package com.localrecorder.live

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Drives the session state machine with fake transports, capture and a virtual clock (no threads, no network). */
class LiveSessionTest {
    private class FakeTransport(val listener: LiveTranslateClient.Listener) : LiveTransport {
        var connected = false
        var finished = false
        var cancelled = false
        var result = AppendResult.SENT
        val audio = mutableListOf<ByteArray>()
        override var queuedAudioBytes = 0

        override fun connect(configuration: LiveTranslateConfig, key: String) {
            if (key.isEmpty()) throw LiveTranslateException("请在 LiveTranslate 设置中保存专用 API Key")
            connected = true
        }

        override fun append(pcm: ByteArray): AppendResult {
            if (result == AppendResult.SENT) audio.add(pcm)
            return result
        }

        override fun finish() { finished = true }
        override fun cancel() { cancelled = true }
    }

    private class FakeSpeech : SpeechOutput {
        var started = false
        var stopped = false
        var accept = true
        var bytes = 0
        var drained: (() -> Unit)? = null
        override fun start(volume: Float) { started = true }
        override fun append(pcm: ByteArray): Boolean {
            if (accept) bytes += pcm.size
            return accept
        }
        override fun finish(done: () -> Unit) { drained = done }
        override fun stop() { stopped = true }
    }

    private class Device : SessionPlatform {
        private class Timer(val at: Long, val block: () -> Unit, var cancelled: Boolean = false)

        private val posted = ArrayDeque<() -> Unit>()
        private val timers = mutableListOf<Timer>()
        private var now = 0L
        val transports = mutableListOf<FakeTransport>()
        val speeches = mutableListOf<FakeSpeech>()
        var onChunk: ((ByteArray) -> Unit)? = null
        var onError: ((String) -> Unit)? = null
        var captureStarts = 0
        var captureFails = false
        var active = false
        val snapshots = mutableListOf<SessionSnapshot>()
        val session = LiveSession(this) { snapshots.add(it) }

        val transport get() = transports.last()
        val state get() = session.snapshot.state

        override fun post(block: () -> Unit) { posted.addLast(block) }
        override fun schedule(delayMs: Long, block: () -> Unit): Cancellable {
            val timer = Timer(now + delayMs, block)
            timers.add(timer)
            return Cancellable { timer.cancelled = true }
        }
        override fun transport(listener: LiveTranslateClient.Listener) = FakeTransport(listener).also(transports::add)
        override fun startCapture(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit) {
            if (captureFails) throw LiveTranslateException("无法打开麦克风，请检查录音权限或是否被其他应用占用")
            captureStarts++
            this.onChunk = onChunk
            this.onError = onError
        }
        override fun stopCapture() { onChunk = null }
        override fun speech(): SpeechOutput = FakeSpeech().also(speeches::add)
        override fun sessionActive(active: Boolean) { this.active = active }

        fun run() {
            while (posted.isNotEmpty()) posted.removeFirst()()
        }

        fun advance(ms: Long) {
            val until = now + ms
            run()
            while (true) {
                val next = timers.filter { !it.cancelled && it.at <= until }.minByOrNull { it.at } ?: break
                timers.remove(next)
                now = next.at
                next.block()
                run()
            }
            now = until
        }

        fun speak(bytes: Int = 3200, fill: Int = 0) {
            onChunk!!(ByteArray(bytes) { fill.toByte() })
            run()
        }

        fun record(config: LiveTranslateConfig = LiveTranslateConfig(), autoReconnect: Boolean = true) {
            session.start(config, "mock-only", autoReconnect)
            transport.listener.onReady()
            assertEquals(SessionState.RECORDING, state)
        }

        /** One complete utterance on the current connection. */
        fun utter(id: String, source: String = "Hello.", translation: String = "你好。") {
            val listener = transport.listener
            listener.onEvent(json("type" to "conversation.item.created", "previous_item_id" to id, "item" to json("id" to "$id-out", "role" to "assistant")))
            listener.onEvent(json("type" to "conversation.item.input_audio_transcription.completed", "item_id" to id, "transcript" to source))
            listener.onEvent(json("type" to "response.text.done", "item_id" to "$id-out", "text" to translation))
        }
    }

    private companion object {
        fun json(vararg pairs: Pair<String, Any>): JSONObject = JSONObject().apply { pairs.forEach { put(it.first, it.second) } }
        const val LOST = "LiveTranslate 连接中断或无法连接，请检查网络、服务地址及 API Key；已有文字已保留"
    }

