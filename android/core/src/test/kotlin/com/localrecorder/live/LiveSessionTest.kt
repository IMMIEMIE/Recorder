package com.localrecorder.live

import com.localrecorder.sessions.SessionRecord
import com.localrecorder.sessions.SessionRecorder
import com.localrecorder.sessions.SessionRow
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

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
        var now = 0L
        val transports = mutableListOf<FakeTransport>()
        val openedAt = mutableListOf<Long>()
        val speeches = mutableListOf<FakeSpeech>()
        var onChunk: ((ByteArray) -> Unit)? = null
        var onError: ((String) -> Unit)? = null
        var captureStarts = 0
        var captureFails = false
        var active = false
        val snapshots = mutableListOf<SessionSnapshot>()
        val observers = mutableListOf<(SessionSnapshot) -> Unit>()
        val session = LiveSession(this) { snapshot -> snapshots.add(snapshot); observers.forEach { it(snapshot) } }

        val transport get() = transports.last()
        val state get() = session.snapshot.state

        override fun post(block: () -> Unit) { posted.addLast(block) }
        override fun schedule(delayMs: Long, block: () -> Unit): Cancellable {
            val timer = Timer(now + delayMs, block)
            timers.add(timer)
            return Cancellable { timer.cancelled = true }
        }
        override fun transport(listener: LiveTranslateClient.Listener): FakeTransport {
            openedAt += now
            return FakeTransport(listener).also(transports::add)
        }
        override fun elapsedMs() = now
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
        val RATE_LIMITED = EndCause(EndCause.Kind.RATE_LIMITED, "服务限流：1007 rate limit")
        val NO_RESULT = EndCause(EndCause.Kind.NO_RESULT, "服务端错误：no semantic result")

        /** 100 ms of 16 kHz PCM16, the microphone's chunk size. */
        const val CHUNK = 3200
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
        // The microphone opens on start; speech before the configuration is acknowledged waits, then goes first.
        assertEquals(1, device.captureStarts)
        device.speak(fill = 1)
        assertTrue("nothing sent before ready", device.transport.audio.isEmpty())
        device.transport.listener.onReady()
        assertEquals(SessionState.RECORDING, device.state)
        assertTrue(device.session.snapshot.status.contains("English"))
        device.speak(fill = 2)
        assertEquals(listOf<Byte>(1, 2), device.transport.audio.map { it[0] })
        assertEquals("one capture for the whole session", 1, device.captureStarts)
        device.utter("a")
        device.transport.listener.onEvent(json("type" to "conversation.item.input_audio_transcription.delta", "item_id" to "b", "delta" to "Tail"))
        assertEquals(2, device.transport.audio.size)

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
    fun firstConnectionCatchesUpOnlyTheLastSecond() {
        val device = Device()
        device.session.start(LiveTranslateConfig(), "mock-only")
        assertEquals("正在连接…", device.session.snapshot.status)
        repeat(30) { device.speak(CHUNK, fill = it) } // 3 s before the configuration is acknowledged
        assertTrue(device.transport.audio.isEmpty())
        device.transport.listener.onReady()
        val sent = device.transport.audio
        assertEquals("only the last second goes at once", LiveSession.CATCH_UP_AUDIO_BYTES, sent.sumOf { it.size })
        assertEquals((20..29).toList(), sent.map { it[0].toInt() })
        // Then real time: one chunk per captured chunk.
        device.speak(CHUNK, fill = 30)
        device.speak(CHUNK, fill = 31)
        assertEquals((20..31).toList(), sent.map { it[0].toInt() })
        assertTrue(device.session.snapshot.rows.none { it.marker.isNotEmpty() })
    }

    @Test
    fun reconnectCatchesUpOnlyTheLastSecond() {
        val device = Device()
        device.record()
        device.utter("a")
        device.transport.listener.onEnd(LOST, true, EndCause(detail = "网络故障：SocketException: Connection reset"))
        assertTrue("the cause is shown", device.session.snapshot.status.contains("原因：网络故障：SocketException"))
        repeat(50) { device.speak(CHUNK, fill = it) } // 5 s while reconnecting
        device.advance(LiveSession.RECONNECT_DELAYS_MS[0])
        device.transport.listener.onReady()
        val sent = device.transport.audio
        assertEquals(LiveSession.CATCH_UP_AUDIO_BYTES, sent.sumOf { it.size })
        assertEquals("oldest audio dropped", (40..49).toList(), sent.map { it[0].toInt() })
        assertEquals("the break is still marked", listOf("", BREAK), device.session.snapshot.rows.map { it.marker })
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
    fun backlogIsShedInsteadOfReconnecting() {
        val device = Device()
        device.record()
        device.utter("a")
        val link = device.transport
        link.queuedAudioBytes = LiveSession.SHED_AUDIO_BYTES
        device.speak(CHUNK, fill = 1)
        assertFalse("at the limit still sending", device.session.snapshot.slowNetwork)
        link.queuedAudioBytes = LiveSession.SHED_AUDIO_BYTES + 1
        repeat(20) { device.speak(CHUNK, fill = 2) } // 2 s dropped
        assertTrue(device.session.snapshot.slowNetwork)
        assertEquals("dropped, not sent", listOf(1), link.audio.map { it[0].toInt() })
        link.queuedAudioBytes = LiveSession.RESUME_AUDIO_BYTES
        device.speak(CHUNK, fill = 3)
        assertTrue("hysteresis: still dropping", device.session.snapshot.slowNetwork)
        device.advance(LiveSession.STALL_MS * 3) // no timer replaces the connection; only a chunk checks for a stall
        assertEquals(SessionState.RECORDING, device.state)
        assertEquals("no new connection for a backlog", 1, device.transports.size)

        link.queuedAudioBytes = LiveSession.RESUME_AUDIO_BYTES - 1
        device.speak(CHUNK, fill = 4)
        assertFalse(device.session.snapshot.slowNetwork)
        assertEquals("sending resumes with the current chunk", listOf(1, 4), link.audio.map { it[0].toInt() })
        device.utter("b", "Later.", "之后。")
        val rows = device.session.snapshot.rows
        assertEquals(listOf("", LiveSession.congestionMarker(2), ""), rows.map { it.marker })
        assertEquals(listOf("Hello.", "", "Later."), rows.map { it.source })
        assertTrue(device.session.exportText().contains("【网络拥塞，约 2 秒语音未翻译】"))

        // A chunk the transport refuses outright is dropped the same way.
        link.queuedAudioBytes = 0
        link.result = AppendResult.FULL
        device.speak(CHUNK, fill = 5)
        assertEquals(SessionState.RECORDING, device.state)
        assertTrue(device.session.snapshot.slowNetwork)
        assertEquals(1, device.transports.size)

        // The marker stays where it was when the connection ends.
        link.result = AppendResult.SENT
        device.speak(CHUNK, fill = 6)
        link.listener.onEnd(LOST, true)
        assertEquals(
            listOf("", LiveSession.congestionMarker(2), "", LiveSession.congestionMarker(1), BREAK),
            device.session.snapshot.rows.map { it.marker },
        )
    }

    @Test
    fun stalledBacklogReconnectsAfterTimeout() {
        val device = Device()
        device.record()
        val stuck = device.transport
        stuck.queuedAudioBytes = LiveSession.SHED_AUDIO_BYTES + 1
        device.speak()
        // Draining, however slowly, keeps the connection.
        repeat(5) {
            device.advance(LiveSession.STALL_MS - 1)
            stuck.queuedAudioBytes -= 1
            device.speak()
        }
        assertEquals(SessionState.RECORDING, device.state)
        // Not going down at all for STALL_MS replaces it.
        device.advance(LiveSession.STALL_MS - 1)
        device.speak()
        assertEquals(SessionState.RECORDING, device.state)
        device.advance(1)
        device.speak()
        assertEquals(SessionState.RECONNECTING, device.state)
        assertTrue(stuck.cancelled)
        assertTrue(device.session.snapshot.status.contains("停滞"))
        assertFalse(device.session.snapshot.slowNetwork)
        device.advance(LiveSession.RECONNECT_DELAYS_MS[0])
        device.transport.listener.onReady()
        device.speak(fill = 7)
        assertEquals(listOf(7), device.transport.audio.map { it[0].toInt() })

        val manual = Device()
        manual.record(autoReconnect = false)
        manual.transport.queuedAudioBytes = LiveSession.SHED_AUDIO_BYTES + 1
        manual.speak()
        manual.advance(LiveSession.STALL_MS)
        manual.speak()
        assertEquals(SessionState.IDLE, manual.state)
        assertTrue(manual.session.snapshot.error.contains("停滞"))
    }

    @Test
    fun rateLimitWaitsWithoutBurningAttempts() {
        val device = Device()
        device.record()
        device.transport.listener.onEnd(LiveTranslateClient.RATE_LIMITED_ERROR, true, RATE_LIMITED)
        assertEquals(SessionState.RECONNECTING, device.state)
        assertEquals("服务限流，20 秒后重试", device.session.snapshot.status)
        device.advance(LiveSession.RATE_LIMIT_DELAYS_MS[0] - 1)
        assertEquals("no connection during the wait", 1, device.transports.size)
        assertEquals("the countdown ticks", "服务限流，1 秒后重试", device.session.snapshot.status)
        device.advance(1)
        assertEquals(2, device.transports.size)
        // Limited again before it was ready: the wait doubles.
        device.transport.listener.onEnd(LiveTranslateClient.RATE_LIMITED_ERROR, true, RATE_LIMITED)
        assertEquals("服务限流，40 秒后重试", device.session.snapshot.status)
        device.advance(LiveSession.RATE_LIMIT_DELAYS_MS[1])
        assertEquals(3, device.transports.size)
        device.transport.listener.onReady()
        assertEquals(SessionState.RECORDING, device.state)
        // The rate limits did not use up the ordinary attempts.
        device.transport.listener.onEnd(LOST, true)
        assertTrue(device.session.snapshot.status.contains("第 1 次"))
        assertEquals("one marker for one break", 1, device.session.snapshot.rows.count { it.marker == BREAK })

        // Rate limited on every attempt: the session ends after the last wait, minutes later.
        val limited = Device()
        limited.record()
        for (wait in LiveSession.RATE_LIMIT_DELAYS_MS) {
            limited.transport.listener.onEnd(LiveTranslateClient.RATE_LIMITED_ERROR, true, RATE_LIMITED)
            assertEquals(SessionState.RECONNECTING, limited.state)
            limited.advance(wait)
        }
        limited.transport.listener.onEnd(LiveTranslateClient.RATE_LIMITED_ERROR, true, RATE_LIMITED)
        assertEquals(SessionState.IDLE, limited.state)
        assertTrue(limited.session.snapshot.error.contains("持续限流"))
        assertEquals(LiveSession.RATE_LIMIT_DELAYS_MS.sum(), limited.now)

        // A rate-limited first connection ends the session; starting again right away is refused locally.
        val first = Device()
        first.session.start(LiveTranslateConfig(), "mock-only")
        first.transport.listener.onEnd(LiveTranslateClient.RATE_LIMITED_ERROR, true, RATE_LIMITED)
        assertEquals(SessionState.IDLE, first.state)
        assertTrue(first.session.snapshot.error.contains("限流"))
        first.advance(1_000)
        first.session.start(LiveTranslateConfig(), "mock-only")
        assertEquals(SessionState.IDLE, first.state)
        assertTrue(first.session.snapshot.error.contains("19 秒后再试"))
        assertEquals(1, first.transports.size)
        first.advance(LiveSession.RATE_LIMIT_DELAYS_MS[0])
        first.record()
    }

    @Test
    fun noResultCloseReconnectsQuietly() {
        val device = Device()
        device.record()
        device.utter("a")
        device.transport.listener.onEnd(LiveTranslateClient.NO_RESULT_ERROR, true, NO_RESULT)
        assertEquals(SessionState.RECONNECTING, device.state)
        assertTrue(device.session.snapshot.status.contains("无识别结果"))
        device.advance(0)
        assertEquals("immediately", 2, device.transports.size)
        device.transport.listener.onReady()
        assertEquals(SessionState.RECORDING, device.state)
        assertEquals("", device.session.snapshot.notice)
        assertTrue("no marker", device.session.snapshot.rows.none { it.marker.isNotEmpty() })
        // Not a failed attempt.
        device.transport.listener.onEnd(LOST, true)
        assertTrue(device.session.snapshot.status.contains("第 1 次"))

        // If the quiet replacement fails, it is an ordinary break after all.
        val failing = Device()
        failing.record()
        failing.transport.listener.onEnd(LiveTranslateClient.NO_RESULT_ERROR, true, NO_RESULT)
        failing.advance(0)
        failing.transport.listener.onEnd(LOST, true)
        assertEquals(SessionState.RECONNECTING, failing.state)
        assertEquals(listOf(BREAK), failing.session.snapshot.rows.map { it.marker })
        assertTrue(failing.session.snapshot.status.contains("第 1 次"))
        failing.advance(LiveSession.RECONNECT_DELAYS_MS[0])
        failing.transport.listener.onReady()
        assertTrue(failing.session.snapshot.notice.contains("已重新连接"))
    }

    @Test
    fun connectionsAreCappedPerMinute() {
        // Quiet replacements and network switches are not counted as attempts, so only the cap holds them back.
        val device = Device()
        device.record()
        var round = 0
        while (device.now < 3 * LiveSession.CONNECTION_WINDOW_MS) {
            val link = device.transport
            link.listener.onEnd(LiveTranslateClient.NO_RESULT_ERROR, true, NO_RESULT) // ignored while waiting
            if (round++ % 2 == 1) device.session.networkAvailable(round.toLong())
            device.advance(1_000)
            if (device.transport !== link) device.transport.listener.onReady()
        }
        assertTrue("connections keep opening at the capped pace", device.transports.size >= 3 * LiveSession.MAX_CONNECTIONS_PER_WINDOW)
        val times = device.openedAt
        for (i in 0 until times.size - LiveSession.MAX_CONNECTIONS_PER_WINDOW) {
            assertTrue(
                "at most ${LiveSession.MAX_CONNECTIONS_PER_WINDOW} connections in any minute: $times",
                times[i + LiveSession.MAX_CONNECTIONS_PER_WINDOW] - times[i] >= LiveSession.CONNECTION_WINDOW_MS,
            )
        }

        val burst = Device()
        burst.record()
        repeat(LiveSession.MAX_CONNECTIONS_PER_WINDOW - 1) {
            burst.transport.listener.onEnd(LiveTranslateClient.NO_RESULT_ERROR, true, NO_RESULT)
            burst.advance(0)
            burst.transport.listener.onReady()
        }
        assertEquals(LiveSession.MAX_CONNECTIONS_PER_WINDOW, burst.transports.size)
        burst.transport.listener.onEnd(LiveTranslateClient.NO_RESULT_ERROR, true, NO_RESULT)
        burst.advance(0)
        assertEquals("the ninth waits", LiveSession.MAX_CONNECTIONS_PER_WINDOW, burst.transports.size)
        assertEquals("连接过于频繁，60 秒后重试", burst.session.snapshot.status)
        burst.advance(LiveSession.CONNECTION_WINDOW_MS)
        assertEquals(LiveSession.MAX_CONNECTIONS_PER_WINDOW + 1, burst.transports.size)
    }

    @Test
    fun speechWhileConnectingIsBoundedAndDroppedOnCancel() {
        // A slow handshake keeps only the most recent second, like a reconnect gap.
        val slow = Device()
        slow.session.start(LiveTranslateConfig(), "mock-only")
        val chunk = 3200
        repeat(LiveSession.CATCH_UP_AUDIO_BYTES / chunk + 5) { slow.speak(chunk, fill = it) }
        slow.transport.listener.onReady()
        val sent = slow.transport.audio
        assertEquals(LiveSession.CATCH_UP_AUDIO_BYTES, sent.sumOf { it.size })
        assertEquals("oldest chunks dropped first", 5.toByte(), sent.first()[0])

        // Without auto-reconnect the first connection still gets the speech captured while it was set up.
        val manual = Device()
        manual.session.start(LiveTranslateConfig(), "mock-only", autoReconnect = false)
        manual.speak(fill = 7)
        manual.transport.listener.onReady()
        assertEquals(listOf<Byte>(7), manual.transport.audio.map { it[0] })

        // Cancelling while connecting closes the microphone and sends nothing.
        val cancelled = Device()
        cancelled.session.start(LiveTranslateConfig(), "mock-only")
        cancelled.speak()
        cancelled.session.stop()
        assertEquals(SessionState.IDLE, cancelled.state)
        assertNull(cancelled.onChunk)
        assertTrue(cancelled.transport.cancelled && cancelled.transport.audio.isEmpty())

        // A failed handshake ends the session and the microphone with it.
        val failed = Device()
        failed.session.start(LiveTranslateConfig(), "mock-only")
        failed.speak()
        failed.transport.listener.onEnd(LOST, true)
        assertEquals(SessionState.IDLE, failed.state)
        assertNull(failed.onChunk)
        assertFalse(failed.active)
    }

    @Test
    fun captureFailuresEndTheSession() {
        // The microphone opens on start, so a refused microphone ends the session before any connection is used.
        val denied = Device()
        denied.captureFails = true
        denied.session.start(LiveTranslateConfig(), "mock-only")
        assertEquals(SessionState.IDLE, denied.state)
        assertTrue(denied.session.snapshot.error.contains("麦克风"))
        assertTrue(denied.transport.cancelled)
        assertFalse(denied.active)
        denied.transport.listener.onReady()
        assertEquals(SessionState.IDLE, denied.state)

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

    @Test
    fun recorderKeepsOnlyFinalizedRows() {
        val device = Device()
        val saved = mutableListOf<SessionRecord>()
        val ended = mutableListOf<Pair<String, SessionRecord?>>()
        val recorder = SessionRecorder({ device.now }, device::schedule, ZoneId.of("Asia/Shanghai"), object : SessionRecorder.Sink {
            override fun save(record: SessionRecord) { saved += record }
            override fun ended(id: String, record: SessionRecord?) { ended += id to record }
        })
        device.observers += recorder::observe
        val id = "00000000-0000-4000-8000-000000000001"
        recorder.begin(null, id, "zh")
        device.record()
        device.advance(500)
        device.utter("a")
        val listener = device.transport.listener
        listener.onEvent(json("type" to "conversation.item.input_audio_transcription.delta", "item_id" to "b", "delta" to "Half a sent"))
        assertTrue("writes are throttled", saved.isEmpty())
        device.advance(SessionRecorder.SAVE_DELAY_MS - 1)
        assertTrue(saved.isEmpty())
        device.advance(1)
        assertEquals(1, saved.size)
        assertEquals(listOf(SessionRow(0, SessionRow.KIND_TEXT, 500, "Hello.", "你好。")), saved.last().rows)
        assertEquals("08:00 is 1970-01-01 in Shanghai", "01-01 08:00 Hello.", saved.last().title)
        assertNull("still recording", saved.last().segments.single().endedAtMs)

        // The source is final before its translation: stored at once, the translation fills the same row later.
        listener.onEvent(json("type" to "conversation.item.created", "previous_item_id" to "c", "item" to json("id" to "c-out", "role" to "assistant")))
        listener.onEvent(json("type" to "conversation.item.input_audio_transcription.completed", "item_id" to "c", "transcript" to "Second."))
        listener.onEvent(json("type" to "response.text.delta", "item_id" to "c-out", "delta" to "第二"))
        device.advance(SessionRecorder.SAVE_DELAY_MS)
        assertEquals(listOf("Hello.", "Second."), saved.last().rows.map { it.source })
        assertEquals("a partial translation is not stored", "", saved.last().rows[1].translation)
        listener.onEvent(json("type" to "response.text.done", "item_id" to "c-out", "text" to "第二句。"))
        device.advance(SessionRecorder.SAVE_DELAY_MS)
        assertEquals(listOf("你好。", "第二句。"), saved.last().rows.map { it.translation })

        // A translation whose source never arrives is final once its connection is gone; the partial row is not.
        listener.onEvent(json("type" to "response.text.done", "item_id" to "x-out", "text" to "孤立译文"))
        device.advance(SessionRecorder.SAVE_DELAY_MS)
        assertEquals(2, saved.last().rows.size)
        listener.onEnd(LOST, true)
        device.advance(LiveSession.RECONNECT_DELAYS_MS[0])
        device.transport.listener.onReady()
        device.utter("d", "Back.", "回来了。")
        device.transport.listener.onEvent(json("type" to "response.text.done", "item_id" to "y-out", "text" to "尾部译文"))
        val writes = saved.size
        device.session.stop()
        device.transport.listener.onEnd(null, false)
        assertEquals(SessionState.IDLE, device.state)
        assertEquals("stop writes at once", writes + 1, saved.size)
        val first = saved.last()
        assertEquals(id, ended.single().first)
        assertEquals(first, ended.single().second)
        assertEquals(
            listOf(
                SessionRow(0, SessionRow.KIND_TEXT, 500, "Hello.", "你好。"),
                SessionRow(0, SessionRow.KIND_TEXT, 1500, "Second.", "第二句。"),
                SessionRow(0, SessionRow.KIND_TEXT, 3500, "", "孤立译文"),
                SessionRow(0, SessionRow.KIND_BREAK, 4500),
                SessionRow(0, SessionRow.KIND_TEXT, 5000, "Back.", "回来了。"),
                SessionRow(0, SessionRow.KIND_TEXT, 5000, "", "尾部译文"),
            ),
            first.rows,
        )
        assertEquals(device.now, first.segments.single().endedAtMs)
        assertEquals(device.now, first.updatedAtMs)
        assertEquals(0L, first.createdAtMs)

        // Continue recording: a new segment; nothing is written for a continuation without speech.
        device.advance(60_000)
        recorder.begin(first, "unused", "ja")
        device.session.clear()
        device.record()
        device.session.stop()
        device.transport.listener.onEnd(null, false)
        assertEquals(first, ended.last().second)
        assertEquals(writes + 1, saved.size)

        recorder.begin(first, "unused", "ja")
        device.session.clear()
        device.record()
        device.utter("e", "Day two.", "二日目。")
        device.session.stop()
        device.transport.listener.onEnd(null, false)
        val continued = saved.last()
        assertEquals(id, continued.id)
        assertEquals(listOf("zh", "ja"), continued.segments.map { it.targetLanguage })
        assertEquals(SessionRow(1, SessionRow.KIND_TEXT, 0, "Day two.", "二日目。"), continued.rows.last())
        assertEquals(first.rows, continued.rows.dropLast(1))
        assertEquals("the automatic title keeps the first text", first.title, continued.title)

        // A new session that never got text is dropped, never written.
        val count = saved.size
        recorder.begin(null, "00000000-0000-4000-8000-000000000002", "zh")
        device.session.clear()
        device.record()
        recorder.rename("Renamed early")
        device.session.stop()
        device.transport.listener.onEnd(null, false)
        assertEquals(count, saved.size)
        assertEquals("00000000-0000-4000-8000-000000000002" to null, ended.last())
        assertNull(recorder.record)
    }
}

private const val BREAK = LiveSession.BREAK_MARKER
