package com.localrecorder.live

import com.localrecorder.sessions.SessionRecord
import com.localrecorder.sessions.SessionRecorder
import org.junit.AfterClass
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import java.io.File
import java.time.ZoneId
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** End-to-end and unit tests for Seed-LiveInterpret 2.0 (volc-ast) against tests/mock_volc_ast_server.py. */
class SeedLiveInterpretTests {
    companion object {
        private lateinit var volcServer: Process
        private lateinit var volcBase: String
        private lateinit var qwenServer: Process
        private lateinit var qwenBase: String

        @BeforeClass @JvmStatic
        fun startServers() {
            volcServer = launchMock("volc.ast.mock") { volcBase = it }
            qwenServer = launchMock("livetranslate.mock") { qwenBase = it }
        }

        private fun launchMock(property: String, assign: (String) -> Unit): Process {
            val script = System.getProperty(property) ?: error("missing system property $property; run through Gradle")
            val portFile = File.createTempFile("mock-port", ".txt").apply { deleteOnExit() }
            portFile.writeText("")
            val proc = ProcessBuilder("python3", script, portFile.absolutePath).inheritIO().start()
            repeat(100) {
                if (portFile.readText().isNotBlank()) {
                    assign("ws://127.0.0.1:" + portFile.readText().trim())
                    return proc
                }
                Thread.sleep(50)
            }
            error("mock server $property did not start")
        }

        @AfterClass @JvmStatic
        fun stopServers() {
            if (::volcServer.isInitialized) volcServer.destroy()
            if (::qwenServer.isInitialized) qwenServer.destroy()
        }
    }

    private val callbacks = Executors.newSingleThreadExecutor()

    private inner class Probe(timeoutMs: Long = 30_000) : LiveTransport.Listener {
        @Volatile var ready = false
        @Volatile var ended = false
        @Volatile var error: String? = null
        @Volatile var recoverable = false
        @Volatile var cause = EndCause()
        @Volatile var audioBytes = 0
        @Volatile var audioError: LiveMessage? = null
        @Volatile var callbackCount = 0
        @Volatile var lastFinishedMessage = ""
        val events = LiveTranslateEvents()
        private val decoder = LiveTranslateAudioDecoder()
        val client = SeedLiveInterpretClient(
            listener = this,
            callbackExecutor = callbacks,
            finishTimeoutMs = timeoutMs,
            allowLocalhost = true,
            wireObserver = { resp ->
                if (resp.event == VolcAstEventType.SESSION_FINISHED) {
                    lastFinishedMessage = resp.responseMeta?.message.orEmpty()
                }
            },
        )

        override fun onReady() { ready = true; callbackCount++ }
        override fun onEvent(event: LiveSessionEvent) {
            callbackCount++
            events.apply(event)
            try {
                decoder.consume(event)?.let { audioBytes += it.size }
            } catch (e: LiveTranslateException) {
                audioError = e.liveMessage
            }
        }
        override fun onEnd(error: String?, recoverable: Boolean, cause: EndCause) {
            this.error = error
            this.recoverable = recoverable
            this.cause = cause
            callbackCount++
            ended = true
        }

        fun connect(
            route: String,
            key: String = "mock-volc-key",
            appKey: String = "",
            audio: Boolean = false,
            sourceLanguage: String = "",
            targetLanguage: String = "zh",
        ) {
            val profile = LiveServiceProfile.seedLiveInterpret(
                endpoint = volcBase + route,
                sourceLanguage = sourceLanguage,
                appKey = appKey,
            )
            client.connect(
                LiveTranslateConfig(catalog = LiveServiceCatalog(profile), language = targetLanguage, audioOutput = audio),
                key,
            )
        }

        fun waitFor(condition: () -> Boolean) {
            repeat(600) {
                if (condition()) return
                Thread.sleep(10)
            }
            error("timed out waiting for volc-ast fixture")
        }
    }