    @Test
    fun plainSessionKeepsRowsAndDrainsTail() {
        val device = Device()
        device.session.start(LiveTranslateConfig(), "")
        assertEquals("missing key reported before anything starts", SessionState.IDLE, device.state)
        assertTrue(device.session.snapshot.error.contains("API Key"))
        assertFalse(device.active)

        device.session.start(LiveTranslateConfig(language = "en"), "mock-only")
        assertEquals(SessionState.CONNECTING, device.state)
        assertTrue(device.active && device.transport.connected)
        assertEquals("", device.session.snapshot.error)
        assertNull("no capture before the configuration is acknowledged", device.onChunk)
        device.transport.listener.onReady()
        assertEquals(SessionState.RECORDING, device.state)
        assertTrue(device.session.snapshot.status.contains("English"))
        device.speak()
        device.utter("a")
        device.transport.listener.onEvent(json("type" to "conversation.item.input_audio_transcription.delta", "item_id" to "b", "delta" to "Tail"))
        assertEquals(1, device.transport.audio.size)

        device.session.stop()
        assertEquals(SessionState.FINISHING, device.state)
        assertNull("capture stopped before session.finish", device.onChunk)
        assertTrue(device.transport.finished)
        device.transport.listener.onEvent(json("type" to "conversation.item.input_audio_transcription.completed", "item_id" to "b", "transcript" to "Tail."))
        device.transport.listener.onEnd(null, false)
        assertEquals(SessionState.IDLE, device.state)
        assertFalse(device.active)
        assertEquals("", device.session.snapshot.error)
        assertEquals(listOf("Hello.", "Tail."), device.session.snapshot.rows.map { it.source })
        assertEquals("Hello.\n你好。\n\nTail.", device.session.exportText())

        // A second session appends below the first; clearing needs an idle session.
        device.record()
        device.utter("a", "Again.", "再来。")
        device.session.clear()
        device.session.stop()
        device.transport.listener.onEnd(null, false)
        val rows = device.session.snapshot.rows
        assertEquals(listOf("Hello.", "Tail.", "Again."), rows.map { it.source })
        assertEquals("row keys stay unique across sessions", rows.size, rows.map { it.key }.toSet().size)
        device.session.clear()
        assertTrue(device.session.snapshot.rows.isEmpty())
    }

    @Test
    fun droppedConnectionIsReplacedWithoutLosingSpeech() {
        val device = Device()
        device.record()
        device.utter("a")
        val first = device.transport
        first.listener.onEvent(json("type" to "conversation.item.input_audio_transcription.delta", "item_id" to "b", "delta" to "Half a sent"))
        // The socket dies: audio is refused before the end callback arrives.
        first.result = AppendResult.CLOSED
        device.speak(fill = 1)
        first.listener.onEnd(LOST, true)
        assertEquals(SessionState.RECONNECTING, device.state)
        assertTrue("capture keeps running", device.onChunk != null && device.active)
        assertEquals(BREAK, device.session.snapshot.rows.last().marker)
        assertEquals("Half a sent", device.session.snapshot.rows[1].source)
        assertSame("no new connection before the backoff", first, device.transport)

        device.speak(fill = 2)
        device.advance(LiveSession.RECONNECT_DELAYS_MS[0])
        val second = device.transport
        assertTrue(second !== first && second.connected)
        assertEquals(SessionState.RECONNECTING, device.state)
        device.speak(fill = 3)
        // Late callbacks of the dead connection are ignored.
        first.listener.onEvent(json("type" to "conversation.item.input_audio_transcription.delta", "item_id" to "b", "delta" to " stale"))
        first.listener.onEnd("stale", false)
        assertEquals(SessionState.RECONNECTING, device.state)

        second.listener.onReady()
        assertEquals(SessionState.RECORDING, device.state)
        assertEquals("one capture for the whole session", 1, device.captureStarts)
        device.speak(fill = 4)
        assertEquals("gap audio first, in order, then live audio", listOf(1, 2, 3, 4), second.audio.map { it[0].toInt() })
        assertTrue(device.session.snapshot.notice.contains("已重新连接"))

        device.utter("a", "After.", "之后。")
        val rows = device.session.snapshot.rows
        assertEquals(listOf("Hello.", "Half a sent", "", "After."), rows.map { it.source })
        assertEquals("same item IDs on a new connection get new keys", rows.size, rows.map { it.key }.toSet().size)
        assertTrue(device.session.exportText().contains("【$BREAK】"))

        device.session.stop()
        second.listener.onEnd(null, false)
        assertEquals(SessionState.IDLE, device.state)
        assertEquals(4, device.session.snapshot.rows.size)
    }

