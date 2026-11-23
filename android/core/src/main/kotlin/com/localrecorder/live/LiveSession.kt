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
)

fun interface Cancellable {
    fun cancel()
}

interface SpeechOutput {
    fun start(volume: Float)

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
class LiveSession(private val platform: SessionPlatform, private val onChange: (SessionSnapshot) -> Unit) {
    companion object {
        val RECONNECT_DELAYS_MS = longArrayOf(500, 1_000, 2_000, 4_000, 8_000)
        const val OFFLINE_GIVE_UP_MS = 60_000L

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
    private var lastError = ""

    /** Short cause of the last disconnect for the reconnecting status (category + detail, never the key). */
    private var lastCause = ""
    private var online = true
    private var network: Long? = null
    private var retry: Cancellable? = null
    private var ticker: Cancellable? = null
    private var giveUp: Cancellable? = null
    private var stable: Cancellable? = null

    /** Rate limits since the session start or the last stable connection; no connection opens before [limitedUntil]. */
    private var limits = 0
    private var limitedUntil = 0L

    /** When recent connections were opened, oldest first (kept across sessions: the service counts per key). */
    private val opens = ArrayDeque<Long>()

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
    private val gap = ArrayDeque<ByteArray>()
    private var gapBytes = 0
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
    fun start(config: LiveTranslateConfig, key: String, autoReconnect: Boolean = true) {
        if (snapshot.state != SessionState.IDLE) return
        this.config = config
        this.key = key
        this.autoReconnect = autoReconnect
        attempts = 0
        limits = 0
        lastCause = ""
        quiet = false
        online = true
        network = null
        // A new session right after a rate limit or a burst of connections would only be refused again.
        val wait = earliestOpen() - platform.elapsedMs()
        if (wait > 0) {
            update { it.copy(error = "连接过于频繁或服务限流，请 ${seconds(wait)} 秒后再试") }
            return
        }
        stopPlayback()
        speechOff = false
        open()?.let { failure ->
            update { it.copy(error = failure) }
            return
        }
        // Speech before the connection is ready is kept only for its last second, so do not invite talking yet.
        update { it.copy(state = SessionState.CONNECTING, status = "正在连接…", error = "", notice = "") }
        try {
            platform.sessionActive(true)
        } catch (_: Exception) {
            end("无法启动前台录音服务，请在应用位于前台时开始")
            return
        }
        // Capture starts now, not once the session is configured: people speak as soon as they press start,
        // and the handshake usually takes under 1 s. Its last second is sent first once ready.
        beginCapture()
    }

    /** Explicit switch: keep the existing capture and history, and apply the same connection budget as reconnect. */
    fun switchProfile(next: LiveTranslateConfig, credential: String): Boolean {
        if (snapshot.state != SessionState.RECORDING || credential.isBlank() || next.profile.id == config.profile.id) return false
        detach()
        config = next
        key = credential
        quiet = false
        lastCause = "切换到「" + next.profile.name + "」"
        history += SubtitleRow("profile:$epoch", "", true, "", true, lastCause)
        update { it.copy(state = SessionState.RECONNECTING, slowNetwork = false, slowService = false, notice = "") }
        publish()
        attempt(immediately = true, counted = false)
        return true
    }

    /** Stops capture; the server still delivers the tail before the session ends. */
    fun stop() {
        when (snapshot.state) {
            SessionState.CONNECTING, SessionState.RECONNECTING -> end(null)
            SessionState.RECORDING -> {
                // Joins the capture thread, so every chunk is queued before session.finish.
                stopCapture()
                stable?.cancel()
                transport?.finish()
                update { it.copy(state = SessionState.FINISHING, status = "正在等待尾句结果…", slowNetwork = false) }
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
    fun interruptPlayback(message: String) {
        if (speech == null) return
        stopPlayback()
        update { it.copy(notice = message) }
    }

    fun notice(message: String) = update { it.copy(notice = message) }

    fun dismissMessages() = update { it.copy(error = "", notice = "") }

    /** The microphone was taken away (a call, another recorder) or failed. */
    fun captureInterrupted(message: String) {
        if (capturing) end(message)
    }

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
            SessionState.RECORDING -> if (switched && autoReconnect) interrupt("网络已切换")
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
            SessionState.RECORDING -> if (autoReconnect) interrupt("网络已断开")
            SessionState.RECONNECTING -> {
                dropTransport()
                attempt()
            }
            else -> Unit
        }
    }

    /** Opens a new connection for the current session; returns an error for an invalid configuration. */
    private fun open(): String? {
        uplinkSlow = false
        serverSlow = false
        progressOffset = -1
        val token = ++connection
        opens.addLast(platform.elapsedMs())
        events = LiveTranslateEvents()
        markers.clear()
        val next: LiveTransport
        try {
            next = platform.transport(config, Listener(token))
            next.connect(config, key)
        } catch (e: LiveTranslateException) {
            return e.message.orEmpty()
        }
        transport = next
        playback = if (config.audioOutput && !speechOff) LiveTranslatePlaybackQueue(config.playbackTiming) else null
        return null
    }

    /** The earliest time a connection may open: after a rate-limit wait, and within the per-minute budget. */
    private fun earliestOpen(): Long {
        val now = platform.elapsedMs()
        while (opens.isNotEmpty() && opens.first() <= now - CONNECTION_WINDOW_MS) opens.removeFirst()
        val window = if (opens.size >= MAX_CONNECTIONS_PER_WINDOW) opens[opens.size - MAX_CONNECTIONS_PER_WINDOW] + CONNECTION_WINDOW_MS else now
        return maxOf(now, window, limitedUntil)
    }

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

        override fun onEvent(event: LiveSessionEvent) {
            if (token == connection) received(event)
        }

        override fun onEnd(error: String?, recoverable: Boolean, cause: EndCause) {
            if (token == connection) ended(error, recoverable, cause)
        }
    }

    /** Opens the microphone; until a connection is ready its chunks wait in the gap buffer. */
    private fun beginCapture() {
        val generation = synchronized(audioLock) {
            live = null
            buffering = true
            gap.clear()
            gapBytes = 0
            resetShedding()
            ++capture
        }
        try {
            platform.startCapture(
                { pcm -> chunk(generation, pcm) },
                { message -> platform.post { if (generation == capture) captureInterrupted(message) } },
            )
        } catch (e: Exception) {
            end((e as? LiveTranslateException)?.message ?: "无法打开麦克风")
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
            while (gap.isNotEmpty()) {
                if (current.append(gap.removeFirst()) != AppendResult.SENT) break
            }
            gap.clear()
            gapBytes = 0
            resetShedding()
            buffering = false
            live = current
            windowStartMs = platform.elapsedMs()
            windowStartQueue = current.queuedAudioBytes
            windowSent = 0
            windowCaptured = 0
        }
    }

    /** Under [audioLock]. */
    private fun resetShedding() {
        shedding = false
        droppedBytes = 0
        stallReported = false
    }

    private fun ready() {
        val current = transport ?: return
        when (snapshot.state) {
            SessionState.CONNECTING -> {
                attach(current)
                // After capture: the platform has settled its audio routing (e.g. a Bluetooth headset) by now.
                if (config.audioOutput) startSpeech()
                update { it.copy(state = SessionState.RECORDING, status = recordingStatus()) }
            }
            SessionState.RECONNECTING -> {
                attach(current)
                stable = platform.schedule(STABLE_MS) {
                    attempts = 0
                    limits = 0
                }
                val renewed = quiet
                quiet = false
                update {
                    it.copy(
                        state = SessionState.RECORDING, status = recordingStatus(),
                        notice = if (renewed) it.notice else "已重新连接；中断期间的内容可能有缺失",
                    )
                }
            }
            else -> Unit
        }
    }

    private fun recordingStatus() = "正在转写 → ${config.languageName}"

    /** Capture thread. */
    private fun chunk(generation: Int, pcm: ByteArray) {
        val notify = ArrayList<() -> Unit>(2)
        synchronized(audioLock) {
            if (generation != capture) return
            val target = live
            if (target == null) {
                if (buffering) keep(pcm)
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
                when (target.append(pcm)) {
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
        if (buffering) keep(pcm)
    }

    private fun keep(pcm: ByteArray) {
        gap.addLast(pcm)
        gapBytes += pcm.size
        while (gapBytes > CATCH_UP_AUDIO_BYTES && gap.size > 1) gapBytes -= gap.removeFirst().size
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
        markers += events.order.lastOrNull() to SubtitleRow("congestion:${markerCount++}", "", true, "", true, congestionMarker(seconds))
        update { it.copy(slowNetwork = false) }
        publish()
    }

    /** The backlog has not gone down for [STALL_MS]: the connection is not usable any more. */
    private fun stalled(generation: Int, target: LiveTransport) {
        if (!current(generation, target)) return
        if (autoReconnect) {
            interrupt("网络发送长时间停滞", "上行发送停滞超过 ${STALL_MS / 1000} 秒")
        } else {
            end("网络发送长时间停滞，已停止录音；已有文字已保留")
        }
    }

    private fun received(event: LiveSessionEvent) {
        when (event) {
            is LiveSessionEvent.SpeechStart -> observeProgress(event.milliseconds)
            is LiveSessionEvent.SpeechEnd -> observeProgress(event.milliseconds)
            else -> Unit
        }
        events.apply(event)
        playback?.let { queue ->
            try {
                for (pcm in queue.consume(event, events)) {
                    if (speech?.append(pcm) == false) {
                        interruptPlayback("译音播放积压超过 30 秒，已停止播放；字幕继续更新")
                        break
                    }
                }
            } catch (e: LiveTranslateException) {
                interruptPlayback(e.message.orEmpty())
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
        }
        publish()
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
        if (limited && limits <= RATE_LIMIT_DELAYS_MS.size) limitedUntil = platform.elapsedMs() + RATE_LIMIT_DELAYS_MS[limits - 1]
        val again = recoverable && (!limited || limits <= RATE_LIMIT_DELAYS_MS.size)
        val failure = if (limited && !again) "LiveTranslate 持续限流，已停止录音；已有文字已保留" else error
        when (snapshot.state) {
            SessionState.RECORDING -> when {
                !again || !autoReconnect -> end(failure)
                cause.kind == EndCause.Kind.NO_RESULT -> renew(cause.detail)
                else -> interrupt(error.orEmpty(), cause.detail, counted = !limited)
            }
            SessionState.RECONNECTING -> if (again) {
                lastError = error.orEmpty()
                lastCause = cause.detail
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
            history.add(SubtitleRow("break:$epoch", "", true, "", true, BREAK_MARKER))
        }
    }

    /** Stops sending to the current connection; capture keeps running into the gap buffer. */
    private fun detach() {
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
    private fun interrupt(reason: String, cause: String = reason, counted: Boolean = true) {
        detach()
        markBreak()
        quiet = false
        lastError = reason
        lastCause = cause
        update { it.copy(state = SessionState.RECONNECTING, slowNetwork = false, slowService = false, notice = "") }
        publish()
        attempt(counted = counted)
    }

    /**
     * The service closed a connection that heard nothing it could transcribe for 60 s (a long silence):
     * replace it right away without a marker; this is not a failed attempt.
     */
    private fun renew(cause: String) {
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
            update { it.copy(status = "网络已断开，等待恢复…") }
            if (giveUp == null) {
                giveUp = platform.schedule(OFFLINE_GIVE_UP_MS) { end("网络长时间不可用，已停止录音；已有文字已保留") }
            }
            return
        }
        var delay = 0L
        if (counted) {
            if (attempts >= RECONNECT_DELAYS_MS.size) {
                end("多次重新连接失败，已停止录音。$lastError")
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
            open()?.let(::end)
        }
        when {
            at > now + delay -> countdown(at, if (at == limitedUntil) "服务限流" else "连接过于频繁")
            quiet -> update { it.copy(status = "长时间无识别结果，正在续接连接…") }
            else -> update { it.copy(status = reconnectStatus()) }
        }
    }

    private fun reconnectStatus(): String {
        val base = if (attempts > 0) "连接中断，正在重新连接（第 $attempts 次）…" else "连接中断，正在重新连接…"
        return if (lastCause.isEmpty()) base else "$base 原因：$lastCause"
    }

    /** "服务限流，N 秒后重试", updated every second until the connection opens at [at]. */
    private fun countdown(at: Long, label: String) {
        val left = at - platform.elapsedMs()
        val shown = seconds(left)
        update { it.copy(status = "$label，$shown 秒后重试") }
        if (shown > 1) ticker = platform.schedule(left - (shown - 1) * 1000L) { countdown(at, label) }
    }

    private fun seconds(ms: Long) = ((ms + 999) / 1000).toInt()

    private fun startSpeech() {
        try {
            speech = platform.speech().also { it.start(config.volume) }
            update { it.copy(playing = true) }
        } catch (_: Exception) {
            stopPlayback()
            update { it.copy(notice = "无法启动译音播放，仅显示字幕") }
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
            gapBytes = 0
            resetShedding()
        }
    }

    private fun end(error: String?) {
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
        update { it.copy(state = SessionState.IDLE, status = "", error = error.orEmpty(), slowNetwork = false, slowService = false) }
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
        return SubtitleRow("$epoch:${row.id}", row.source.text, row.source.done, translation.text, translation.done)
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
            SubtitleRow("$epoch:out:$id", "", frozen && part.done, part.text, part.done)
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