    @Test
    fun protobufCodecAndSubtitleMerger() {
        val meta = VolcAstProtoWriter().apply {
            writeString(1, "sid-99")
            writeInt32(2, 7)
            writeInt32(3, VolcAstTranslateResponse.STATUS_SUCCESS)
            writeString(4, "ok")
            // Unknown billing submessage (field 5) must be skipped safely.
            writeBytes(5, byteArrayOf(0x0A, 0x02, 0x31, 0x32))
        }.toByteArray()
        val raw = VolcAstProtoWriter().apply {
            writeMessage(1, meta)
            writeInt32(2, VolcAstEventType.TRANSLATION_SUBTITLE_END)
            writeBytes(3, byteArrayOf(0x00, 0x40))
            writeString(4, "你好，世界🌏。")
            writeInt32(5, 1200)
            writeInt32(6, 2400)
            writeBool(7, true)
            writeInt32(8, 250)
            // Unknown varint (field 98) must be skipped safely.
            writeInt32(98, 12345)
        }.toByteArray()

        val decoded = VolcAstTranslateResponse.decode(raw)
        assertEquals("sid-99", decoded.responseMeta?.sessionID)
        assertEquals(7, decoded.responseMeta?.sequence)
        assertFalse(decoded.hasErrorStatus)
        assertEquals(VolcAstEventType.TRANSLATION_SUBTITLE_END, decoded.event)
        assertArrayEquals(byteArrayOf(0x00, 0x40), decoded.data)
        assertEquals("你好，世界🌏。", decoded.text)
        assertEquals(1200, decoded.startTime)
        assertEquals(2400, decoded.endTime)
        assertTrue(decoded.spkChg)
        assertEquals(250, decoded.mutedDurationMs)

        assertEquals("yes yes", VolcAstSubtitleMerger.append("yes ", "yes"))
        assertEquals("yesyes", VolcAstSubtitleMerger.append("yes", "yes"))
        assertEquals("to today", VolcAstSubtitleMerger.append("to ", "today"))
        assertEquals("today", VolcAstSubtitleMerger.append("to", "day"))
        assertEquals("a and", VolcAstSubtitleMerger.append("a ", "and"))
        assertEquals("你好，世界", VolcAstSubtitleMerger.append("你好", "，世界"))
    }

    @Test
    fun profileSwitchingValidationAndBackwardCompatibleJson() {
        val qwen = LiveServiceProfile()
        val volc = qwen.switchingProtocol(LiveServiceProfile.VOLC_AST_PROTOCOL_ID)
        assertTrue(volc.isVolcAst)
        assertEquals(LiveServiceProfile.VOLC_AST_VERSION, volc.version)
        assertEquals(LiveServiceProfile.VOLC_AST_DEFAULT_ENDPOINT, volc.endpoint)
        assertEquals(LiveServiceProfile.VOLC_AST_DEFAULT_RESOURCE_ID, volc.modelID)
        assertEquals("en", volc.resolvedSourceLanguage("zh"))
        assertEquals("zh", volc.resolvedSourceLanguage("en"))

        val customized = volc.copy(sourceLanguage = "zhen", appKey = "app-999")
        val config = LiveTranslateConfig(catalog = LiveServiceCatalog(customized), language = "zh")
        assertEquals(LiveServiceProfile.VOLC_AST_DEFAULT_ENDPOINT, config.url())
        val restored = LiveTranslateConfig.fromJson(config.toJson())
        assertEquals(config, restored)
        assertFalse("secret keys never appear in config JSON", config.toJson().contains("mock-volc"))

        // Legacy JSON without sourceLanguage / appKey still parses cleanly.
        val legacy = LiveTranslateConfig.fromJson("""{"enabled":true,"endpoint":"wss://example.com/realtime","language":"en"}""")
        assertFalse(legacy.profile.isVolcAst)
        assertEquals("", legacy.profile.sourceLanguage)
        assertEquals("", legacy.profile.appKey)

        // Invalid fields rejected.
        assertEquals(
            LiveMessage.InvalidSourceLanguage,
            (runCatching { volc.copy(sourceLanguage = "xx").validate() }.exceptionOrNull() as LiveTranslateException).liveMessage,
        )
        assertEquals(
            LiveMessage.InvalidAppKeyFormat,
            (runCatching { volc.copy(appKey = "bad key\n").validate() }.exceptionOrNull() as LiveTranslateException).liveMessage,
        )
    }

    @Test
    fun silentConnectionTestSingleAndDualAuth() {
        val single = Probe()
        single.connect("/ok")
        single.waitFor { single.ready || single.ended }
        assertTrue(single.ready)
        single.client.finish()
        single.waitFor { single.ended }
        assertNull(single.error)
        assertEquals("audio_bytes=0", single.lastFinishedMessage)
        assertTrue(single.events.rows.isEmpty())

        val dual = Probe()
        dual.connect("/dual-auth", key = "mock-volc-access", appKey = "app-12345")
        dual.waitFor { dual.ready || dual.ended }
        assertTrue(dual.ready)
        dual.client.finish()
        dual.waitFor { dual.ended }
        assertNull(dual.error)
        assertEquals("audio_bytes=0", dual.lastFinishedMessage)
    }