    @Test
    fun gapAudioIsBoundedToTheMostRecent() {
        val device = Device()
        device.record()
        device.transport.listener.onEnd(LOST, true)
        repeat(80) { device.speak(fill = it) } // 8 s of 100 ms chunks
        device.advance(LiveSession.RECONNECT_DELAYS_MS[0])
        device.transport.listener.onReady()
        val sent = device.transport.audio
        assertEquals(LiveSession.MAX_GAP_AUDIO_BYTES, sent.sumOf { it.size })
        assertEquals("oldest audio dropped", 30, sent.first()[0].toInt())
        assertEquals(79, sent.last()[0].toInt())
    }

    @Test
    fun reconnectGivesUpAfterRepeatedFailures() {
        val device = Device()
        device.record()
        device.transport.listener.onEnd(LOST, true)
        for (delay in LiveSession.RECONNECT_DELAYS_MS) {
            assertEquals(SessionState.RECONNECTING, device.state)
            val before = device.transports.size
            device.advance(delay - 1)
            assertEquals("backoff respected", before, device.transports.size)
            device.advance(1)
            assertEquals(before + 1, device.transports.size)
            device.transport.listener.onEnd(LOST, true)
        }
        assertEquals(SessionState.IDLE, device.state)
        assertTrue(device.session.snapshot.error.startsWith("多次重新连接失败"))
        assertNull(device.onChunk)
        assertFalse(device.active)
        assertEquals("one marker for one break", 1, device.session.snapshot.rows.count { it.marker.isNotEmpty() })

        // A session that stays up resets the counter; a short-lived one does not.
        val steady = Device()
        steady.record()
        repeat(3) {
            steady.transport.listener.onEnd(LOST, true)
            steady.advance(LiveSession.RECONNECT_DELAYS_MS[0])
            steady.transport.listener.onReady()
            steady.advance(LiveSession.STABLE_MS)
        }
        steady.transport.listener.onEnd(LOST, true)
        assertTrue(steady.session.snapshot.status.contains("第 1 次"))
        val flapping = Device()
        flapping.record()
        flapping.transport.listener.onEnd(LOST, true)
        flapping.advance(LiveSession.RECONNECT_DELAYS_MS[0])
        flapping.transport.listener.onReady()
        flapping.transport.listener.onEnd(LOST, true)
        assertTrue(flapping.session.snapshot.status.contains("第 2 次"))
        assertEquals("consecutive breaks share one marker", 1, flapping.session.snapshot.rows.count { it.marker.isNotEmpty() })
    }

    @Test
    fun fatalErrorsAndDisabledReconnectEndTheSession() {
        val fatal = Device()
        fatal.record()
        fatal.utter("a")
        fatal.transport.listener.onEnd("LiveTranslate 请求受限或额度不足，请检查账户余额并稍后重试", false)
        assertEquals(SessionState.IDLE, fatal.state)
        assertTrue(fatal.session.snapshot.error.contains("额度不足"))
        assertEquals(1, fatal.session.snapshot.rows.size)
        assertEquals(1, fatal.transports.size)

        val manual = Device()
        manual.record(autoReconnect = false)
        manual.transport.listener.onEnd(LOST, true)
        assertEquals(SessionState.IDLE, manual.state)
        assertEquals(LOST, manual.session.snapshot.error)

        // A reconnect that is refused (e.g. the key was revoked meanwhile) is not retried.
        val refused = Device()
        refused.record()
        refused.transport.listener.onEnd(LOST, true)
        refused.advance(LiveSession.RECONNECT_DELAYS_MS[0])
        refused.transport.listener.onEnd("LiveTranslate API Key 无效或无权访问，请核对密钥、区域和工作空间", false)
        assertEquals(SessionState.IDLE, refused.state)
        assertEquals(2, refused.transports.size)

        // The first connection of a session is never retried: the user is watching and may fix the settings.
        val initial = Device()
        initial.session.start(LiveTranslateConfig(), "mock-only")
        initial.transport.listener.onEnd(LOST, true)
        assertEquals(SessionState.IDLE, initial.state)
        assertEquals(LOST, initial.session.snapshot.error)
        initial.advance(60_000)
        assertEquals(1, initial.transports.size)
    }

    @Test
    fun stopWhileReconnectingEndsQuietly() {
        val device = Device()
        device.record()
        device.transport.listener.onEnd(LOST, true)
        device.session.stop()
        assertEquals(SessionState.IDLE, device.state)
        assertEquals("", device.session.snapshot.error)
        assertNull(device.onChunk)
        device.advance(60_000)
        assertEquals("pending retry cancelled", 1, device.transports.size)

        val connecting = Device()
        connecting.record()
        connecting.transport.listener.onEnd(LOST, true)
        connecting.advance(LiveSession.RECONNECT_DELAYS_MS[0])
        connecting.session.stop()
        assertTrue(connecting.transport.cancelled)
        connecting.transport.listener.onReady()
        assertEquals(SessionState.IDLE, connecting.state)
    }

