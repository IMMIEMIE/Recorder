package com.localrecorder.live

import org.json.JSONObject

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
    fun transport(listener: LiveTranslateClient.Listener): LiveTransport

    /** Starts 16 kHz mono PCM16 capture; both callbacks may run on a capture thread. Throws when unavailable. */
    fun startCapture(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit)

    /** Returns after the last chunk has been delivered. */
    fun stopCapture()
    fun speech(): SpeechOutput

    /** Foreground service, network monitoring. Throws when the session may not start now. */
    fun sessionActive(active: Boolean)
}

/**
 * The session state machine behind the UI: one user session spans one or more LiveTranslate
 * connections. A dropped connection is replaced by a new one (rows received so far are kept and
 * the break is marked) while capture keeps running. All methods must be called on the session
 * thread; transcripts live only in memory.
 */
class LiveSession(private val platform: SessionPlatform, private val onChange: (SessionSnapshot) -> Unit) {
    companion object {
        val RECONNECT_DELAYS_MS = longArrayOf(500, 1_000, 2_000, 4_000, 8_000)
        const val OFFLINE_GIVE_UP_MS = 60_000L

        /** A reconnected session that lasts this long resets the attempt counter. */
        const val STABLE_MS = 30_000L

        /** Speech captured while reconnecting is kept (most recent 5 s) and sent first. */
        const val MAX_GAP_AUDIO_BYTES = LiveTranslateConfig.INPUT_SAMPLE_RATE * 2 * 5
        const val SLOW_AUDIO_BYTES = LiveTranslateConfig.INPUT_SAMPLE_RATE * 2 * 3
        const val RECOVERED_AUDIO_BYTES = LiveTranslateConfig.INPUT_SAMPLE_RATE * 2

        /** Rows still tracked by ID for the live connection; older ones are frozen into the history. */
        const val MAX_ACTIVE_ROWS = 200
        const val MAX_ROWS = 1_000
        const val BREAK_MARKER = "连接中断，此处内容可能有缺失"
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
    private var online = true
    private var network: Long? = null
    private var retry: Cancellable? = null
    private var giveUp: Cancellable? = null
    private var stable: Cancellable? = null

    // Shared with the capture thread.
    private val audioLock = Any()
    private var capture = 0
    private var capturing = false
    private var live: LiveTransport? = null
    private var buffering = false
    private val gap = ArrayDeque<ByteArray>()
    private var gapBytes = 0
    private var slow = false

    /** Starts a session; the caller has already obtained the microphone permission. */
    fun start(config: LiveTranslateConfig, key: String, autoReconnect: Boolean = true) {
        if (snapshot.state != SessionState.IDLE) return
        this.config = config
        this.key = key
        this.autoReconnect = autoReconnect
        attempts = 0
        online = true
        network = null
        stopPlayback()
        speechOff = false
        open()?.let { failure ->
            update { it.copy(error = failure) }
            return
        }
        update { it.copy(state = SessionState.CONNECTING, status = "正在连接 LiveTranslate…", error = "", notice = "") }
        try {
            platform.sessionActive(true)
        } catch (_: Exception) {
            end("无法启动前台录音服务，请在应用位于前台时开始")
        }
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
        val token = ++connection
        events = LiveTranslateEvents()
        val next = platform.transport(Listener(token))
        try {
            next.connect(config, key)
        } catch (e: LiveTranslateException) {
            return e.message.orEmpty()
        }
        transport = next
        playback = if (config.audioOutput && !speechOff) LiveTranslatePlaybackQueue(config.playbackTiming) else null
        return null
    }

    private fun dropTransport() {
        retry?.cancel()
        retry = null
        transport?.cancel()
        transport = null
        connection++
    }

    private inner class Listener(private val token: Int) : LiveTranslateClient.Listener {
        override fun onReady() {
            if (token == connection) ready()
        }

        override fun onEvent(event: JSONObject) {
            if (token == connection) received(event)
        }

        override fun onEnd(error: String?, recoverable: Boolean) {
            if (token == connection) ended(error, recoverable)
        }
    }

    private fun ready() {
        val current = transport ?: return
        when (snapshot.state) {
            SessionState.CONNECTING -> {
                val generation = synchronized(audioLock) {
                    live = current
                    buffering = false
                    gap.clear()
                    gapBytes = 0
                    slow = false
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
                // After capture: the platform has settled its audio routing (e.g. a Bluetooth headset) by now.
                if (config.audioOutput) startSpeech()
                update { it.copy(state = SessionState.RECORDING, status = recordingStatus()) }
            }
            SessionState.RECONNECTING -> {
                synchronized(audioLock) {
                    // Speech captured during the gap goes first, in order.
                    while (gap.isNotEmpty()) {
                        if (current.append(gap.removeFirst()) != AppendResult.SENT) break
                    }
                    gap.clear()
                    gapBytes = 0
                    buffering = false
                    live = current
                }
                stable = platform.schedule(STABLE_MS) { attempts = 0 }
                update { it.copy(state = SessionState.RECORDING, status = recordingStatus(), notice = "已重新连接；中断期间的内容可能有缺失") }
            }
            else -> Unit
        }
    }

    private fun recordingStatus() = "正在转写 → ${config.languageName}"

    /** Capture thread. */
    private fun chunk(generation: Int, pcm: ByteArray) {
        var full: LiveTransport? = null
        var slowChanged: Boolean? = null
        synchronized(audioLock) {
            if (generation != capture) return
            val target = live
            if (target == null) {
                if (buffering) keep(pcm)
                return
            }
            when (target.append(pcm)) {
                AppendResult.SENT -> {
                    val queued = target.queuedAudioBytes
                    if (!slow && queued > SLOW_AUDIO_BYTES) {
                        slow = true
                        slowChanged = true
                    } else if (slow && queued < RECOVERED_AUDIO_BYTES) {
                        slow = false
                        slowChanged = false
                    }
                }
                // FULL: the socket is not draining. CLOSED: it ended and onEnd is on its way.
                // Either way keep the audio for the connection that replaces it.
                AppendResult.FULL -> {
                    full = target
                    hold(pcm)
                }
                AppendResult.CLOSED -> hold(pcm)
            }
        }
        full?.let { stuck -> platform.post { backlog(stuck) } }
        slowChanged?.let { value ->
            platform.post { if (generation == capture && snapshot.state == SessionState.RECORDING) update { it.copy(slowNetwork = value) } }
        }
    }

    private fun hold(pcm: ByteArray) {
        live = null
        buffering = autoReconnect
        if (buffering) keep(pcm)
    }

    private fun keep(pcm: ByteArray) {
        gap.addLast(pcm)
        gapBytes += pcm.size
        while (gapBytes > MAX_GAP_AUDIO_BYTES && gap.size > 1) gapBytes -= gap.removeFirst().size
    }

    private fun backlog(stuck: LiveTransport) {
        if (stuck !== transport || snapshot.state != SessionState.RECORDING) return
        val message = "网络发送积压过多，已停止录音；已有文字已保留"
        if (autoReconnect) interrupt(message) else end(message)
    }

    private fun received(event: JSONObject) {
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
        for (id in order.take((order.size - MAX_ACTIVE_ROWS).coerceAtLeast(0))) {
            events.rows[id]?.let { row -> subtitle(row)?.let(history::add) }
            events.retire(id)
        }
        publish()
    }

    private fun ended(error: String?, recoverable: Boolean) {
        when (snapshot.state) {
            SessionState.RECORDING -> if (recoverable && autoReconnect) interrupt(error.orEmpty()) else end(error)
            SessionState.RECONNECTING -> if (recoverable) {
                lastError = error.orEmpty()
                dropTransport()
                attempt()
            } else {
                end(error)
            }
            else -> end(error)
        }
    }

    /** The connection of a running session is gone: keep capturing and replace it. */
    private fun interrupt(reason: String) {
        stable?.cancel()
        stable = null
        synchronized(audioLock) {
            live = null
            buffering = true
            slow = false
        }
        dropTransport()
        freeze()
        if (history.lastOrNull()?.marker.isNullOrEmpty()) {
            history.add(SubtitleRow("break:$epoch", "", true, "", true, BREAK_MARKER))
        }
        lastError = reason
        update { it.copy(state = SessionState.RECONNECTING, slowNetwork = false, notice = "") }
        publish()
        attempt()
    }

    private fun attempt(immediately: Boolean = false) {
        retry?.cancel()
        retry = null
        if (!online) {
            update { it.copy(status = "网络已断开，等待恢复…") }
            if (giveUp == null) {
                giveUp = platform.schedule(OFFLINE_GIVE_UP_MS) { end("网络长时间不可用，已停止录音；已有文字已保留") }
            }
            return
        }
        if (attempts >= RECONNECT_DELAYS_MS.size) {
            end("多次重新连接失败，已停止录音。$lastError")
            return
        }
        val delay = if (immediately) 0 else RECONNECT_DELAYS_MS[attempts]
        attempts++
        update { it.copy(status = "连接中断，正在重新连接（第 $attempts 次）…") }
        retry = platform.schedule(delay) {
            retry = null
            open()?.let(::end)
        }
    }

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
            slow = false
        }
    }