    @Test
    fun s2tAndS2sStreamingAndOggGuard() {
        // S2T with explicit zhen source language
        val s2t = Probe()
        s2t.connect("/source-check/zhen", audio = false, sourceLanguage = "zhen")
        s2t.waitFor { s2t.ready || s2t.ended }
        assertTrue(s2t.ready)
        assertEquals(AppendResult.SENT, s2t.client.append(ByteArray(640) { 1 }))
        s2t.waitFor { s2t.events.rows.values.any { it.source.text == "Hello world" } }
        s2t.client.finish()
        s2t.waitFor { s2t.ended }
        assertNull(s2t.error)
        val row = s2t.events.rows.values.single()
        assertEquals("Hello world.", row.source.text)
        assertTrue(row.source.done)
        assertEquals("你好，世界🌏。", s2t.events.translation(row).text)
        assertTrue(s2t.events.translation(row).done)
        assertEquals(1.2, row.seconds, 0.0)
        assertEquals(0, s2t.audioBytes)

        // S2S with 24 kHz PCM16 split on odd byte boundary
        val s2s = Probe()
        s2s.connect("/ok", audio = true)
        s2s.waitFor { s2s.ready || s2s.ended }
        assertTrue(s2s.ready)
        assertEquals(AppendResult.SENT, s2s.client.append(ByteArray(640) { 1 }))
        s2s.client.finish()
        s2s.waitFor { s2s.ended }
        assertNull(s2s.error)
        assertNull(s2s.audioError)
        assertEquals(4800, s2s.audioBytes)

        // Repeated words, short prefixes, and authoritative End replacement over wire
        val repeatProbe = Probe()
        repeatProbe.connect("/repeat-words")
        repeatProbe.waitFor { repeatProbe.ready || repeatProbe.ended }
        assertTrue(repeatProbe.ready)
        assertEquals(AppendResult.SENT, repeatProbe.client.append(ByteArray(640) { 1 }))
        repeatProbe.waitFor { repeatProbe.events.rows.values.any { it.source.text == "yes yes to today" } }
        repeatProbe.client.finish()
        repeatProbe.waitFor { repeatProbe.ended }
        assertNull(repeatProbe.error)
        val repeatRow = repeatProbe.events.rows.values.single()
        assertEquals("yes yes to today", repeatRow.source.text)
        assertTrue(repeatRow.source.done)
        assertEquals("你好，世界！", repeatProbe.events.translation(repeatRow).text)
        assertTrue(repeatProbe.events.translation(repeatRow).done)

        // OggS defensive rejection stops audio without breaking subtitles
        val ogg = Probe()
        ogg.connect("/ogg-audio", audio = true)
        ogg.waitFor { ogg.ready || ogg.ended }
        assertEquals(AppendResult.SENT, ogg.client.append(ByteArray(640) { 1 }))
        ogg.client.finish()
        ogg.waitFor { ogg.ended }
        assertNull(ogg.error)
        assertEquals(LiveMessage.AudioInvalidFormat, ogg.audioError)
        assertEquals("你好，世界🌏。", ogg.events.translation(ogg.events.rows.values.single()).text)
    }

    @Test
    fun failuresNeverLeakCredentialsAndClassifyRecoverability() {
        val routes = mapOf(
            "/unauthorized" to false,
            "/redirect" to false,
            "/http-429" to true,
            "/session-failed-auth" to false,
            "/session-failed-quota" to false,
            "/rate-limited" to true,
            "/wrong-order" to false,
            "/invalid-proto" to false,
            "/disconnect" to true,
            "/finished-early" to true,
            "/timeout" to false,
        )
        for ((route, recoverable) in routes) {
            val probe = Probe(timeoutMs = 150)
            probe.connect(route)
            probe.waitFor { probe.ready || probe.ended }
            if (probe.ready) {
                if (route == "/disconnect" || route == "/finished-early") probe.client.append(ByteArray(2))
                else probe.client.finish()
            }
            probe.waitFor { probe.ended }
            assertNotNull("failure surfaced: $route", probe.error)
            assertFalse("error must never leak key: $route", probe.error!!.contains("mock-volc-key"))
            assertEquals("recoverable: $route", recoverable, probe.recoverable)
            if (route == "/rate-limited" || route == "/http-429") {
                assertEquals(EndCause.Kind.RATE_LIMITED, probe.cause.kind)
            }
        }
    }

