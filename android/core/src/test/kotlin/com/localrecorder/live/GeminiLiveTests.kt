package com.localrecorder.live

import org.json.JSONObject
import org.junit.AfterClass
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.BeforeClass
import org.junit.Test
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class GeminiLiveTests {
    companion object {
        private lateinit var server: Process
        private lateinit var base: String

        @BeforeClass @JvmStatic
        fun startServer() {
            val script = System.getProperty("gemini.live.mock") ?: error("run through Gradle")
            val portFile = File.createTempFile("gemini-live-port", ".txt").apply { deleteOnExit() }
            portFile.writeText("")
            server = ProcessBuilder("python3", script, portFile.absolutePath).inheritIO().start()
            repeat(100) {
                if (portFile.readText().isNotBlank()) {
                    base = "ws://127.0.0.1:" + portFile.readText().trim()
                    return
                }
                Thread.sleep(50)
            }
            error("gemini mock server did not start")
        }

        @AfterClass @JvmStatic
        fun stopServer() {
            server.destroy()
        }
    }

    private val callbacks = Executors.newSingleThreadExecutor()

    private fun geminiProfile(
        id: String = "gemini-default",
        name: String = "Gemini Live",
        endpoint: String = "$base/ok",
        modelID: String = LiveServiceProfile.GEMINI_DEFAULT_MODEL,
    ) = LiveServiceProfile(
        id = id,
        name = name,
        endpoint = endpoint,
        modelID = modelID,
        protocolID = LiveServiceProfile.GEMINI_PROTOCOL_ID,
        version = LiveServiceProfile.GEMINI_VERSION,
    )

    private inline fun assertRejected(message: String, block: () -> Unit) {
        try {
            block()
        } catch (_: Exception) {
            return
        }
        fail(message)
    }

    private inner class Probe(timeoutMs: Long = 15_000, timing: PlaybackTiming = PlaybackTiming.STREAMING) : LiveTransport.Listener {
        @Volatile var ready = false
        @Volatile var ended = false
        @Volatile var error: String? = null
        @Volatile var recoverable = false
        @Volatile var cause = EndCause()
        @Volatile var audioBytes = 0
        @Volatile var audioError: LiveMessage? = null
        @Volatile var callbackCount = 0
        val events = LiveTranslateEvents()
        private val playback = LiveTranslatePlaybackQueue(timing)
        val client = GeminiLiveClient(this, callbacks, finishTimeoutMs = timeoutMs, allowLocalhost = true)

        override fun onReady() { ready = true; callbackCount++ }
        override fun onEvent(event: LiveSessionEvent) {
            callbackCount++
            events.apply(event)
            try {
                for (pcm in playback.consume(event, events)) {
                    audioBytes += pcm.size
                }
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
            audio: Boolean = false,
            modelID: String = LiveServiceProfile.GEMINI_DEFAULT_MODEL,
            key: String = "mock-gemini",
            language: String = "zh",
        ) {
            val config = LiveTranslateConfig(
                catalog = LiveServiceCatalog(geminiProfile(endpoint = base + route, modelID = modelID)),
                language = language,
                audioOutput = audio,
            )
            client.connect(config, key)
        }

        fun waitFor(condition: () -> Boolean) {
            repeat(600) {
                if (condition()) return
                Thread.sleep(10)
            }
            error("timed out waiting for gemini websocket fixture")
        }
    }

    @Test
    fun profileSwitchingValidationAndUrlNormalization() {
        val qwen = LiveServiceProfile()
        val switched = qwen.switchingProtocol(LiveServiceProfile.GEMINI_PROTOCOL_ID)
        assertEquals(LiveServiceProfile.GEMINI_PROTOCOL_ID, switched.protocolID)
        assertEquals(LiveServiceProfile.GEMINI_VERSION, switched.version)
        assertEquals(LiveServiceProfile.GEMINI_DEFAULT_ENDPOINT, switched.endpoint)
        assertEquals(LiveServiceProfile.GEMINI_DEFAULT_MODEL, switched.modelID)

        val backToQwen = switched.switchingProtocol(LiveServiceProfile.QWEN_PROTOCOL_ID)
        assertEquals(LiveServiceProfile.QWEN_PROTOCOL_ID, backToQwen.protocolID)
        assertEquals(LiveServiceProfile.QWEN_VERSION, backToQwen.version)
        assertEquals(LiveTranslateConfig.DEFAULT_ENDPOINT, backToQwen.endpoint)
        assertEquals(LiveTranslateConfig.MODEL, backToQwen.modelID)

        // Custom endpoints and models are preserved across protocol switches.
        val custom = qwen.copy(endpoint = "wss://proxy.example.com/live", modelID = "custom-model")
        val customSwitched = custom.switchingProtocol(LiveServiceProfile.GEMINI_PROTOCOL_ID)
        assertEquals("wss://proxy.example.com/live", customSwitched.endpoint)
        assertEquals("custom-model", customSwitched.modelID)

        // Minimal Gemini JSON without Qwen VAD fields parses cleanly.
        val minimalJson = JSONObject(
            """{"id":"g1","name":"Gemini","endpoint":"${LiveServiceProfile.GEMINI_DEFAULT_ENDPOINT}","modelID":"gemini-2.5-flash-native-audio-preview-12-2025","protocolID":"gemini-live","version":"1.0"}""",
        )
        val parsed = LiveServiceProfile.parse(minimalJson)
        assertTrue(parsed.isGeminiLive)
        parsed.validate()

        // Unsupported Gemini version rejected.
        assertRejected("unsupported gemini version") {
            parsed.copy(version = "2.0").validate()
        }

        // URL validation & normalization: AI Studio and Vertex AI endpoints allowed without ?model= query.
        val aiStudio = LiveTranslateConfig(
            catalog = LiveServiceCatalog(geminiProfile(endpoint = "wss://GENERATIVELANGUAGE.GOOGLEAPIS.COM:443/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")),
        ).normalized()
        assertEquals(LiveServiceProfile.GEMINI_DEFAULT_ENDPOINT, aiStudio.endpoint)
        assertEquals(LiveServiceProfile.GEMINI_DEFAULT_ENDPOINT, aiStudio.url())
        assertEquals("livetranslate:" + LiveServiceProfile.GEMINI_DEFAULT_ENDPOINT, aiStudio.keyAccount)

        val vertexEndpoint = "wss://us-central1-aiplatform.googleapis.com/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent"
        val vertex = LiveTranslateConfig(
            catalog = LiveServiceCatalog(geminiProfile(endpoint = vertexEndpoint, modelID = "projects/p/locations/us-central1/publishers/google/models/gemini-live-2.5-flash-native-audio")),
        ).normalized()
        assertEquals(vertexEndpoint, vertex.url())
        assertTrue(GeminiLiveAdapter.usesBearerAuth(vertex.url(), "access-token"))
        assertTrue(GeminiLiveAdapter.usesBearerAuth(aiStudio.url(), "ya29.oauth-token"))
        assertFalse(GeminiLiveAdapter.usesBearerAuth(aiStudio.url(), "AIzaSyMockKey"))

        // Reject query parameters (prevents ?key=secret in saved endpoint).
        for (bad in listOf(
            "${LiveServiceProfile.GEMINI_DEFAULT_ENDPOINT}?key=secret",
            "${LiveServiceProfile.GEMINI_DEFAULT_ENDPOINT}?model=foo",
            "https://generativelanguage.googleapis.com/ws/foo",
            "wss://user:pass@generativelanguage.googleapis.com/ws/foo",
            "wss://generativelanguage.googleapis.com/",
        )) {
            assertRejected("unsafe gemini URL rejected: $bad") {
                LiveTranslateConfig(catalog = LiveServiceCatalog(geminiProfile(endpoint = bad))).url()
            }
        }
    }

    @Test
    fun setupMessageAndModelNormalization() {
        assertEquals("models/gemini-2.5-flash-native-audio-preview-12-2025", GeminiLiveAdapter.normalizedModelName("gemini-2.5-flash-native-audio-preview-12-2025"))
        assertEquals("models/gemini-2.0-flash-exp", GeminiLiveAdapter.normalizedModelName("models/gemini-2.0-flash-exp"))
        val vertexModel = "projects/my-proj/locations/us-central1/publishers/google/models/gemini-live-2.5-flash-native-audio"
        assertEquals(vertexModel, GeminiLiveAdapter.normalizedModelName(vertexModel))

        // Native-audio model uses AUDIO + outputAudioTranscription even when audioOutput is false.
        val nativeTextOnly = LiveTranslateConfig(
            catalog = LiveServiceCatalog(geminiProfile(modelID = "gemini-2.5-flash-native-audio-preview-12-2025")),
            language = "ja",
            audioOutput = false,
        )
        val nativeSetup = GeminiLiveAdapter.setupMessage(nativeTextOnly).getJSONObject("setup")
        assertEquals("models/gemini-2.5-flash-native-audio-preview-12-2025", nativeSetup.getString("model"))
        assertEquals("AUDIO", nativeSetup.getJSONObject("generationConfig").getJSONArray("responseModalities").getString(0))
        assertTrue(nativeSetup.has("inputAudioTranscription"))
        assertTrue(nativeSetup.has("outputAudioTranscription"))
        assertTrue(nativeSetup.getJSONObject("systemInstruction").getJSONArray("parts").getJSONObject(0).getString("text").contains("Japanese"))

        // Non-native-audio model uses TEXT modality when audioOutput is false.
        val textCapable = LiveTranslateConfig(
            catalog = LiveServiceCatalog(geminiProfile(modelID = "gemini-2.0-flash-exp")),
            language = "zh",
            audioOutput = false,
        )
        val textSetup = GeminiLiveAdapter.setupMessage(textCapable).getJSONObject("setup")
        assertEquals("models/gemini-2.0-flash-exp", textSetup.getString("model"))
        assertEquals("TEXT", textSetup.getJSONObject("generationConfig").getJSONArray("responseModalities").getString(0))
        assertTrue(textSetup.has("inputAudioTranscription"))
        assertFalse(textSetup.has("outputAudioTranscription"))
    }

    @Test
    fun connectionTestSendsNoAudioAndFinishesCleanly() {
        val probe = Probe()
        assertEquals(AppendResult.CLOSED, probe.client.append(ByteArray(2)))
        probe.connect("/ok")
        probe.waitFor { probe.ready || probe.ended }
        assertTrue("setupComplete received", probe.ready)
        probe.client.finish()
        probe.waitFor { probe.ended }
        assertNull(probe.error)
        assertTrue(probe.events.rows.isEmpty())
    }

    @Test
    fun textModalityNativeAudioTextOnlyAndAudioPlaybackModes() {
        // 1. Non-native-audio model in TEXT modality.
        val textProbe = Probe()
        textProbe.connect("/ok", audio = false, modelID = "gemini-2.0-flash-exp")
        textProbe.waitFor { textProbe.ready || textProbe.ended }
        assertTrue(textProbe.ready)
        assertEquals(AppendResult.SENT, textProbe.client.append(ByteArray(640)))
        textProbe.client.finish()
        textProbe.waitFor { textProbe.ended }
        assertNull(textProbe.error)
        val textRow = textProbe.events.rows.values.single()
        assertEquals("Hello world.", textRow.source.text)
        assertTrue(textRow.source.done)
        assertEquals("你好，世界🌏。", textProbe.events.translation(textRow).text)
        assertTrue(textProbe.events.translation(textRow).done)
        assertEquals(0, textProbe.audioBytes)

        // 2. Native-audio model with audioOutput = false discards inline audio while keeping subtitles.
        val nativeSilent = Probe()
        nativeSilent.connect("/ok", audio = false)
        nativeSilent.waitFor { nativeSilent.ready }
        assertEquals(AppendResult.SENT, nativeSilent.client.append(ByteArray(640)))
        nativeSilent.client.finish()
        nativeSilent.waitFor { nativeSilent.ended }
        assertNull(nativeSilent.error)
        assertEquals(0, nativeSilent.audioBytes)
        val silentRow = nativeSilent.events.rows.values.single()
        assertEquals("Hello world.", silentRow.source.text)
        assertEquals("你好，世界🌏。", nativeSilent.events.translation(silentRow).text)

        // 3. Native-audio model with audioOutput = true in STREAMING and AFTER_FINAL modes (odd-byte PCM split).
        for (timing in listOf(PlaybackTiming.STREAMING, PlaybackTiming.AFTER_FINAL)) {
            val spoken = Probe(timing = timing)
            spoken.connect("/ok", audio = true)
            spoken.waitFor { spoken.ready }
            assertEquals(AppendResult.SENT, spoken.client.append(ByteArray(640)))
            spoken.client.finish()
            spoken.waitFor { spoken.ended }
            assertNull(spoken.error)
            assertNull(spoken.audioError)
            assertEquals("odd-byte PCM16 chunks reassembled ($timing)", 4800, spoken.audioBytes)
            val row = spoken.events.rows.values.single()
            assertEquals("Hello world.", row.source.text)
            assertEquals("你好，世界🌏。", spoken.events.translation(row).text)
        }
    }

    @Test
    fun bearerAuthAndInterruptedTurnPreserveSubtitles() {
        val bearer = Probe()
        bearer.connect("/bearer", audio = false, key = "ya29.mock-token")
        bearer.waitFor { bearer.ready || bearer.ended }
        assertTrue("Bearer auth succeeded", bearer.ready)
        bearer.client.finish()
        bearer.waitFor { bearer.ended }
        assertNull(bearer.error)

        val interrupted = Probe()
        interrupted.connect("/interrupted", audio = false)
        interrupted.waitFor { interrupted.ready }
        assertEquals(AppendResult.SENT, interrupted.client.append(ByteArray(640)))
        interrupted.waitFor { interrupted.events.rows.values.any { it.source.text == "First part" && it.source.done } }
        interrupted.client.finish()
        interrupted.waitFor { interrupted.ended }
        assertNull(interrupted.error)
        assertEquals(2, interrupted.events.order.size)
        val first = interrupted.events.rows[interrupted.events.order[0]]!!
        val second = interrupted.events.rows[interrupted.events.order[1]]!!
        assertEquals("First part", first.source.text)
        assertEquals("第一段", interrupted.events.translation(first).text)
        assertEquals("Second part.", second.source.text)
        assertEquals("第二段。", interrupted.events.translation(second).text)
    }

    @Test
    fun malformedAudioWarnsWithoutStoppingSubtitles() {
        val probe = Probe()
        probe.connect("/bad-audio", audio = true)
        probe.waitFor { probe.ready }
        assertEquals(AppendResult.SENT, probe.client.append(ByteArray(640)))
        probe.client.finish()
        probe.waitFor { probe.ended }
        assertNull(probe.error)
        assertEquals(LiveMessage.AudioInvalidFormat, probe.audioError)
        val row = probe.events.rows.values.single()
        assertEquals("Hello world.", row.source.text)
        assertEquals("你好，世界🌏。", probe.events.translation(row).text)
    }

    @Test
    fun failuresAndRateLimitsAreClassifiedSafely() {
        val cases = mapOf(
            "/unauthorized" to Triple(false, EndCause.Kind.OTHER, LiveMessage.AuthError),
            "/forbidden" to Triple(false, EndCause.Kind.OTHER, LiveMessage.AuthError),
            "/http-429" to Triple(true, EndCause.Kind.RATE_LIMITED, LiveMessage.RateLimited),
            "/redirect" to Triple(false, EndCause.Kind.OTHER, LiveMessage.ConnectionLost),
            "/rate-limited" to Triple(true, EndCause.Kind.RATE_LIMITED, LiveMessage.RateLimited),
            "/json-error-auth" to Triple(false, EndCause.Kind.OTHER, LiveMessage.AuthError),
            "/json-error-rate" to Triple(true, EndCause.Kind.RATE_LIMITED, LiveMessage.RateLimited),
            "/close-1007" to Triple(false, EndCause.Kind.OTHER, LiveMessage.ServiceFailed),
            "/timeout" to Triple(false, EndCause.Kind.OTHER, LiveMessage.FinishTimeout),
        )
        for ((route, expected) in cases) {
            val probe = Probe(timeoutMs = 150)
            probe.connect(route)
            probe.waitFor { probe.ready || probe.ended }
            if (probe.ready) {
                probe.client.append(ByteArray(640))
                probe.client.finish()
            }
            probe.waitFor { probe.ended }
            assertNotNull("failure surfaced: $route", probe.error)
            assertFalse("never leaks API key: $route -> ${probe.error}", probe.error!!.contains("mock-gemini"))
            assertFalse("never leaks API key in cause: $route -> ${probe.cause.detail}", probe.cause.detail.contains("mock-gemini"))
            assertEquals("recoverable ($route)", expected.first, probe.recoverable)
            assertEquals("kind ($route)", expected.second, probe.cause.kind)
            assertEquals("error message ($route)", expected.third, probe.cause.errorMessage)
        }
    }

    @Test
    fun liveSessionReconnectsOnDropAndGoAwayUsingProfileTransport() {
        val thread = Executors.newSingleThreadScheduledExecutor()
        val snapshotRef = java.util.concurrent.atomic.AtomicReference(SessionSnapshot())
        val onChunkRef = java.util.concurrent.atomic.AtomicReference<((ByteArray) -> Unit)?>(null)
        val platform = object : SessionPlatform {
            override fun post(block: () -> Unit) = thread.execute(block)
            override fun schedule(delayMs: Long, block: () -> Unit): Cancellable {
                val future = thread.schedule(block, delayMs, TimeUnit.MILLISECONDS)
                return Cancellable { future.cancel(false) }
            }
            override fun transport(configuration: LiveTranslateConfig, listener: LiveTransport.Listener): LiveTransport =
                configuration.profile.transport(listener, thread, allowLocalhost = true)
            override fun startCapture(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit) { onChunkRef.set(onChunk) }
            override fun stopCapture() { onChunkRef.set(null) }
            override fun speech() = object : SpeechOutput {
                override fun start(volume: Float) = Unit
                override fun append(pcm: ByteArray): Boolean = true
                override fun finish(done: () -> Unit) = done()
                override fun stop() = Unit
            }
            override fun sessionActive(active: Boolean) = Unit
        }
        val session = LiveSession(platform) { snapshotRef.set(it) }
        fun waitFor(what: String, condition: (SessionSnapshot) -> Boolean) {
            repeat(1000) {
                if (condition(snapshotRef.get())) return
                Thread.sleep(10)
            }
            error("timed out waiting for $what: ${snapshotRef.get()}")
        }

        val config = LiveTranslateConfig(
            catalog = LiveServiceCatalog(geminiProfile(endpoint = "$base/drop-once/gemini-${System.nanoTime()}")),
        )
        platform.post { session.start(config, "mock-gemini") }
        waitFor("initial ready") { it.state == SessionState.RECORDING }
        onChunkRef.get()!!(ByteArray(640))
        waitFor("reconnect after drop") { it.state == SessionState.RECORDING && it.rows.any { row -> row.marker.isNotEmpty() } }
        onChunkRef.get()!!(ByteArray(640))
        waitFor("second connection partial") { it.rows.any { row -> row.source.contains("Hello") } }
        platform.post { session.stop() }
        waitFor("session idle") { it.state == SessionState.IDLE }
        val finalSnapshot = snapshotRef.get()
        assertEquals("", finalSnapshot.error)
        assertEquals(listOf("Before the break", "", "Hello world."), finalSnapshot.rows.map { it.source })
        assertEquals("你好，世界🌏。", finalSnapshot.rows[2].translation)
        assertTrue(finalSnapshot.rows[2].sourceDone && finalSnapshot.rows[2].translationDone)

        // Verify goAway is reported as recoverable.
        val goAwayProbe = Probe()
        goAwayProbe.connect("/go-away")
        goAwayProbe.waitFor { goAwayProbe.ready }
        goAwayProbe.client.append(ByteArray(640))
        goAwayProbe.waitFor { goAwayProbe.ended }
        assertTrue("goAway should be recoverable", goAwayProbe.recoverable)
        val goAwayRow = goAwayProbe.events.rows.values.single()
        assertEquals("Hello world.", goAwayRow.source.text)
        assertEquals("你好，世界🌏。", goAwayProbe.events.translation(goAwayRow).text)
    }

    @Test
    fun boundedQueueAndSilentCancel() {
        val probe = Probe()
        probe.connect("/ok")
        probe.waitFor { probe.ready }
        assertEquals(AppendResult.FULL, probe.client.append(ByteArray(320_001)))
        assertEquals(AppendResult.SENT, probe.client.append(ByteArray(640)))
        probe.client.cancel()
        Thread.sleep(100)
        val count = probe.callbackCount
        Thread.sleep(200)
        assertEquals(count, probe.callbackCount)
        assertFalse(probe.ended)
        assertEquals(AppendResult.CLOSED, probe.client.append(ByteArray(2)))
    }
}
