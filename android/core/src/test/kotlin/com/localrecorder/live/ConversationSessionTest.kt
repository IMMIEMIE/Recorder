package com.localrecorder.live

import org.junit.Assert.*
import org.junit.Test

class ConversationSessionTest {
    private class Connection(val listener: LiveTransport.Listener) : LiveTransport {
        lateinit var config: LiveTranslateConfig
        val chunks = mutableListOf<ByteArray>()
        var finishing = false
        override fun connect(configuration: LiveTranslateConfig, key: String) { config = configuration }
        override fun append(pcm: ByteArray): AppendResult { chunks += pcm; return AppendResult.SENT }
        override val queuedAudioBytes = 0
        override fun finish() { finishing = true }
        override fun cancel() {}
        fun words(id: String, start: Int, source: String, translation: String) {
            listener.onEvent(LiveSessionEvent.SpeechStart(id, start, null))
            listener.onEvent(LiveSessionEvent.Link(id, "$id-out", null))
            listener.onEvent(LiveSessionEvent.Text(id, source, true, true, null))
            listener.onEvent(LiveSessionEvent.Text("$id-out", translation, false, true, null))
            listener.onEvent(LiveSessionEvent.SpeechEnd(start + 200, null))
        }
        fun sound(id: String, value: Byte) {
            listener.onEvent(LiveSessionEvent.Audio("$id-out", byteArrayOf(value, value), false, null))
            listener.onEvent(LiveSessionEvent.Audio("$id-out", null, true, null))
        }
    }

    private class Device(val loudspeaker: Boolean = true) : SessionPlatform {
        private data class Timer(val at: Long, val task: () -> Unit)
        private val timers = mutableListOf<Timer>()
        private var now = 0L
        val sockets = mutableListOf<Connection>()
        val played = mutableListOf<Byte>()
        val service = mutableListOf<Boolean>()
        var onDrained: (() -> Unit)? = null
        var capture: ((ByteArray) -> Unit)? = null
        var starts = 0
        var stops = 0
        val engine = ConversationSession(this, { text, a, b, done -> done(DialogueTurns.scriptLanguage(text, a, b)) }, { loudspeaker }) {}
        override fun elapsedMs() = now
        override fun post(block: () -> Unit) = block()
        override fun schedule(delayMs: Long, block: () -> Unit): Cancellable {
            val timer = Timer(now + delayMs, block)
            timers += timer
            return Cancellable { timers.remove(timer) }
        }
        fun advance(ms: Long) {
            val end = now + ms
            while (true) {
                val timer = timers.filter { it.at <= end }.minByOrNull { it.at } ?: break
                timers.remove(timer)
                now = timer.at
                timer.task()
            }
            now = end
        }
        override fun transport(configuration: LiveTranslateConfig, listener: LiveTransport.Listener): LiveTransport =
            Connection(listener).also(sockets::add)
        override fun startCapture(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit) { starts++; capture = onChunk }
        override fun stopCapture() { stops++; capture = null }
        override fun speech() = object : SpeechOutput {
            override fun start(volume: Float) {}
            override fun append(pcm: ByteArray): Boolean { played += pcm.first(); return true }
            override fun finish(done: () -> Unit) { onDrained = done }
            override fun stop() {}
        }
        override fun sessionActive(active: Boolean) { service += active }
        fun begin(voice: Boolean = false, dialogue: Boolean = true) {
            engine.configure(dialogue, "zh", "en", "en")
            engine.start(LiveTranslateConfig(language = "en", audioOutput = voice), "mock-only")
            sockets.forEach { it.listener.onReady() }
            speak()
        }
        fun speak() { capture!!(ByteArray(3200) { 7 }) }
    }