    private inner class Device : SessionPlatform {
        private val thread = Executors.newSingleThreadScheduledExecutor()
        @Volatile var snapshot = SessionSnapshot()
        @Volatile var spokenBytes = 0
        @Volatile var onChunk: ((ByteArray) -> Unit)? = null
        val savedRecords = mutableListOf<SessionRecord>()
        val recorder = SessionRecorder(
            clock = { System.currentTimeMillis() },
            schedule = ::schedule,
            zone = ZoneId.of("UTC"),
            sink = object : SessionRecorder.Sink {
                override fun save(record: SessionRecord) { synchronized(savedRecords) { savedRecords += record } }
                override fun ended(id: String, record: SessionRecord?) {
                    if (record != null) synchronized(savedRecords) { savedRecords += record }
                }
            },
        )
        val session = LiveSession(this) {
            snapshot = it
            recorder.observe(it)
        }

        override fun post(block: () -> Unit) = thread.execute(block)
        override fun schedule(delayMs: Long, block: () -> Unit): Cancellable {
            val future = thread.schedule(block, delayMs, TimeUnit.MILLISECONDS)
            return Cancellable { future.cancel(false) }
        }
        override fun transport(configuration: LiveTranslateConfig, listener: LiveTransport.Listener): LiveTransport =
            configuration.profile.transport(listener, thread, allowLocalhost = true)
        override fun startCapture(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit) { this.onChunk = onChunk }
        override fun stopCapture() { onChunk = null }
        override fun speech() = object : SpeechOutput {
            override fun start(volume: Float) = Unit
            override fun append(pcm: ByteArray): Boolean { spokenBytes += pcm.size; return true }
            override fun finish(done: () -> Unit) = done()
            override fun stop() = Unit
        }
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
    fun reconnectPreservesFinalizedSentencesWithoutDuplication() {
        val device = Device()
        val profile = LiveServiceProfile.seedLiveInterpret(endpoint = "$volcBase/drop-after-final/case-${System.nanoTime()}")
        val config = LiveTranslateConfig(catalog = LiveServiceCatalog(profile), audioOutput = true, playbackTiming = PlaybackTiming.AFTER_FINAL)
        device.post {
            device.recorder.begin(null, "sess-volc-1", "zh")
            device.session.start(config, "mock-volc-key")
        }
        device.waitFor("recording") { it.state == SessionState.RECORDING }
        device.onChunk!!(ByteArray(640) { 1 })
        // Connection 1 delivers finalized Turn 1 ("First turn." / "第一句。") and drops; session auto-reconnects.
        device.waitFor("reconnected") { snap -> snap.state == SessionState.RECORDING && snap.rows.any { it.marker.isNotEmpty() } }
        device.onChunk!!(ByteArray(640) { 1 })
        device.waitFor("second turn partial") { snap -> snap.rows.any { it.source.contains("Hello") } }
        device.post { device.session.stop() }
        device.waitFor("idle") { it.state == SessionState.IDLE }
        device.post { device.recorder.finish() }
        Thread.sleep(50)

        val textRows = device.snapshot.rows.filter { it.marker.isEmpty() }
        assertEquals(listOf("First turn.", "Hello world."), textRows.map { it.source })
        assertEquals(listOf("第一句。", "你好，世界🌏。"), textRows.map { it.translation })
        assertEquals(4800, device.spokenBytes)
        val persisted = synchronized(device.savedRecords) { device.savedRecords.last() }
        val persistedTexts = persisted.rows.filter { it.kind == com.localrecorder.sessions.SessionRow.KIND_TEXT }
        assertEquals("finalized sentence must not be duplicated after reconnect", listOf("First turn.", "Hello world."), persistedTexts.map { it.source })
    }

    @Test
    fun liveSwitchBetweenQwenAndSeedLiveInterpret() {
        val device = Device()
        val qwen = LiveServiceProfile(id = "qwen-1", name = "Qwen", endpoint = "$qwenBase/ok")
        val volc = LiveServiceProfile.seedLiveInterpret(id = "volc-1", name = "Seed 2.0", endpoint = "$volcBase/ok")
        val catalog = LiveServiceCatalog(qwen).using(volc).using(qwen)
        val qwenConfig = LiveTranslateConfig(catalog = catalog, language = "zh")
        val volcConfig = qwenConfig.copy(catalog = catalog.using(volc))

        device.post { device.session.start(qwenConfig, "mock-only") }
        device.waitFor("qwen recording") { it.state == SessionState.RECORDING }
        device.onChunk!!(ByteArray(640) { 1 })
        device.waitFor("qwen partial") { snap -> snap.rows.any { it.source == "Hello" } }

        // Live switch to Seed-LiveInterpret 2.0
        device.post { assertTrue(device.session.switchProfile(volcConfig, "mock-volc-key")) }
        device.waitFor("volc recording") { snap -> snap.state == SessionState.RECORDING && snap.rows.any { it.marker.contains("Seed 2.0") } }
        device.onChunk!!(ByteArray(640) { 1 })
        device.waitFor("volc text") { snap -> snap.rows.count { it.source.contains("Hello") } >= 2 }
        device.post { device.session.stop() }
        device.waitFor("idle") { it.state == SessionState.IDLE }
        assertEquals("", device.snapshot.error)
        assertTrue(device.snapshot.rows.any { it.source == "Hello world." && it.translation == "你好，世界🌏。" && it.sourceDone && it.translationDone })
    }
}
