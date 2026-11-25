package com.localrecorder.live


enum class SessionState { IDLE, CONNECTING, RECORDING, RECONNECTING, FINISHING }

data class SubtitleRow(
    val key: String,
    val source: String,
    val sourceDone: Boolean,
    val translation: String,
    val translationDone: Boolean,
    /** Non-empty for a separator (a connection break); source and translation are then empty. */
    val marker: String = "",
    val targetLanguage: String? = null,
    val sourceLanguage: String? = null,
    val speaker: String? = null,
    /** Start of the provider utterance on the shared monotonic capture clock. */
    val audioStartMs: Long? = null,
    val languageChange: Boolean = false,
    /** Display name attached to the first text row after a confirmed switch, as required by the export format. */
    val languageSwitch: String? = null,
    val markerMessage: LiveMessage? = null,
)

data class SessionSnapshot(
    val state: SessionState = SessionState.IDLE,
    val rows: List<SubtitleRow> = emptyList(),
    val status: String = "",
    val error: String = "",
    val notice: String = "",
    val playing: Boolean = false,
    /** Audio is waiting to be sent; subtitles lag behind. */
    val slowNetwork: Boolean = false,
    val slowService: Boolean = false,
    /** Older rows were dropped to keep a long session bounded. */
    val trimmed: Boolean = false,
    val statusMessage: LiveMessage? = null,
    val errorMessage: LiveMessage? = null,
    val noticeMessage: LiveMessage? = null,
)

fun interface Cancellable {
    fun cancel()
}

interface SpeechOutput {
    /** Actual output route, when available. Read from the microphone thread during dialogue playback. */
    val microphoneMayHearPlayback: Boolean? get() = null
    fun start(volume: Float)
    fun setVolume(volume: Float) {}

    /** False when too much speech is already waiting. */
    fun append(pcm: ByteArray): Boolean

    /** Plays out what is queued, then calls [done] (on any thread). */
    fun finish(done: () -> Unit)
    fun stop()
}

/** Everything [LiveSession] needs from the device. [post] and [schedule] run blocks on the one session thread. */
interface SessionPlatform {
    fun post(block: () -> Unit)
    fun schedule(delayMs: Long, block: () -> Unit): Cancellable
    fun transport(configuration: LiveTranslateConfig, listener: LiveTransport.Listener): LiveTransport

    /** Starts 16 kHz mono PCM16 capture; both callbacks may run on a capture thread. Throws when unavailable. */
    fun startCapture(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit)

    /** Returns after the last chunk has been delivered. */
    fun stopCapture()
    fun speech(): SpeechOutput

    /** Foreground service, network monitoring. Throws when the session may not start now. */
    fun sessionActive(active: Boolean)

    /** A monotonic clock in milliseconds, on the same time base as [schedule]; any thread. */
    fun elapsedMs(): Long = System.nanoTime() / 1_000_000
}

/** One per logical recording controller. The two dialogue sockets draw on the same per-key service quota. */
class LiveConnectionBudget {
    private val opens = ArrayDeque<Long>()
    var limitedUntil = 0L
        private set

    fun limit(until: Long) { limitedUntil = maxOf(limitedUntil, until) }

    fun earliest(now: Long): Long {
        while (opens.isNotEmpty() && opens.first() <= now - LiveSession.CONNECTION_WINDOW_MS) opens.removeFirst()
        val window = if (opens.size >= LiveSession.MAX_CONNECTIONS_PER_WINDOW)
            opens.first() + LiveSession.CONNECTION_WINDOW_MS else now
        return maxOf(now, window, limitedUntil)
    }

    fun opened(now: Long) { opens.addLast(now) }
}

/**
 * The session state machine behind the UI: one user session spans one or more LiveTranslate
 * connections. A dropped connection is replaced by a new one (rows received so far are kept and
 * the break is marked) while capture keeps running. All methods must be called on the session
 * thread. Rows live in memory here; `SessionRecorder` persists the finalized ones from the snapshots
 * (a row counts as final once `sourceDone`, its translation once `translationDone`).
 *
 * Audio pacing (issue #24): the service falls behind for good when it gets several seconds of audio at
 * once, so a ready connection gets at most [CATCH_UP_MS] of the speech captured before it, then real time.
 * A growing uplink backlog is shed (chunks dropped, the gap marked) rather than answered with a reconnect;
 * only a backlog that stops draining altogether replaces the connection.
 */
