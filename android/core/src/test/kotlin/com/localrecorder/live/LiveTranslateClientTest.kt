package com.localrecorder.live

import org.json.JSONObject
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Runs the client against tests/mock_livetranslate_server.py (synthetic audio and credentials only). */
class LiveTranslateClientTest {
    companion object {
        private lateinit var server: Process
        private lateinit var base: String

        @BeforeClass @JvmStatic
        fun startServer() {
            val script = System.getProperty("livetranslate.mock") ?: error("run through Gradle")
            val portFile = File.createTempFile("live-port", ".txt").apply { deleteOnExit() }
            portFile.writeText("")
            server = ProcessBuilder("python3", script, portFile.absolutePath).inheritIO().start()
            repeat(100) {
                if (portFile.readText().isNotBlank()) {
                    base = "ws://127.0.0.1:" + portFile.readText().trim()
                    return
                }
                Thread.sleep(50)
            }
            error("mock server did not start")
        }

        @AfterClass @JvmStatic
        fun stopServer() {
            server.destroy()
        }
    }

    // Single callback thread, like the app's main thread.
    private val callbacks = Executors.newSingleThreadExecutor()

    private inner class Probe(timeoutMs: Long = 30_000) : LiveTranslateClient.Listener {
        @Volatile var ready = false
        @Volatile var ended = false
        @Volatile var error: String? = null
        @Volatile var recoverable = false
        @Volatile var bytes = 0
        @Volatile var audioBytes = 0
        @Volatile var callbackCount = 0
        val events = LiveTranslateEvents()
        private val decoder = LiveTranslateAudioDecoder()
        val client = LiveTranslateClient(this, callbacks, finishTimeoutMs = timeoutMs, allowLocalhost = true)

        override fun onReady() { ready = true; callbackCount++ }
        override fun onEvent(event: JSONObject) {
            callbackCount++
            events.apply(event)
            runCatching { decoder.consume(event) }.getOrNull()?.let { audioBytes += it.size }
            if (event.optString("type") == "fixture.audio_bytes") bytes = event.getInt("count")
        }
        override fun onEnd(error: String?, recoverable: Boolean) {
            this.error = error
            this.recoverable = recoverable
            callbackCount++
            ended = true
        }

        fun connect(route: String, audio: Boolean = false) =
            client.connect(LiveTranslateConfig(endpoint = base + route, audioOutput = audio), "mock-only")

        fun waitFor(condition: () -> Boolean) {
            repeat(600) {
                if (condition()) return
                Thread.sleep(10)
            }
            error("timed out waiting for websocket fixture")
        }
    }

    @Test
    fun textSessionDrainsTailAndJoinsById() {
        repeat(2) {
            val probe = Probe()
            assertEquals("audio blocked before ready", AppendResult.CLOSED, probe.client.append(ByteArray(2)))
            probe.connect("/ok")
            probe.waitFor { probe.ready || probe.ended }
            assertTrue("configuration acknowledged", probe.ready)
            repeat(30) { assertEquals("audio accepted", AppendResult.SENT, probe.client.append(ByteArray(640))) }
            probe.client.finish()
            probe.waitFor { probe.ended }
            assertNull(probe.error)
            assertEquals("finish follows all queued audio", 30 * 640, probe.bytes)
            val row = probe.events.rows["source"]!!
            assertEquals("Hello world.", row.source.text)
            assertTrue(row.source.done)
            val translated = probe.events.translation(row)
            assertEquals("你好，世界🌏。", translated.text)
            assertTrue(translated.done)
            assertEquals(1.2, row.seconds, 0.0)
        }
    }

    @Test
    fun audioSessionReceivesSpeechOnce() {
        val spoken = Probe()
        spoken.connect("/ok", audio = true)
        spoken.waitFor { spoken.ready || spoken.ended }
        assertTrue("audio format acknowledged", spoken.ready)
        spoken.client.append(ByteArray(640))
        spoken.client.finish()
        spoken.waitFor { spoken.ended }
        assertNull(spoken.error)
        assertEquals("audio output received once despite duplicates", 4800, spoken.audioBytes)
        assertEquals("你好，世界🌏。", spoken.events.translation(spoken.events.rows["source"]!!).text)

        val badFormat = Probe()
        badFormat.connect("/wrong-audio-format", audio = true)
        badFormat.waitFor { badFormat.ended }
        assertTrue("unexpected audio sample rate rejected before capture", badFormat.error != null && !badFormat.ready)
    }

    @Test
    fun connectionTestSendsNoAudio() {
        val empty = Probe()
        empty.connect("/ok")
        empty.waitFor { empty.ready }
        empty.client.finish()
        empty.waitFor { empty.ended }
        assertNull(empty.error)
        assertEquals(0, empty.bytes)
        assertTrue(empty.events.rows.isEmpty())
    }