    @Test
    fun networkChangesDriveReconnect() {
        val device = Device()
        device.record()
        device.session.networkAvailable(1)
        assertEquals("the network in use at the start is not a switch", SessionState.RECORDING, device.state)
        val wifi = device.transport

        // Wi-Fi to mobile data: replace the connection right away instead of waiting for a timeout.
        device.session.networkAvailable(2)
        assertEquals(SessionState.RECONNECTING, device.state)
        assertTrue(wifi.cancelled)
        device.advance(LiveSession.RECONNECT_DELAYS_MS[0])
        device.transport.listener.onReady()
        assertEquals(SessionState.RECORDING, device.state)

        // No network at all: wait instead of burning attempts, then connect as soon as it is back.
        device.session.networkLost()
        assertEquals(SessionState.RECONNECTING, device.state)
        assertTrue(device.session.snapshot.status.contains("等待恢复"))
        val before = device.transports.size
        device.advance(LiveSession.OFFLINE_GIVE_UP_MS - 1)
        assertEquals(before, device.transports.size)
        device.session.networkAvailable(3)
        device.advance(0)
        assertEquals(before + 1, device.transports.size)
        device.transport.listener.onReady()
        assertEquals(SessionState.RECORDING, device.state)
        device.advance(LiveSession.OFFLINE_GIVE_UP_MS)
        assertEquals("give-up timer cancelled once online", SessionState.RECORDING, device.state)

        device.session.networkLost()
        device.advance(LiveSession.OFFLINE_GIVE_UP_MS)
        assertEquals(SessionState.IDLE, device.state)
        assertTrue(device.session.snapshot.error.contains("网络长时间不可用"))

        // The network drops while a reconnect attempt is in flight.
        val flight = Device()
        flight.record()
        flight.transport.listener.onEnd(LOST, true)
        flight.advance(LiveSession.RECONNECT_DELAYS_MS[0])
        val pending = flight.transport
        flight.session.networkLost()
        assertTrue(pending.cancelled)
        pending.listener.onReady()
        assertEquals(SessionState.RECONNECTING, flight.state)
        flight.session.networkAvailable(9)
        flight.advance(0)
        flight.transport.listener.onReady()
        assertEquals(SessionState.RECORDING, flight.state)

        val manual = Device()
        manual.record(autoReconnect = false)
        manual.session.networkAvailable(1)
        manual.session.networkAvailable(2)
        manual.session.networkLost()
        assertEquals("without auto-reconnect only a real failure ends the session", SessionState.RECORDING, manual.state)
    }

    @Test
    fun backlogWarnsThenReconnects() {
        val device = Device()
        device.record()
        device.transport.queuedAudioBytes = LiveSession.SLOW_AUDIO_BYTES + 1
        device.speak()
        assertTrue(device.session.snapshot.slowNetwork)
        device.transport.queuedAudioBytes = LiveSession.RECOVERED_AUDIO_BYTES
        device.speak()
        assertTrue("hysteresis", device.session.snapshot.slowNetwork)
        device.transport.queuedAudioBytes = LiveSession.RECOVERED_AUDIO_BYTES - 1
        device.speak()
        assertFalse(device.session.snapshot.slowNetwork)

        val stuck = device.transport
        stuck.result = AppendResult.FULL
        device.speak(fill = 7)
        assertEquals(SessionState.RECONNECTING, device.state)
        assertTrue(stuck.cancelled)
        device.advance(LiveSession.RECONNECT_DELAYS_MS[0])
        device.transport.listener.onReady()
        assertEquals("the refused chunk is sent on the new connection", listOf(7), device.transport.audio.map { it[0].toInt() })

        val manual = Device()
        manual.record(autoReconnect = false)
        manual.transport.result = AppendResult.FULL
        manual.speak()
        assertEquals(SessionState.IDLE, manual.state)
        assertTrue(manual.session.snapshot.error.contains("积压"))
    }