    @Test fun routesBothDirectionsMergesReversedLaneOrderAndKeepsUnknown() {
        val d = Device()
        d.begin()
        val (a, b) = d.sockets
        assertEquals(listOf("zh", "en"), d.sockets.map { it.config.language })
        assertEquals(1, d.starts)
        assertEquals(1, a.chunks.size)
        assertEquals(1, b.chunks.size)
        b.words("b1", 10, "你好", "Hello!")
        val key = d.engine.snapshot.rows.single().key
        a.words("a1", 0, "你好", "你好")
        a.words("a2", 400, "Good evening", "晚上好")
        b.words("b2", 415, "Good evening", "Good evening")
        b.words("b3", 1200, "42", "forty-two")
        a.words("a3", 1202, "42", "四十二")
        val rows = d.engine.snapshot.rows
        assertEquals(key, rows.first().key)
        assertEquals(listOf("A", "B", "unknown"), rows.map { it.speaker })
        assertEquals(listOf("zh", "en", null), rows.map { it.sourceLanguage })
        assertEquals(listOf("en", "zh", null), rows.map { it.targetLanguage })
        assertEquals(listOf("Hello!", "晚上好", ""), rows.map { it.translation })
        d.engine.stop()
        assertTrue(d.sockets.all { it.finishing })
        assertEquals(SessionState.FINISHING, d.engine.snapshot.state)
        b.listener.onEnd(null, false)
        assertEquals(SessionState.FINISHING, d.engine.snapshot.state)
        a.listener.onEnd(null, false)
        assertEquals(SessionState.IDLE, d.engine.snapshot.state)
        assertEquals(listOf(true, false), d.service)
        assertEquals(1, d.stops)
        assertEquals(rows, d.engine.snapshot.rows)
    }

    @Test fun quarantinesAudioUntilBothLanesAgreeAndMutesOnlyTheLoudspeakerInterval() {
        for (gate in listOf(true, false)) {
            val d = Device(loudspeaker = gate)
            d.begin(voice = true)
            val (a, b) = d.sockets
            // Out-of-order audio, prior to linking or source-language identification.
            b.sound("b1", 2)
            a.sound("a1", 1)
            b.words("b1", 10, "你好", "Hello")
            assertTrue(d.played.isEmpty())
            a.words("a1", 0, "你好", "你好")
            assertEquals(listOf<Byte>(2), d.played)
            d.speak()
            assertEquals(if (gate) 0 else 7, a.chunks.last().first().toInt())
            d.onDrained!!.invoke()
            d.speak()
            assertEquals(7, a.chunks.last().first().toInt())
            b.sound("b2", 3)
            a.sound("a2", 4)
            b.words("b2", 800, "好", "Good")
            a.words("a2", 805, "Good", "好")
            assertEquals(listOf<Byte>(2), d.played)
            val conflicted = d.engine.snapshot.rows.last()
            assertEquals("unknown", conflicted.speaker)
            assertEquals("", conflicted.translation)
        }
    }

    @Test fun oneLaneRecoveringLeavesOtherUsableAndModeSwitchKeepsMicAndOldTail() {
        val d = Device()
        d.begin()
        val (a, b) = d.sockets
        b.listener.onEnd("限流", true, EndCause(EndCause.Kind.RATE_LIMITED, "1007"))
        assertEquals(SessionState.RECORDING, d.engine.snapshot.state)
        a.words("alone", 100, "Good", "好")
        assertEquals("好", d.engine.snapshot.rows.first { it.speaker == "B" }.translation)
        d.engine.configure(false, "zh", "en", "ja")
        d.engine.configure(false, "zh", "en", "fr")
        d.advance(999)
        assertEquals(2, d.sockets.size)
        // The shared rate limit delays the new lane. The old lane drains instead of dropping its final text.
        d.advance(1)
        a.words("tail", 900, "Bye", "再见")
        a.listener.onEnd(null, false)
        d.advance(20_000)
        assertEquals(3, d.sockets.size)
        val normal = d.sockets.last()
        normal.listener.onReady()
        normal.words("n", 100, "Bonjour", "Salut")
        assertEquals("fr", normal.config.language)
        assertEquals(1, d.starts)
        assertEquals(0, d.stops)
        assertEquals(listOf(true), d.service)
        assertTrue(d.engine.snapshot.rows.any { it.translation == "再见" && it.targetLanguage == "zh" })
        assertTrue(d.engine.snapshot.rows.any { it.translation == "Salut" && it.targetLanguage == "fr" })
    }
}