    @Test
    fun failuresAreSurfacedWithoutLeakingCredentials() {
        // Only a lost connection or a session the server closed by itself is worth a new session.
        val routes = mapOf(
            "/unauthorized" to false, "/redirect" to false, "/error" to false, "/wrong-mode" to false,
            "/disconnect" to true, "/finished-early" to true, "/timeout" to false,
        )
        for ((route, recoverable) in routes) {
            val probe = Probe(timeoutMs = 100)
            probe.connect(route)
            probe.waitFor { probe.ready || probe.ended }
            if (probe.ready) {
                if (route == "/disconnect" || route == "/finished-early") probe.client.append(ByteArray(2)) else probe.client.finish()
            }
            probe.waitFor { probe.ended }
            assertNotNull("failure surfaced: $route", probe.error)
            assertFalse("provider payload never leaks credentials", probe.error!!.contains("mock-only"))
            assertEquals("recoverable: $route", recoverable, probe.recoverable)
        }
        val unauthorized = Probe()
        unauthorized.connect("/unauthorized")
        unauthorized.waitFor { unauthorized.ended }
        assertTrue(unauthorized.error!!.contains("API Key 无效"))
    }

    /** The session engine on real threads: one session thread, the test thread as the capture thread. */
    private inner class Device : SessionPlatform {
        private val thread = Executors.newSingleThreadScheduledExecutor()
        @Volatile var snapshot = SessionSnapshot()
        @Volatile var onChunk: ((ByteArray) -> Unit)? = null
        val session = LiveSession(this) { snapshot = it }

        override fun post(block: () -> Unit) = thread.execute(block)
        override fun schedule(delayMs: Long, block: () -> Unit): Cancellable {
            val future = thread.schedule(block, delayMs, TimeUnit.MILLISECONDS)
            return Cancellable { future.cancel(false) }
        }
        override fun transport(listener: LiveTranslateClient.Listener): LiveTransport =
            LiveTranslateClient(listener, thread, allowLocalhost = true)
        override fun startCapture(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit) { this.onChunk = onChunk }
        override fun stopCapture() { onChunk = null }
        override fun speech(): SpeechOutput = error("text only")
        override fun sessionActive(active: Boolean) = Unit

        fun waitFor(what: String, condition: (SessionSnapshot) -> Boolean) {
            repeat(1000) {
                if (condition(snapshot)) return
                Thread.sleep(10)
            }
            error("timed out waiting for $what: $snapshot")
        }
    }

    @Test
    fun sessionSurvivesADroppedConnection() {
        val device = Device()
        val config = LiveTranslateConfig(endpoint = "$base/drop-once/${System.nanoTime()}")
        device.post { device.session.start(config, "mock-only") }
        device.waitFor("first connection") { it.state == SessionState.RECORDING }
        // The fixture answers the first audio with a partial transcript and cuts the connection.
        device.onChunk!!(ByteArray(640))
        device.waitFor("reconnect") { snapshot -> snapshot.state == SessionState.RECORDING && snapshot.rows.any { it.marker.isNotEmpty() } }
        device.onChunk!!(ByteArray(640))
        device.waitFor("text on the new connection") { snapshot -> snapshot.rows.any { it.source == "Hello" } }
        device.post { device.session.stop() }
        device.waitFor("tail") { it.state == SessionState.IDLE }
        assertEquals("", device.snapshot.error)
        val rows = device.snapshot.rows
        assertEquals(listOf("Before the break", "", "Hello world."), rows.map { it.source })
        assertEquals(LiveSession.BREAK_MARKER, rows[1].marker)
        assertEquals("你好，世界🌏。", rows[2].translation)
        assertTrue(rows[2].sourceDone && rows[2].translationDone && !rows[0].sourceDone)
    }

    @Test
    fun boundedQueueAndSilentCancel() {
        val cancel = Probe()
        cancel.connect("/ok")
        cancel.waitFor { cancel.ready }
        assertEquals("bounded audio queue", AppendResult.FULL, cancel.client.append(ByteArray(320_001)))
        assertEquals(AppendResult.SENT, cancel.client.append(ByteArray(640)))
        cancel.client.cancel()
        Thread.sleep(100)
        val count = cancel.callbackCount
        Thread.sleep(200)
        assertEquals("cancel suppresses subsequent transport callbacks", count, cancel.callbackCount)
        assertFalse(cancel.ended)
        assertEquals("closed client rejects audio", AppendResult.CLOSED, cancel.client.append(ByteArray(2)))
    }
}