    @Test
    fun captureFailuresEndTheSession() {
        val denied = Device()
        denied.captureFails = true
        denied.session.start(LiveTranslateConfig(), "mock-only")
        denied.transport.listener.onReady()
        assertEquals(SessionState.IDLE, denied.state)
        assertTrue(denied.session.snapshot.error.contains("麦克风"))
        assertTrue(denied.transport.cancelled)

        val device = Device()
        device.record()
        val staleError = device.onError!!
        device.onError!!("麦克风读取失败（-3），已停止录音；已有文字已保留")
        device.run()
        assertEquals(SessionState.IDLE, device.state)
        assertTrue(device.session.snapshot.error.contains("麦克风读取失败"))

        // An error reported by the previous capture must not end the next session.
        device.record()
        staleError("stale")
        device.run()
        assertEquals(SessionState.RECORDING, device.state)
        device.session.captureInterrupted("麦克风被通话或其他应用占用，已停止录音；已有文字已保留")
        assertEquals(SessionState.IDLE, device.state)
        device.session.captureInterrupted("ignored while idle")
        assertTrue(device.session.snapshot.error.contains("通话"))
    }

    @Test
    fun translatedSpeechFollowsTheSession() {
        fun audio(id: String, item: String = "a-out") = json(
            "type" to "response.audio.delta", "event_id" to id, "item_id" to item,
            "delta" to java.util.Base64.getEncoder().encodeToString(ByteArray(480)),
        )
        val device = Device()
        device.record(LiveTranslateConfig(audioOutput = true))
        val speech = device.speeches.single()
        assertTrue(speech.started && device.session.snapshot.playing)
        device.transport.listener.onEvent(audio("1"))
        assertEquals(480, speech.bytes)

        // The player survives a reconnect; the new connection gets a fresh decoder.
        device.transport.listener.onEnd(LOST, true)
        device.advance(LiveSession.RECONNECT_DELAYS_MS[0])
        device.transport.listener.onReady()
        device.transport.listener.onEvent(audio("1"))
        assertEquals(960, speech.bytes)
        assertEquals(1, device.speeches.size)

        // Queued speech plays out after the session ends.
        device.session.stop()
        device.transport.listener.onEnd(null, false)
        assertTrue(device.session.snapshot.playing && !speech.stopped)
        speech.drained!!()
        device.run()
        assertTrue(speech.stopped)
        assertFalse(device.session.snapshot.playing)

        // A player that falls 30 s behind is stopped; subtitles continue.
        device.record(LiveTranslateConfig(audioOutput = true))
        val slow = device.speeches.last()
        slow.accept = false
        device.transport.listener.onEvent(audio("1"))
        assertTrue(slow.stopped && device.session.snapshot.notice.contains("积压"))
        assertEquals(SessionState.RECORDING, device.state)
        device.utter("a")
        assertEquals("你好。", device.session.snapshot.rows.last().translation)
        device.session.stop()
        device.transport.listener.onEnd(null, false)

        // Losing audio focus or pressing "stop playback" silences the rest of the session.
        device.record(LiveTranslateConfig(audioOutput = true))
        val focused = device.speeches.last()
        device.session.interruptPlayback("其他应用占用了音频输出，已停止译音；字幕继续更新")
        assertTrue(focused.stopped && device.session.snapshot.notice.contains("音频输出"))
        device.transport.listener.onEvent(audio("1"))
        assertEquals(0, focused.bytes)
    }

    @Test
    fun longSessionsStayBounded() {
        val device = Device()
        device.record()
        val total = LiveSession.MAX_ROWS + 300
        repeat(total) { device.utter("u$it", "Source $it", "译文 $it") }
        var rows = device.session.snapshot.rows
        assertEquals(LiveSession.MAX_ROWS + LiveSession.MAX_ACTIVE_ROWS, rows.size)
        assertTrue(device.session.snapshot.trimmed)
        assertEquals("Source ${total - 1}", rows.last().source)
        assertEquals("the oldest rows are dropped", "Source ${total - rows.size}", rows.first().source)
        assertEquals(rows.size, rows.map { it.key }.toSet().size)

        // A late duplicate for a row that was frozen must not create a second row.
        device.transport.listener.onEvent(json("type" to "conversation.item.input_audio_transcription.completed", "item_id" to "u${total - 300}", "transcript" to "late"))
        device.transport.listener.onEvent(json("type" to "response.text.delta", "item_id" to "u${total - 300}-out", "delta" to "late"))
        rows = device.session.snapshot.rows
        assertEquals(LiveSession.MAX_ROWS + LiveSession.MAX_ACTIVE_ROWS, rows.size)
        assertFalse(rows.any { it.source == "late" || it.translation.contains("late") })

        device.session.stop()
        device.transport.listener.onEnd(null, false)
        assertEquals(LiveSession.MAX_ROWS, device.session.snapshot.rows.size)
        device.session.clear()
        assertFalse(device.session.snapshot.trimmed)
    }
}

private const val BREAK = LiveSession.BREAK_MARKER