    private fun end(error: String?) {
        giveUp?.cancel()
        giveUp = null
        stable?.cancel()
        stable = null
        stopCapture()
        dropTransport()
        playback = null
        freeze()
        // Speech already received plays out; a new session or "stop playback" cuts it short.
        speech?.let { current ->
            current.finish { platform.post { if (speech === current) stopPlayback() } }
        }
        update { it.copy(state = SessionState.IDLE, status = "", error = error.orEmpty(), slowNetwork = false) }
        publish()
        try {
            platform.sessionActive(false)
        } catch (_: Exception) {
        }
    }

    /** Moves the current connection's rows into the history; later connections append below them. */
    private fun freeze() {
        history.addAll(currentRows())
        events = LiveTranslateEvents()
        epoch++
    }

    private fun subtitle(row: LiveTranslateEvents.Row): SubtitleRow? {
        val translation = events.translation(row)
        if (row.source.text.isEmpty() && translation.text.isEmpty()) return null
        return SubtitleRow("$epoch:${row.id}", row.source.text, row.source.done, translation.text, translation.done)
    }

    private fun currentRows(): List<SubtitleRow> {
        val rows = events.order.mapNotNull { id -> events.rows[id]?.let(::subtitle) }
        // Translations whose source association has not arrived yet.
        val pending = events.unmatchedOutputs.map { (id, part) ->
            SubtitleRow("$epoch:out:$id", "", false, part.text, part.done)
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