class LiveSession(
    private val platform: SessionPlatform,
    private val connectionBudget: LiveConnectionBudget,
    private val onChange: (SessionSnapshot) -> Unit,
) {
    constructor(platform: SessionPlatform, onChange: (SessionSnapshot) -> Unit) :
        this(platform, LiveConnectionBudget(), onChange)

    companion object {
        val RECONNECT_DELAYS_MS = longArrayOf(500, 1_000, 2_000, 4_000, 8_000)
        const val OFFLINE_GIVE_UP_MS = 60_000L
        const val LANGUAGE_DEBOUNCE_MS = 1_000L
        const val LANGUAGE_ACK_MS = 2_000L

        /** A reconnected session that lasts this long resets the attempt and rate-limit counters. */
        const val STABLE_MS = 30_000L

        /** Waits after the service refuses the request rate (close 1007); one more rate limit ends the session. */
        val RATE_LIMIT_DELAYS_MS = longArrayOf(20_000, 40_000, 80_000, 160_000)

        /** Never more than this many connections in any [CONNECTION_WINDOW_MS] (the service allows about 10 a minute). */
        const val MAX_CONNECTIONS_PER_WINDOW = 8
        const val CONNECTION_WINDOW_MS = 60_000L

        private const val BYTES_PER_MS = LiveTranslateConfig.INPUT_SAMPLE_RATE * 2 / 1000

        /**
         * Speech captured while connecting or reconnecting: only the most recent part is sent once the
         * connection is ready, the rest is dropped. About 1 s is absorbed by the service; 5 s at once
         * leaves it reading at about half real time for good.
         */
        const val CATCH_UP_MS = 1_000
        const val CATCH_UP_AUDIO_BYTES = CATCH_UP_MS * BYTES_PER_MS

        /** Above this uplink backlog new chunks are dropped (and the network shown as slow)… */
        const val SHED_AUDIO_BYTES = 1_500 * BYTES_PER_MS

        /** …until it is below this again. */
        const val RESUME_AUDIO_BYTES = 300 * BYTES_PER_MS

        /** A backlog that has not gone down at all for this long means the connection is dead: replace it. */
        const val STALL_MS = 8_000L

        /** Rows still tracked by ID for the live connection; older ones are frozen into the history. */
        const val MAX_ACTIVE_ROWS = 200
        const val MAX_ROWS = 1_000
        const val BREAK_MARKER = "连接中断，此处内容可能有缺失"

        fun congestionMarker(seconds: Int) = "网络拥塞，约 $seconds 秒语音未翻译"
    }

    var snapshot = SessionSnapshot()
        private set

    private var config = LiveTranslateConfig()
    private var key = ""
    private var autoReconnect = true
    private var recoverInitial = false

    private val history = ArrayList<SubtitleRow>()
    private var events = LiveTranslateEvents()
    private var epoch = 0
    private var trimmed = false

    private var connection = 0
    private var transport: LiveTransport? = null
    private var playback: LiveTranslatePlaybackQueue? = null
    private var speech: SpeechOutput? = null
    private var speechOff = false

    private var attempts = 0
    private var lastError: LiveMessage? = null

    /** Short cause of the last disconnect for the reconnecting status (category + detail, never the key). */
    private var lastCause: LiveMessage? = null
    private var online = true
    private var network: Long? = null
    private var retry: Cancellable? = null
    private var ticker: Cancellable? = null
    private var giveUp: Cancellable? = null
    private var stable: Cancellable? = null

    /** Rate limits since the session start or the last stable connection; no connection opens before the shared cooldown expires. */
    private var limits = 0
    private var desiredLanguage: String? = null
    private var awaitingLanguage: String? = null
    private var languageTimer: Cancellable? = null
    private var debounceComplete = false
    private val speaking = mutableSetOf<String>()
    private var switchOnReady = false
    private var drainingOldLanguage = false
    private var settingsReconnect = false
    private var firstSwitchRow: String? = null
    private val switchCandidates = mutableSetOf<String>()
    private var finishAfterHandoff = false
    private var drain: Cancellable? = null
    private var drainProgressAt = 0L

    /** The current reconnect replaces a connection the service closed for lack of results: no marker, no notice. */
    private var quiet = false

    /** Congestion markers inside the live connection, each after the row ID that was newest at the time (null: before all). */
    private val markers = ArrayList<Pair<String?, SubtitleRow>>()
    private var markerCount = 0

    // Shared with the capture thread.
    private val audioLock = Any()
    private var capture = 0
    private var capturing = false
    private var live: LiveTransport? = null
    private var buffering = false
    private var gap = LiveHandoffAudio(LiveHandoffAudio.Reason.RECOVERY)
    private var plannedAudio = false
    private var captureOriginMs: Long? = null
    private var capturedBytes = 0L
    // Each discontinuity in the uploaded audio needs its own offset to compare both dialogue lanes after a drop.
    private data class AudioSpan(val sentStart: Long, val capturedStart: Long)
    private val spans = ArrayDeque<AudioSpan>()
    private var sentBytes = 0L
    private var shedding = false
    private var droppedBytes = 0L
    private var lowestQueued = 0
    private var lowestAt = 0L
    private var stallReported = false
    // The session thread combines local uplink throughput with the service's speech offsets.
    private var uplinkSlow = false
    private var serverSlow = false
    private var progressAt = 0L
    private var progressOffset = -1
    private var windowStartMs = 0L
    private var windowStartQueue = 0
    private var windowSent = 0L
    private var windowCaptured = 0L

    /** Starts a session; the caller has already obtained the microphone permission. */
    fun start(
        config: LiveTranslateConfig, key: String, autoReconnect: Boolean = true,
        plannedHandoff: Boolean = false, recoverInitial: Boolean = false,
    ) {
        if (snapshot.state != SessionState.IDLE) return
        this.config = config
        this.key = key
        this.autoReconnect = autoReconnect
        this.recoverInitial = recoverInitial
        attempts = 0
        limits = 0
        lastCause = null
        quiet = false
        online = true
        network = null
        // A new session right after a rate limit or a burst of connections would only be refused again.
        val wait = earliestOpen() - platform.elapsedMs()
        if (wait > 0 && !plannedHandoff && !recoverInitial) {
            val err = LiveMessage.CooldownError(seconds(wait))
            update { it.copy(error = err.defaultText, errorMessage = err) }
            return
        }
        stopPlayback()
        speechOff = false
        if (wait <= 0) open()?.let { failure ->
            update { it.copy(error = failure.defaultText, errorMessage = failure) }
            return
        }
        // Speech before the connection is ready is kept only for its last second, so do not invite talking yet.
        update {
            it.copy(
                state = SessionState.CONNECTING,
                status = LiveMessage.Connecting.defaultText,
                statusMessage = LiveMessage.Connecting,
                error = "",
                errorMessage = null,
                notice = "",
                noticeMessage = null,
            )
        }
        try {
            platform.sessionActive(true)
        } catch (_: Exception) {
            end(LiveMessage.ForegroundServiceFailed)
            return
        }
        // Capture starts now, not once the session is configured: people speak as soon as they press start,
        // and the handshake usually takes under 1 s. Its last second is sent first once ready.
        beginCapture(plannedHandoff)
        if (wait > 0 && snapshot.state == SessionState.CONNECTING) attempt(immediately = true, counted = false)
    }

    /** Stable for an item within the current provider connection, even if a later socket reuses its ID. */
    fun sourceRowKey(id: String): String = "$epoch:$id"

    /** Local playback and reconnect settings take effect immediately; negotiated wire settings use a paced handoff. */
    fun setPreferences(next: LiveTranslateConfig, reconnect: Boolean) {
        autoReconnect = reconnect
        if (next.profile.id != config.profile.id || next.endpoint != config.endpoint ||
            snapshot.state !in setOf(SessionState.CONNECTING, SessionState.RECORDING, SessionState.RECONNECTING)) return
        if (next.volume != config.volume) speech?.setVolume(next.volume)
        if (next.playbackTiming != config.playbackTiming && config.audioOutput && !speechOff)
            playback = LiveTranslatePlaybackQueue(next.playbackTiming)
        val restart = next.profile.copy(name = config.profile.name) != config.profile ||
            next.audioOutput != config.audioOutput
        if (next.audioOutput != config.audioOutput) {
            if (next.audioOutput) speechOff = false else stopPlayback()
        }
        config = next.copy(language = config.language)
        if (restart) settingsReconnect = true
        applySettingsHandoff()
    }

    private fun applySettingsHandoff() {
        if (!settingsReconnect || snapshot.state != SessionState.RECORDING || awaitingLanguage != null || finishAfterHandoff) return
        settingsReconnect = false
        pauseForHandoff()
        detach()
        quiet = true
        update {
            it.copy(
                state = SessionState.RECONNECTING,
                status = LiveMessage.ApplyingSettings.defaultText,
                statusMessage = LiveMessage.ApplyingSettings,
            )
        }
        attempt(immediately = true, counted = false)
    }

    /** Last selection wins; change only after the active utterance has ended. */
    fun setTargetLanguage(language: String) {
        if (snapshot.state !in setOf(SessionState.CONNECTING, SessionState.RECONNECTING, SessionState.RECORDING) ||
            finishAfterHandoff || LiveTranslateConfig.LANGUAGES.none { it.first == language }) return
        desiredLanguage = language
        if (awaitingLanguage != null || switchOnReady) return
        debounceLanguage()
    }

    private fun debounceLanguage() {
        languageTimer?.cancel()
        debounceComplete = false
        if (desiredLanguage == config.language) {
            desiredLanguage = null
            return
        }
        languageTimer = platform.schedule(LANGUAGE_DEBOUNCE_MS) {
            debounceComplete = true
            tryLanguageChange()
        }
    }

    private fun tryLanguageChange() {
        val next = desiredLanguage ?: return
        if (!debounceComplete || speaking.isNotEmpty() || snapshot.state != SessionState.RECORDING ||
            awaitingLanguage != null || switchOnReady) return
        languageTimer?.cancel()
        awaitingLanguage = next
        pauseForHandoff()
        languageTimer = platform.schedule(LANGUAGE_ACK_MS) { replaceForLanguage(next) }
        if (transport?.updateLanguage(next) != true) replaceForLanguage(next)
    }

    private fun pauseForHandoff() {
        drain?.cancel()
        drain = null
        synchronized(audioLock) {
            if (!plannedAudio) gap = LiveHandoffAudio(LiveHandoffAudio.Reason.LANGUAGE_SWITCH)
            plannedAudio = true
            live = null
            buffering = true
        }
    }

    private fun replaceForLanguage(language: String) {
        if (awaitingLanguage != language) return
        languageTimer?.cancel()
        if (!drainingOldLanguage && events.rows.values.any { !events.translation(it).done }) {
            // A translated tail can arrive after speech_stopped. Finish the old socket before retiring its rows.
            drainingOldLanguage = true
            transport?.finish()
            languageTimer = platform.schedule(LANGUAGE_ACK_MS) { openLanguageReplacement(language) }
            return
        }
        openLanguageReplacement(language)
    }

    private fun openLanguageReplacement(language: String) {
        drainingOldLanguage = false
        languageTimer?.cancel()
        awaitingLanguage = null
        switchOnReady = true
        detach()
        config = config.copy(language = language)
        quiet = true
        update {
            it.copy(
                state = SessionState.RECONNECTING,
                status = LiveMessage.SwitchingLanguage.defaultText,
                statusMessage = LiveMessage.SwitchingLanguage,
            )
        }
        attempt(immediately = true, counted = false)
    }

    private fun changedLanguage() {
        switchOnReady = false
        awaitingLanguage = null
        languageTimer?.cancel()
        languageTimer = null
        val name = config.languageName
        firstSwitchRow = name
        switchCandidates.clear()
        val markerMsg = LiveMessage.LanguageSwitchedMarker(name)
        markers += events.order.lastOrNull() to SubtitleRow(
            "language:${markerCount++}", "", true, "", true,
            marker = markerMsg.defaultText, targetLanguage = config.language, languageChange = true,
            markerMessage = markerMsg,
        )
        if (desiredLanguage == config.language) desiredLanguage = null
        debounceComplete = false
        if (desiredLanguage != null && !finishAfterHandoff) debounceLanguage()
        publish()
    }

    /** Explicit switch: keep the existing capture and history, and apply the same connection budget as reconnect. */
    fun switchProfile(next: LiveTranslateConfig, credential: String): Boolean {
        if (snapshot.state != SessionState.RECORDING || credential.isBlank() || next.profile.id == config.profile.id) return false
        // An explicitly selected profile supplies its own target; ignore a late ack from the previous socket.
        languageTimer?.cancel()
        desiredLanguage = null
        awaitingLanguage = null
        debounceComplete = false
        firstSwitchRow = null
        detach()
        config = next
        key = credential
        quiet = false
        val switchCause = LiveMessage.CauseProfileSwitch(next.profile.name)
        val switchMarker = LiveMessage.ProfileSwitchedMarker(next.profile.name)
        lastCause = switchCause
        history += SubtitleRow("profile:$epoch", "", true, "", true, switchMarker.defaultText, markerMessage = switchMarker)
        update { it.copy(state = SessionState.RECONNECTING, slowNetwork = false, slowService = false, notice = "", noticeMessage = null) }
        publish()
        attempt(immediately = true, counted = false)
        return true
    }

    /** Stops capture; the server still delivers the tail before the session ends. */
    fun stop() {
        val waiting = synchronized(audioLock) { plannedAudio && gap.size > 0 }
        if (waiting && (!online || transport == null && earliestOpen() > platform.elapsedMs())) {
            // An explicit stop must not keep the microphone/service alive through a long quota or offline wait.
            end(LiveMessage.HandoffStoppedEarly)
            return
        }
        if (waiting && snapshot.state in setOf(SessionState.CONNECTING, SessionState.RECONNECTING, SessionState.RECORDING)) {
            if (capturing) {
                platform.stopCapture()
                capturing = false
            }
            finishAfterHandoff = true
            update { it.copy(status = LiveMessage.WaitingFinalResult.defaultText, statusMessage = LiveMessage.WaitingFinalResult) }
            return
        }
        languageTimer?.cancel()
        desiredLanguage = null
        awaitingLanguage = null
        drainingOldLanguage = false
        when (snapshot.state) {
            SessionState.CONNECTING, SessionState.RECONNECTING -> end(null as LiveMessage?)
            SessionState.RECORDING -> {
                // Joins the capture thread, so every chunk is queued before session.finish.
                stopCapture()
                stable?.cancel()
                transport?.finish()
                update {
                    it.copy(
                        state = SessionState.FINISHING,
                        status = LiveMessage.WaitingFinalResult.defaultText,
                        statusMessage = LiveMessage.WaitingFinalResult,
                        slowNetwork = false,
                    )
                }
            }
            else -> Unit
        }
    }

    fun clear() {
        if (snapshot.state != SessionState.IDLE) return
        history.clear()
        trimmed = false
        events = LiveTranslateEvents()
        publish()
    }

    fun exportText(): String = snapshot.rows.joinToString("\n\n") { row ->
        if (row.marker.isNotEmpty()) "【${row.marker}】"
        else listOf(row.source, row.translation).filter { it.isNotBlank() }.joinToString("\n")
    }

    /** Silences translated speech for the rest of the session; subtitles continue. */
    fun stopPlayback() {
        playback = null
        speechOff = true
        speech?.stop()
        speech = null
        if (snapshot.playing) update { it.copy(playing = false) }
    }

    /** Another app took the audio output. */
    fun interruptPlayback(message: LiveMessage) {
        if (speech == null) return
        stopPlayback()
        update { it.copy(notice = message.defaultText, noticeMessage = message) }
    }

    fun interruptPlayback(message: String) = interruptPlayback(LiveMessage.Raw(message))

    fun notice(message: LiveMessage) = update { it.copy(notice = message.defaultText, noticeMessage = message) }

    fun notice(message: String) = notice(LiveMessage.Raw(message))

    fun dismissMessages() = update { it.copy(error = "", errorMessage = null, notice = "", noticeMessage = null) }

    /** The microphone was taken away (a call, another recorder) or failed. */
    fun captureInterrupted(message: LiveMessage) {
        if (capturing) end(message)
    }

    fun captureInterrupted(message: String) = captureInterrupted(LiveMessage.Raw(message))

    /** The default network is up; [id] changes when the device moves between Wi‑Fi and mobile data. */
    fun networkAvailable(id: Long) {
        val switched = network != null && network != id
        val wasOffline = !online
        network = id
        online = true
        giveUp?.cancel()
        giveUp = null
        when (snapshot.state) {
            // The old socket is bound to the old network; waiting for it to time out loses speech.
            SessionState.RECORDING -> if (switched && autoReconnect) interrupt(LiveMessage.CauseNetworkSwitched)
            SessionState.RECONNECTING -> if (switched || wasOffline) {
                dropTransport()
                attempts = 0
                // A pending rate-limit wait still applies: the limit is per key, not per network.
                attempt(immediately = true)
            }
            else -> Unit
        }
    }

    fun networkLost() {
        online = false
        when (snapshot.state) {
            SessionState.RECORDING -> if (autoReconnect) interrupt(LiveMessage.CauseNetworkLost)
            SessionState.RECONNECTING -> {
                dropTransport()
                attempt()
            }
            else -> Unit
        }
    }

    /** Opens a new connection for the current session; returns an error for an invalid configuration. */
    private fun open(): LiveMessage? {
        uplinkSlow = false
        serverSlow = false
        progressOffset = -1
        val token = ++connection
        settingsReconnect = false // This handshake includes the latest negotiated settings.
        connectionBudget.opened(platform.elapsedMs())
        synchronized(audioLock) {
            spans.clear()
            sentBytes = 0
        }
        speaking.clear()
        switchCandidates.clear()
        events = LiveTranslateEvents()
        markers.clear()
        val next: LiveTransport
        try {
            next = platform.transport(config, Listener(token))
            next.connect(config, key)
        } catch (e: LiveTranslateException) {
            return e.liveMessage
        }
        transport = next
        playback = if (config.audioOutput && !speechOff) LiveTranslatePlaybackQueue(config.playbackTiming) else null
        return null
    }

    /** The earliest time a connection may open: after a rate-limit wait, and within the per-minute budget. */
    private fun earliestOpen() = connectionBudget.earliest(platform.elapsedMs())

    private fun dropTransport() {
        retry?.cancel()
        retry = null
        ticker?.cancel()
        ticker = null
        transport?.cancel()
        transport = null
        connection++
    }

    private inner class Listener(private val token: Int) : LiveTransport.Listener {
        override fun onReady() {
            if (token == connection) ready()
        }

        override fun onLanguageUpdate(language: String, confirmed: Boolean) {
            if (token != connection || language != awaitingLanguage || drainingOldLanguage) return
            if (!confirmed) {
                replaceForLanguage(language)
                return
            }
            config = config.copy(language = language)
            changedLanguage()
            transport?.let(::attach)
            if (snapshot.state == SessionState.RECORDING) {
                val statusMsg = recordingStatusMessage()
                update { it.copy(status = statusMsg.defaultText, statusMessage = statusMsg) }
            }
            applySettingsHandoff()
        }

        override fun onEvent(event: LiveSessionEvent) {
            if (token == connection) received(event)
        }

        override fun onEnd(error: String?, recoverable: Boolean, cause: EndCause) {
            if (token == connection) ended(error, recoverable, cause)
        }
    }

    /** Opens the microphone; until a connection is ready its chunks wait in the gap buffer. */
    private fun beginCapture(planned: Boolean) {
        val generation = synchronized(audioLock) {
            live = null
            buffering = true
            plannedAudio = planned
            gap = LiveHandoffAudio(if (planned) LiveHandoffAudio.Reason.LANGUAGE_SWITCH else LiveHandoffAudio.Reason.RECOVERY)
            captureOriginMs = null
            capturedBytes = 0
            resetShedding()
            ++capture
        }
        try {
            platform.startCapture(
                { pcm -> chunk(generation, pcm) },
                { message -> platform.post { if (generation == capture) captureInterrupted(message) } },
            )
        } catch (e: Exception) {
            end((e as? LiveTranslateException)?.liveMessage ?: LiveMessage.MicOpenFailed)
            return
        }
        capturing = true
    }

    /**
     * The last [CATCH_UP_MS] of speech captured before this connection was ready goes first, in order (the gap
     * buffer keeps no more than that); then chunks go straight to it at the capture pace.
     */
    private fun attach(current: LiveTransport) {
        synchronized(audioLock) {
            resetShedding()
            live = current
            buffering = false
            windowStartMs = platform.elapsedMs()
            drainProgressAt = windowStartMs
            windowStartQueue = current.queuedAudioBytes
            windowSent = 0
            windowCaptured = 0
            if (!plannedAudio) {
                while (gap.size > 0) {
                    val start = capturedBytes - gap.size
                    val pcm = gap.poll(platform.elapsedMs()) ?: break
                    if (appendMapped(current, pcm, start) != AppendResult.SENT) break
                }
                gap.clear()
            }
        }
        drainHandoff(current)
    }

    /** Paces a deliberate switch even when capture stops with buffered audio still to deliver. */
    private fun drainHandoff(current: LiveTransport) {
        drain?.cancel()
        drain = null
        synchronized(audioLock) {
            if (live !== current || !plannedAudio) return
            if (gap.size > 0 && current.queuedAudioBytes < SHED_AUDIO_BYTES) {
                val start = capturedBytes - gap.size
                val pcm = gap.poll(platform.elapsedMs())
                if (pcm != null) {
                    val result = appendMapped(current, pcm, start)
                    if (result == AppendResult.SENT) drainProgressAt = platform.elapsedMs() else gap.restoreFront(pcm)
                    if (result == AppendResult.CLOSED) {
                        live = null
                        buffering = true
                        return
                    }
                }
            }
            if (gap.size > 0) {
                if (platform.elapsedMs() - drainProgressAt >= STALL_MS) {
                    val generation = capture
                    platform.post { stalled(generation, current) }
                } else {
                    drain = platform.schedule(20) { drainHandoff(current) }
                }
                return
            }
            plannedAudio = false
            gap = LiveHandoffAudio(LiveHandoffAudio.Reason.RECOVERY)
        }
        if (finishAfterHandoff && snapshot.state == SessionState.RECORDING) stop()
    }

    /** Under audioLock. Provider positions count only audio successfully sent on this connection. */
    private fun appendMapped(target: LiveTransport, pcm: ByteArray, capturedStart: Long): AppendResult {
        val result = target.append(pcm)
        if (result == AppendResult.SENT) {
            val span = spans.lastOrNull()
            if (span == null || span.capturedStart + sentBytes - span.sentStart != capturedStart) {
                spans.addLast(AudioSpan(sentBytes, capturedStart))
                if (spans.size > MAX_ROWS) spans.removeFirst()
            }
            sentBytes += pcm.size
        }
        return result
    }

    private fun audioPosition(offsetMs: Int): Long? = synchronized(audioLock) {
        val offset = offsetMs.toLong() * BYTES_PER_MS
        val span = spans.lastOrNull { it.sentStart <= offset } ?: return@synchronized null
        captureOriginMs?.plus((span.capturedStart + offset - span.sentStart) / BYTES_PER_MS)
    }

    /** Under [audioLock]. */
    private fun resetShedding() {
        shedding = false
        droppedBytes = 0
        stallReported = false
    }

    private fun ready() {
        val current = transport ?: return
        val statusMsg = recordingStatusMessage()
        when (snapshot.state) {
            SessionState.CONNECTING -> {
                attach(current)
                // After capture: the platform has settled its audio routing (e.g. a Bluetooth headset) by now.
                if (config.audioOutput) startSpeech()
                update { it.copy(state = SessionState.RECORDING, status = statusMsg.defaultText, statusMessage = statusMsg) }
            }
            SessionState.RECONNECTING -> {
                attach(current)
                stable = platform.schedule(STABLE_MS) {
                    attempts = 0
                    limits = 0
                }
                if (config.audioOutput && !speechOff && speech == null) startSpeech()
                val renewed = quiet
                quiet = false
                update {
                    it.copy(
                        state = SessionState.RECORDING,
                        status = statusMsg.defaultText,
                        statusMessage = statusMsg,
                        notice = if (renewed) it.notice else LiveMessage.ReconnectedNotice.defaultText,
                        noticeMessage = if (renewed) it.noticeMessage else LiveMessage.ReconnectedNotice,
                    )
                }
            }
            else -> Unit
        }
        if (switchOnReady) changedLanguage()
        applySettingsHandoff()
        tryLanguageChange()
        if (finishAfterHandoff && !plannedAudio) stop()
    }

    private fun recordingStatusMessage() = LiveMessage.RecordingTo(config.languageName)

    /** Capture thread. */
    private fun chunk(generation: Int, pcm: ByteArray) {
        val notify = ArrayList<() -> Unit>(2)
        synchronized(audioLock) {
            if (generation != capture) return
            if (captureOriginMs == null) captureOriginMs = platform.elapsedMs() - pcm.size / BYTES_PER_MS
            val capturedStart = capturedBytes
            capturedBytes += pcm.size
            val target = live
            if (target == null) {
                if (buffering) gap.append(pcm)
                return
            }
            if (plannedAudio) {
                gap.append(pcm)
                return
            }
            val queued = target.queuedAudioBytes
            val now = platform.elapsedMs()
            if (now - windowStartMs >= 15_000 && windowCaptured > 0) {
                val slow = windowStartQueue + windowSent - queued < windowCaptured * 0.8
                notify += {
                    if (current(generation, target)) {
                        uplinkSlow = slow
                        update { it.copy(slowService = uplinkSlow || serverSlow) }
                    }
                }
                windowStartMs = now
                windowStartQueue = queued
                windowSent = 0
                windowCaptured = 0
            }
            windowCaptured += pcm.size
            if (shedding) {
                if (queued >= RESUME_AUDIO_BYTES) {
                    droppedBytes += pcm.size
                    if (queued < lowestQueued) {
                        lowestQueued = queued
                        lowestAt = now
                    } else if (!stallReported && now - lowestAt >= STALL_MS) {
                        stallReported = true
                        notify += { stalled(generation, target) }
                    }
                } else {
                    // Drained: send again, and mark what was not sent.
                    val dropped = droppedBytes
                    resetShedding()
                    notify += { resumed(generation, target, dropped) }
                }
            } else if (queued > SHED_AUDIO_BYTES) {
                startShedding(pcm, queued)
                notify += { congested(generation, target) }
            }
            if (!shedding) {
                when (appendMapped(target, pcm, capturedStart)) {
                    AppendResult.SENT -> windowSent += pcm.size
                    // Only a chunk larger than the transport's whole queue gets here: drop it like the others.
                    AppendResult.FULL -> {
                        startShedding(pcm, queued)
                        notify += { congested(generation, target) }
                    }
                    // The connection ended and onEnd is on its way: keep the audio for the one that replaces it.
                    AppendResult.CLOSED -> hold(pcm)
                }
            }
        }
        notify.forEach(platform::post)
    }

    /** Under [audioLock]. */
    private fun startShedding(pcm: ByteArray, queued: Int) {
        shedding = true
        droppedBytes += pcm.size
        lowestQueued = queued
        lowestAt = platform.elapsedMs()
        stallReported = false
    }

    private fun hold(pcm: ByteArray) {
        live = null
        buffering = autoReconnect
        if (buffering) gap.append(pcm)
    }

    private fun current(generation: Int, target: LiveTransport) =
        generation == capture && target === transport && snapshot.state == SessionState.RECORDING

    /** The uplink backlog passed [SHED_AUDIO_BYTES]: audio is being dropped. */
    private fun congested(generation: Int, target: LiveTransport) {
        if (current(generation, target)) update { it.copy(slowNetwork = true) }
    }

    /** Sending resumed after [dropped] bytes were not sent: mark the gap where it happened. */
    private fun resumed(generation: Int, target: LiveTransport, dropped: Long) {
        if (!current(generation, target)) return
        val seconds = ((dropped + 500L * BYTES_PER_MS) / (1000L * BYTES_PER_MS)).toInt().coerceAtLeast(1)
        val markerMsg = LiveMessage.CongestionMarker(seconds)
        markers += events.order.lastOrNull() to SubtitleRow(
            "congestion:${markerCount++}", "", true, "", true,
            marker = markerMsg.defaultText, markerMessage = markerMsg,
        )
        update { it.copy(slowNetwork = false) }
        publish()
    }

    /** The backlog has not gone down for [STALL_MS]: the connection is not usable any more. */
    private fun stalled(generation: Int, target: LiveTransport) {
        if (!current(generation, target)) return
        if (autoReconnect) {
            interrupt(LiveMessage.UploadStalledStopped, LiveMessage.CauseUploadStalled(STALL_MS / 1000))
        } else {
            end(LiveMessage.UploadStalledStopped)
        }
    }

    private fun received(event: LiveSessionEvent) {
        when (event) {
            is LiveSessionEvent.SpeechStart -> {
                speaking.add(event.source)
                observeProgress(event.milliseconds)
            }
            is LiveSessionEvent.SpeechEnd -> {
                if (event.source == null) speaking.clear() else speaking.remove(event.source)
                observeProgress(event.milliseconds)
            }
            else -> Unit
        }
        events.apply(event)
        if (event is LiveSessionEvent.Text && event.source && event.final) speaking.remove(event.item)
        val sourceID = when (event) {
            is LiveSessionEvent.SpeechStart -> event.source
            is LiveSessionEvent.Link -> event.source
            is LiveSessionEvent.Text -> if (event.source) event.item else null
            else -> null
        }
        sourceID?.let { id -> events.rows[id]?.let { row ->
            if (row.targetLanguage == null) {
                row.targetLanguage = config.language
                if (firstSwitchRow != null) switchCandidates.add(id)
            }
            if (event is LiveSessionEvent.SpeechStart) row.audioStartMs = audioPosition(event.milliseconds)
        } }
        firstSwitchRow?.let { name ->
            // speech_started can be reported for an empty/noise-only turn; attach the export marker to actual text.
            val visible = events.rows.values.firstOrNull {
                it.targetLanguage == config.language && (it.source.text.isNotEmpty() || events.translation(it).text.isNotEmpty())
                    && it.id in switchCandidates
            }
            if (visible != null) {
                visible.languageSwitch = name
                firstSwitchRow = null
                switchCandidates.clear()
            }
        }
        playback?.let { queue ->
            try {
                for (pcm in queue.consume(event, events)) {
                    if (speech?.append(pcm) == false) {
                        interruptPlayback(LiveMessage.AudioBacklogStopped)
                        break
                    }
                }
            } catch (e: LiveTranslateException) {
                interruptPlayback(e.liveMessage)
            }
        }
        // A long connection keeps only its newest rows addressable by ID.
        val order = events.order
        val retiring = order.take((order.size - MAX_ACTIVE_ROWS).coerceAtLeast(0))
        if (retiring.isNotEmpty()) history.addAll(markersAfter(null))
        for (id in retiring) {
            events.rows[id]?.let { row -> subtitle(row)?.let(history::add) }
            history.addAll(markersAfter(id))
            events.retire(id)
            speaking.remove(id)
            switchCandidates.remove(id)
        }
        publish()
        tryLanguageChange()
    }

    /** Compares service-reported audio positions, even when the local socket is sending at full speed. */
    private fun observeProgress(offset: Int) {
        val now = platform.elapsedMs()
        if (progressOffset >= 0) {
            val elapsed = now - progressAt
            if (elapsed < 15_000 || offset <= progressOffset) return
            serverSlow = offset - progressOffset < elapsed * 0.8
            update { it.copy(slowService = uplinkSlow || serverSlow) }
        }
        progressOffset = offset
        progressAt = now
    }

    /** Removes and returns the congestion markers anchored after [id]. */
    private fun markersAfter(id: String?): List<SubtitleRow> {
        if (markers.none { it.first == id }) return emptyList()
        val (anchored, rest) = markers.partition { it.first == id }
        markers.clear()
        markers.addAll(rest)
        return anchored.map { it.second }
    }

    private fun ended(error: String?, recoverable: Boolean, cause: EndCause) {
        val limited = recoverable && cause.kind == EndCause.Kind.RATE_LIMITED
        if (limited) limits++
        if (limited && limits <= RATE_LIMIT_DELAYS_MS.size) connectionBudget.limit(platform.elapsedMs() + RATE_LIMIT_DELAYS_MS[limits - 1])
        if (drainingOldLanguage && !limited) {
            awaitingLanguage?.let(::openLanguageReplacement)
            return
        }
        drainingOldLanguage = false
        val again = recoverable && (!limited || limits <= RATE_LIMIT_DELAYS_MS.size)
        val errorMsg = cause.errorMessage ?: error?.takeIf { it.isNotEmpty() }?.let(LiveMessage::Raw)
        val causeMsg = cause.detailMessage ?: cause.detail.takeIf { it.isNotEmpty() }?.let(LiveMessage::Raw)
        val failure = if (limited && !again) LiveMessage.ContinuousRateLimitStopped else errorMsg
        when (snapshot.state) {
            SessionState.CONNECTING -> if (recoverInitial && autoReconnect && again) {
                dropTransport()
                quiet = true
                lastCause = causeMsg
                lastError = errorMsg
                update {
                    it.copy(
                        state = SessionState.RECONNECTING,
                        status = LiveMessage.ReconnectingSimple.defaultText,
                        statusMessage = LiveMessage.ReconnectingSimple,
                    )
                }
                attempt(counted = !limited)
            } else end(failure)
            SessionState.RECORDING -> when {
                !again || !autoReconnect -> end(failure)
                cause.kind == EndCause.Kind.NO_RESULT -> renew(causeMsg)
                else -> interrupt(errorMsg, causeMsg, counted = !limited)
            }
            SessionState.RECONNECTING -> if (again) {
                lastError = errorMsg
                lastCause = causeMsg
                dropTransport()
                if (quiet) {
                    // The quiet replacement failed too: from here on it is an ordinary break.
                    quiet = false
                    markBreak()
                    publish()
                }
                attempt(counted = !limited)
            } else {
                end(failure)
            }
            else -> end(failure)
        }
    }

    private fun markBreak() {
        if (history.lastOrNull()?.marker != BREAK_MARKER) {
            history.add(SubtitleRow("break:$epoch", "", true, "", true, BREAK_MARKER, markerMessage = LiveMessage.BreakMarker))
        }
    }

    /** Stops sending to the current connection; capture keeps running into the gap buffer. */
    private fun detach() {
        drain?.cancel()
        drain = null
        drainingOldLanguage = false
        if (awaitingLanguage != null) {
            // A transport failure during the update is recovered directly in the requested language.
            config = config.copy(language = awaitingLanguage!!)
            awaitingLanguage = null
            languageTimer?.cancel()
            switchOnReady = true
        }
        stable?.cancel()
        stable = null
        synchronized(audioLock) {
            live = null
            buffering = true
            resetShedding()
        }
        dropTransport()
        freeze()
    }

    /** The connection of a running session is gone: keep capturing and replace it. */
    private fun interrupt(reason: LiveMessage?, cause: LiveMessage? = reason, counted: Boolean = true) {
        detach()
        markBreak()
        quiet = false
        lastError = reason
        lastCause = cause
        update { it.copy(state = SessionState.RECONNECTING, slowNetwork = false, slowService = false, notice = "", noticeMessage = null) }
        publish()
        attempt(counted = counted)
    }

    /**
     * The service closed a connection that heard nothing it could transcribe for 60 s (a long silence):
     * replace it right away without a marker; this is not a failed attempt.
     */
    private fun renew(cause: LiveMessage?) {
        detach()
        quiet = true
        lastCause = cause
        update { it.copy(state = SessionState.RECONNECTING, slowNetwork = false, slowService = false) }
        publish()
        attempt(counted = false)
    }

    /**
     * Schedules the next connection: after the backoff for a [counted] attempt (immediately otherwise), but never
     * before a rate-limit wait ends or while [MAX_CONNECTIONS_PER_WINDOW] connections were opened in the last minute.
     */
    private fun attempt(immediately: Boolean = false, counted: Boolean = true) {
        retry?.cancel()
        retry = null
        ticker?.cancel()
        ticker = null
        if (!online) {
            update { it.copy(status = LiveMessage.NetworkWaiting.defaultText, statusMessage = LiveMessage.NetworkWaiting) }
            if (giveUp == null) {
                giveUp = platform.schedule(OFFLINE_GIVE_UP_MS) { end(LiveMessage.NetworkUnavailableStopped) }
            }
            return
        }
        var delay = 0L
        if (counted) {
            if (attempts >= RECONNECT_DELAYS_MS.size) {
                end(LiveMessage.ReconnectFailed(lastError))
                return
            }
            delay = if (immediately) 0 else RECONNECT_DELAYS_MS[attempts]
            attempts++
        }
        val now = platform.elapsedMs()
        val at = maxOf(now + delay, earliestOpen())
        retry = platform.schedule(at - now) {
            retry = null
            ticker?.cancel()
            ticker = null
            // The peer may have used the last slot, or received a 1007 while we were waiting.
            if (earliestOpen() > platform.elapsedMs()) attempt(immediately = true, counted = false)
            else open()?.let(::end)
        }
        when {
            at > now + delay -> countdown(at, rateLimited = at == connectionBudget.limitedUntil)
            switchOnReady -> update { it.copy(status = LiveMessage.SwitchingLanguage.defaultText, statusMessage = LiveMessage.SwitchingLanguage) }
            quiet -> update { it.copy(status = LiveMessage.QuietRenewing.defaultText, statusMessage = LiveMessage.QuietRenewing) }
            else -> {
                val statusMsg = LiveMessage.Reconnecting(attempts, lastCause)
                update { it.copy(status = statusMsg.defaultText, statusMessage = statusMsg) }
            }
        }
    }

    /** "服务限流，N 秒后重试", updated every second until the connection opens at [at]. */
    private fun countdown(at: Long, rateLimited: Boolean) {
        val left = at - platform.elapsedMs()
        val shown = seconds(left)
        val statusMsg = LiveMessage.CooldownWait(rateLimited, shown)
        update { it.copy(status = statusMsg.defaultText, statusMessage = statusMsg) }
        if (shown > 1) ticker = platform.schedule(left - (shown - 1) * 1000L) { countdown(at, rateLimited) }
    }

    private fun seconds(ms: Long) = ((ms + 999) / 1000).toInt()

    private fun startSpeech() {
        try {
            speech = platform.speech().also { it.start(config.volume) }
            update { it.copy(playing = true) }
        } catch (_: Exception) {
            stopPlayback()
            update { it.copy(notice = LiveMessage.PlaybackStartFailed.defaultText, noticeMessage = LiveMessage.PlaybackStartFailed) }
        }
    }

    private fun stopCapture() {
        if (capturing) {
            capturing = false
            platform.stopCapture()
        }
        synchronized(audioLock) {
            capture++
            live = null
            buffering = false
            gap.clear()
            resetShedding()
        }
    }

    private fun end(error: LiveMessage?) {
        languageTimer?.cancel()
        drain?.cancel()
        drain = null
        desiredLanguage = null
        awaitingLanguage = null
        debounceComplete = false
        switchOnReady = false
        finishAfterHandoff = false
        settingsReconnect = false
        drainingOldLanguage = false
        firstSwitchRow = null
        switchCandidates.clear()
        giveUp?.cancel()
        giveUp = null
        stable?.cancel()
        stable = null
        stopCapture()
        dropTransport()
        quiet = false
        playback = null
        freeze()
        // Speech already received plays out; a new session or "stop playback" cuts it short.
        speech?.let { current ->
            current.finish { platform.post { if (speech === current) stopPlayback() } }
        }
        // Rows first: observers treat the IDLE snapshot as the end of the session's rows.
        publish()
        update {
            it.copy(
                state = SessionState.IDLE,
                status = "",
                statusMessage = null,
                error = error?.defaultText.orEmpty(),
                errorMessage = error,
                slowNetwork = false,
                slowService = false,
            )
        }
        try {
            platform.sessionActive(false)
        } catch (_: Exception) {
        }
    }

    /** Moves the current connection's rows into the history; later connections append below them. */
    private fun freeze() {
        history.addAll(currentRows(frozen = true))
        events = LiveTranslateEvents()
        markers.clear()
        epoch++
    }

    private fun subtitle(row: LiveTranslateEvents.Row): SubtitleRow? {
        val translation = events.translation(row)
        if (row.source.text.isEmpty() && translation.text.isEmpty()) return null
        return SubtitleRow(sourceRowKey(row.id), row.source.text, row.source.done, translation.text, translation.done,
            targetLanguage = row.targetLanguage, audioStartMs = row.audioStartMs, languageSwitch = row.languageSwitch)
    }

    /**
     * [frozen]: the connection is gone, so a finished translation whose source never arrived is final too
     * (its source is settled as empty); while live, that source may still arrive and re-key the row.
     */
    private fun currentRows(frozen: Boolean = false): List<SubtitleRow> {
        val rows = ArrayList<SubtitleRow>()
        val anchored = markers.groupBy({ it.first }, { it.second })
        anchored[null]?.let(rows::addAll)
        for (id in events.order) {
            events.rows[id]?.let(::subtitle)?.let(rows::add)
            anchored[id]?.let(rows::addAll)
        }
        // Translations whose source association has not arrived yet.
        val pending = events.unmatchedOutputs.map { (id, part) ->
            SubtitleRow("$epoch:out:$id", "", frozen && part.done, part.text, part.done, targetLanguage = config.language)
        }
        return rows + pending
    }

    private fun publish() {
        if (history.size > MAX_ROWS) {
            history.subList(0, history.size - MAX_ROWS).clear()
            trimmed = true
        }
        val rows = history + currentRows()
        update { it.copy(rows = rows, trimmed = trimmed) }
    }

    private fun update(change: (SessionSnapshot) -> SessionSnapshot) {
        val next = change(snapshot)
        if (next == snapshot) return
        snapshot = next
        onChange(next)
    }
}
