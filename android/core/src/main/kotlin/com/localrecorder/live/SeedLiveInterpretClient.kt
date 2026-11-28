package com.localrecorder.live

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Volcengine / BytePlus Seed-LiveInterpret 2.0 (`volc-ast`) binary WebSocket transport.
 * Wire framing: raw Protobuf `TranslateRequest` / `TranslateResponse` per binary WebSocket frame.
 * Translates AST 2.0 subtitle and TTS events into provider-neutral [LiveSessionEvent]s so
 * [LiveSession], [LiveTranslateEvents], [LiveTranslatePlaybackQueue] and [SessionRecorder]
 * work uniformly without duplicating finalized rows across reconnects.
 */
class SeedLiveInterpretClient(
    private val listener: LiveTransport.Listener,
    private val callbackExecutor: Executor,
    private val finishTimeoutMs: Long = 30_000,
    private val allowLocalhost: Boolean = false,
    private val httpClient: OkHttpClient = LiveTranslateClient.sharedHttpClient,
    private val wireObserver: ((VolcAstTranslateResponse) -> Unit)? = null,
    private val diagnostic: (String) -> Unit = {},
) : LiveTransport {

    companion object {
        private val OGG_MAGIC = byteArrayOf(0x4F, 0x67, 0x67, 0x53) // "OggS"

        fun buildStartSessionRequest(
            sessionID: String,
            connectionID: String,
            configuration: LiveTranslateConfig,
        ): VolcAstTranslateRequest {
            val profile = configuration.profile
            val mode = if (configuration.audioOutput) "s2s" else "s2t"
            val sourceLanguage = profile.resolvedSourceLanguage(configuration.language)
            // Official Volcengine AST 2.0 demo uses format="wav" for 16 kHz mono PCM16 uplink chunks.
            val sourceAudio = VolcAstAudio(format = "wav", rate = LiveTranslateConfig.INPUT_SAMPLE_RATE, bits = 16, channel = 1)
            // Request 24 kHz mono PCM16 output in s2s mode to directly feed the existing playback pipeline.
            val targetAudio = if (configuration.audioOutput) {
                VolcAstAudio(format = "pcm", rate = LiveTranslateConfig.OUTPUT_SAMPLE_RATE, bits = 16, channel = 1)
            } else {
                null
            }
            return VolcAstTranslateRequest(
                requestMeta = VolcAstRequestMeta(
                    resourceID = profile.modelID,
                    connectionID = connectionID,
                    sessionID = sessionID,
                    sequence = 1,
                ),
                event = VolcAstEventType.START_SESSION,
                user = VolcAstUser(uid = "shengjian_android", did = "shengjian_android"),
                sourceAudio = sourceAudio,
                targetAudio = targetAudio,
                request = VolcAstReqParams(
                    mode = mode,
                    sourceLanguage = sourceLanguage,
                    targetLanguage = configuration.language,
                ),
                denoise = false,
            )
        }

        fun serviceErrorMessage(code: Int, detail: String): LiveMessage {
            val lower = detail.lowercase()
            if (code == 11_200 || code == 401 || code == 403 || code == 45000010 || code == 45000030 ||
                "auth" in lower || "key" in lower || "permission" in lower ||
                "unauthorized" in lower || "forbidden" in lower || "resource" in lower
            ) {
                return LiveMessage.AuthError
            }
            if (code == 11_301 || code == 11_303 || code == 429 || LiveTranslateClient.isRateLimit(lower)) {
                return LiveMessage.RateLimited
            }
            if (code == 11_302 || "limit" in lower || "quota" in lower || "balance" in lower || "arrears" in lower) {
                return LiveMessage.QuotaOrLimitError
            }
            return LiveMessage.ServiceFailed
        }
    }

    private val queue = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "seed-liveinterpret").apply { isDaemon = true }
    }

    @Volatile private var socket: WebSocket? = null
    @Volatile private var acceptingAudio = false

    private var configuration: LiveTranslateConfig? = null
    private var sessionID = ""
    private var connectionID = ""
    private var sequence = 0
    private var ready = false
    private var finishing = false
    private var closed = false
    private var started = false
    private var httpStatus: Int? = null
    private var deadline: ScheduledFuture<*>? = null
    private var cause: LiveMessage? = null
    private var startFrame: ByteArray? = null

    // Per-connection sequential turn tracking for source, translation, and TTS streams.
    private var nextSourceTurn = 0
    private var nextTranslationTurn = 0
    private var nextTtsTurn = 0
    private var activeSourceTurn: Int? = null
    private var activeTranslationTurn: Int? = null
    private var activeTtsTurn: Int? = null
    private var sourceBuffer = ""
    private var translationBuffer = ""
    private val linkedTurns = HashSet<Int>()
    private var eventSeq = 0

    override val queuedAudioBytes: Int
        get() = (socket?.queueSize() ?: 0L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()

    override fun connect(configuration: LiveTranslateConfig, key: String) {
        if (key.isEmpty()) throw LiveTranslateException(LiveMessage.MissingApiKey)
        if (key.any { it.code !in 33..126 }) throw LiveTranslateException(LiveMessage.InvalidApiKeyFormat)
        val url = configuration.url(allowLocalhost)
        val profile = configuration.profile
        val appKey = profile.appKey.trim()
        val connID = UUID.randomUUID().toString()
        val sid = UUID.randomUUID().toString()

        val requestBuilder = Request.Builder()
            .url(url)
            .header("X-Api-Resource-Id", profile.modelID)
            .header("X-Api-Connect-Id", connID)
        if (appKey.isEmpty()) {
            requestBuilder.header("X-Api-Key", key)
        } else {
            requestBuilder.header("X-Api-App-Key", appKey)
            requestBuilder.header("X-Api-Access-Key", key)
        }
        val request = requestBuilder.build()
        val encodedStart = buildStartSessionRequest(sid, connID, configuration).encode()

        runSync {
            check(!started) { "SeedLiveInterpretClient is single use" }
            started = true
            this.configuration = configuration
            this.sessionID = sid
            this.connectionID = connID
            this.sequence = 1
            this.startFrame = encodedStart
            socket = httpClient.newWebSocket(request, SocketListener())
            armTimeout(20_000, LiveMessage.ConnectTimeout, recoverable = true, detail = LiveMessage.CauseConnectTimeout)
        }
    }

    override fun append(pcm: ByteArray): AppendResult {
        if (!acceptingAudio) return AppendResult.CLOSED
        return runSync {
            val currentSocket = socket
            if (!ready || finishing || closed || currentSocket == null) return@runSync AppendResult.CLOSED
            if (queuedAudioBytes + pcm.size > LiveTranslateClient.MAX_QUEUED_AUDIO_BYTES) return@runSync AppendResult.FULL
            sequence += 1
            val payload = VolcAstTranslateRequest(
                requestMeta = VolcAstRequestMeta(sessionID = sessionID, sequence = sequence),
                event = VolcAstEventType.TASK_REQUEST,
                sourceAudio = VolcAstAudio(
                    format = "wav",
                    rate = LiveTranslateConfig.INPUT_SAMPLE_RATE,
                    bits = 16,
                    channel = 1,
                    binaryData = pcm,
                ),
            ).encode()
            val sent = sendBinary(payload)
            if (sent) AppendResult.SENT else AppendResult.CLOSED
        } ?: AppendResult.CLOSED
    }

    override fun finish() {
        post {
            if (!ready || closed || finishing) return@post
            finishing = true
            acceptingAudio = false
            armTimeout(finishTimeoutMs, LiveMessage.FinishTimeout)
            sequence += 1
            val payload = VolcAstTranslateRequest(
                requestMeta = VolcAstRequestMeta(sessionID = sessionID, sequence = sequence),
                event = VolcAstEventType.FINISH_SESSION,
            ).encode()
            sendBinary(payload)
        }
    }

    override fun cancel() {
        runSync { end(null, notify = false) }
    }

    private fun armTimeout(ms: Long, message: LiveMessage, recoverable: Boolean = false, detail: LiveMessage? = null) {
        deadline?.cancel(false)
        deadline = try {
            queue.schedule({
                if (detail != null) note(detail)
                end(message, recoverable = recoverable)
            }, ms, TimeUnit.MILLISECONDS)
        } catch (_: RejectedExecutionException) {
            null
        }
    }

    private fun sendBinary(bytes: ByteArray): Boolean {
        if (socket?.send(ByteString.of(*bytes)) != true) {
            disconnected()
            return false
        }
        return true
    }

    private fun nextEventId(): String = "ast-ev-${++eventSeq}"
    private fun sourceItemId(turn: Int): String = "ast-src-$turn"
    private fun outputItemId(turn: Int): String = "ast-out-$turn"

    private fun emit(vararg events: LiveSessionEvent, observerResponse: VolcAstTranslateResponse? = null) {
        if (events.isEmpty() && (observerResponse == null || wireObserver == null)) return
        val list = events.toList()
        callbackExecutor.execute {
            if (observerResponse != null) wireObserver?.invoke(observerResponse)
            for (event in list) listener.onEvent(event)
        }
    }

    private fun ensureLinked(turn: Int, out: MutableList<LiveSessionEvent>) {
        if (linkedTurns.add(turn)) {
            out += LiveSessionEvent.Link(sourceItemId(turn), outputItemId(turn), nextEventId())
        }
    }

    private fun flushActiveTurns(out: MutableList<LiveSessionEvent>) {
        activeSourceTurn?.let { turn ->
            if (sourceBuffer.isNotEmpty()) {
                out += LiveSessionEvent.Text(sourceItemId(turn), sourceBuffer, source = true, final = true, eventID = nextEventId())
            }
            activeSourceTurn = null
            sourceBuffer = ""
        }
        activeTranslationTurn?.let { turn ->
            if (translationBuffer.isNotEmpty()) {
                out += LiveSessionEvent.Text(outputItemId(turn), translationBuffer, source = false, final = true, eventID = nextEventId())
            }
            activeTranslationTurn = null
            translationBuffer = ""
        }
        activeTtsTurn?.let { turn ->
            out += LiveSessionEvent.Audio(outputItemId(turn), null, final = true, eventID = nextEventId())
            activeTtsTurn = null
        }
    }

    private fun handleBinary(bytes: ByteArray) {
        if (closed) return
        val response = try {
            VolcAstTranslateResponse.decode(bytes)
        } catch (_: Exception) {
            end(LiveMessage.InvalidServerData)
            return
        }
        val config = configuration ?: return

        if (response.hasErrorStatus) {
            val code = response.responseMeta?.statusCode ?: 0
            val detail = response.responseMeta?.message.orEmpty()
            handleFailureStatus(code, detail)
            return
        }

        when (response.event) {
            VolcAstEventType.SESSION_STARTED, VolcAstEventType.CONNECTION_STARTED -> {
                val returnedId = response.responseMeta?.sessionID.orEmpty()
                if (returnedId.isNotEmpty()) sessionID = returnedId
                if (!ready) {
                    ready = true
                    acceptingAudio = true
                    deadline?.cancel(false)
                    callbackExecutor.execute {
                        wireObserver?.invoke(response)
                        listener.onReady()
                    }
                }
                return
            }
            VolcAstEventType.SESSION_FINISHED, VolcAstEventType.CONNECTION_FINISHED -> {
                if (finishing) {
                    val tail = mutableListOf<LiveSessionEvent>()
                    flushActiveTurns(tail)
                    emit(*tail.toTypedArray(), observerResponse = response)
                    end(null)
                } else {
                    note(LiveMessage.CauseServerFinished)
                    end(LiveMessage.SessionEndedUnexpectedly, recoverable = true)
                }
                return
            }
            VolcAstEventType.SESSION_FAILED, VolcAstEventType.CONNECTION_FAILED, VolcAstEventType.SESSION_CANCELED -> {
                val code = response.responseMeta?.statusCode ?: 0
                val detail = response.responseMeta?.message.orEmpty()
                handleFailureStatus(code, detail)
                return
            }
        }

        if (!ready) {
            end(LiveMessage.InvalidSessionOrder)
            return
        }

        val emitted = mutableListOf<LiveSessionEvent>()
        when (response.event) {
            VolcAstEventType.SOURCE_SUBTITLE_START -> {
                activeSourceTurn?.let { prev ->
                    if (sourceBuffer.isNotEmpty()) {
                        emitted += LiveSessionEvent.Text(sourceItemId(prev), sourceBuffer, source = true, final = true, eventID = nextEventId())
                    }
                }
                val turn = ++nextSourceTurn
                activeSourceTurn = turn
                sourceBuffer = ""
                ensureLinked(turn, emitted)
                if (response.startTime >= 0) {
                    emitted += LiveSessionEvent.SpeechStart(sourceItemId(turn), response.startTime, nextEventId())
                }
                appendSourceDelta(turn, response.text, emitted)
            }
            VolcAstEventType.SOURCE_SUBTITLE_RESPONSE -> {
                val turn = activeSourceTurn ?: (++nextSourceTurn).also {
                    activeSourceTurn = it
                    sourceBuffer = ""
                    ensureLinked(it, emitted)
                    if (response.startTime > 0) {
                        emitted += LiveSessionEvent.SpeechStart(sourceItemId(it), response.startTime, nextEventId())
                    }
                }
                appendSourceDelta(turn, response.text, emitted)
            }
            VolcAstEventType.SOURCE_SUBTITLE_END -> {
                val turn = activeSourceTurn ?: (++nextSourceTurn).also {
                    ensureLinked(it, emitted)
                    if (response.startTime > 0) {
                        emitted += LiveSessionEvent.SpeechStart(sourceItemId(it), response.startTime, nextEventId())
                    }
                }
                val finalText = response.text.ifEmpty { sourceBuffer }
                if (finalText.isNotEmpty()) {
                    emitted += LiveSessionEvent.Text(sourceItemId(turn), finalText, source = true, final = true, eventID = nextEventId())
                }
                if (response.endTime > 0) {
                    emitted += LiveSessionEvent.SpeechEnd(response.endTime, nextEventId(), sourceItemId(turn))
                }
                activeSourceTurn = null
                sourceBuffer = ""
            }
            VolcAstEventType.TRANSLATION_SUBTITLE_START -> {
                activeTranslationTurn?.let { prev ->
                    if (translationBuffer.isNotEmpty()) {
                        emitted += LiveSessionEvent.Text(outputItemId(prev), translationBuffer, source = false, final = true, eventID = nextEventId())
                    }
                }
                val turn = ++nextTranslationTurn
                activeTranslationTurn = turn
                translationBuffer = ""
                ensureLinked(turn, emitted)
                appendTranslationDelta(turn, response.text, emitted)
            }
            VolcAstEventType.TRANSLATION_SUBTITLE_RESPONSE -> {
                val turn = activeTranslationTurn ?: (++nextTranslationTurn).also {
                    activeTranslationTurn = it
                    translationBuffer = ""
                    ensureLinked(it, emitted)
                }
                appendTranslationDelta(turn, response.text, emitted)
            }
            VolcAstEventType.TRANSLATION_SUBTITLE_END -> {
                val turn = activeTranslationTurn ?: (++nextTranslationTurn).also {
                    ensureLinked(it, emitted)
                }
                val finalText = response.text.ifEmpty { translationBuffer }
                if (finalText.isNotEmpty()) {
                    emitted += LiveSessionEvent.Text(outputItemId(turn), finalText, source = false, final = true, eventID = nextEventId())
                }
                activeTranslationTurn = null
                translationBuffer = ""
            }
            VolcAstEventType.TTS_SENTENCE_START -> {
                if (config.audioOutput) {
                    activeTtsTurn?.let { prev ->
                        emitted += LiveSessionEvent.Audio(outputItemId(prev), null, final = true, eventID = nextEventId())
                    }
                    val turn = ++nextTtsTurn
                    activeTtsTurn = turn
                    ensureLinked(turn, emitted)
                }
            }
            VolcAstEventType.TTS_RESPONSE -> {
                if (config.audioOutput && response.data.isNotEmpty()) {
                    val turn = activeTtsTurn ?: (++nextTtsTurn).also {
                        activeTtsTurn = it
                        ensureLinked(it, emitted)
                    }
                    val isOgg = response.data.size >= 4 &&
                        response.data[0] == OGG_MAGIC[0] &&
                        response.data[1] == OGG_MAGIC[1] &&
                        response.data[2] == OGG_MAGIC[2] &&
                        response.data[3] == OGG_MAGIC[3]
                    // Null samples on a non-final Audio event cleanly signals invalid format to LiveTranslateAudioDecoder
                    // so playback stops with a user-visible notice while subtitles continue uninterrupted.
                    val pcm = if (isOgg) null else response.data
                    emitted += LiveSessionEvent.Audio(outputItemId(turn), pcm, final = false, eventID = nextEventId())
                }
            }
            VolcAstEventType.TTS_SENTENCE_END, VolcAstEventType.TTS_ENDED -> {
                if (config.audioOutput) {
                    activeTtsTurn?.let { turn ->
                        emitted += LiveSessionEvent.Audio(outputItemId(turn), null, final = true, eventID = nextEventId())
                        activeTtsTurn = null
                    }
                }
            }
        }

        emit(*emitted.toTypedArray(), observerResponse = response)
    }

    private fun appendSourceDelta(turn: Int, incoming: String, out: MutableList<LiveSessionEvent>) {
        if (incoming.isEmpty()) return
        sourceBuffer = VolcAstSubtitleMerger.append(sourceBuffer, incoming)
        out += LiveSessionEvent.Text(sourceItemId(turn), incoming, source = true, final = false, eventID = nextEventId())
    }

    private fun appendTranslationDelta(turn: Int, incoming: String, out: MutableList<LiveSessionEvent>) {
        if (incoming.isEmpty()) return
        translationBuffer = VolcAstSubtitleMerger.append(translationBuffer, incoming)
        out += LiveSessionEvent.Text(outputItemId(turn), incoming, source = false, final = false, eventID = nextEventId())
    }

    private fun handleFailureStatus(code: Int, detail: String) {
        val message = serviceErrorMessage(code, detail)
        when (message) {
            LiveMessage.RateLimited -> {
                note(LiveMessage.CauseRateLimited)
                end(LiveMessage.RateLimited, recoverable = true, kind = EndCause.Kind.RATE_LIMITED)
            }
            else -> end(message)
        }
    }

    private fun connectionError(): LiveMessage = when (httpStatus) {
        401, 403 -> LiveMessage.AuthError
        429 -> LiveMessage.Http429Error
        else -> LiveMessage.ConnectionLost
    }

    private fun disconnected() {
        val status = httpStatus
        if (status == 429) {
            end(LiveMessage.RateLimited, recoverable = true, kind = EndCause.Kind.RATE_LIMITED)
            return
        }
        end(connectionError(), recoverable = status == null || status >= 500)
    }

    private fun closing(code: Int, reason: String) {
        if (closed) return
        diagnostic("server closing: code=$code")
        when {
            LiveTranslateClient.isNoResult(reason) -> {
                note(LiveMessage.CauseServerClosed(code))
                end(LiveMessage.NoResult, recoverable = true, kind = EndCause.Kind.NO_RESULT)
            }
            code == LiveTranslateClient.RATE_LIMIT_CLOSE_CODE || LiveTranslateClient.isRateLimit(reason) -> {
                note(LiveMessage.CauseRateLimitedCode(code))
                end(LiveMessage.RateLimited, recoverable = true, kind = EndCause.Kind.RATE_LIMITED)
            }
            else -> {
                note(LiveMessage.CauseServerClosed(code))
                disconnected()
            }
        }
    }

    private fun note(detail: LiveMessage) {
        if (cause == null) cause = detail
    }

    private fun end(error: LiveMessage?, notify: Boolean = true, recoverable: Boolean = false, kind: EndCause.Kind = EndCause.Kind.OTHER) {
        if (closed) return
        closed = true
        ready = false
        acceptingAudio = false
        deadline?.cancel(false)
        deadline = null
        socket?.cancel()
        socket = null
        if (notify) {
            val detailMsg = cause ?: if (error != null && recoverable) LiveMessage.CauseDisconnected else null
            val ended = EndCause(kind, detailMsg?.defaultText.orEmpty(), detailMsg, error)
            callbackExecutor.execute { listener.onEnd(error?.defaultText, recoverable, ended) }
        }
        queue.shutdown()
    }

    private inner class SocketListener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            post {
                if (closed) return@post
                val frame = startFrame ?: return@post
                startFrame = null
                sendBinary(frame)
            }
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) = post { handleBinary(bytes.toByteArray()) }
        override fun onMessage(webSocket: WebSocket, text: String) = post { handleBinary(text.toByteArray(Charsets.UTF_8)) }
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) = post { closing(code, reason) }
        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = post { disconnected() }
        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            val status = response?.code
            val detail = "failure: " + t.javaClass.simpleName + (status?.let { " (HTTP $it)" } ?: "")
            response?.close()
            post {
                if (!closed) {
                    diagnostic(detail)
                    note(if (status != null) LiveMessage.CauseHandshakeFailed(status) else LiveMessage.CauseNetworkFailure(t.javaClass.simpleName))
                }
                httpStatus = status
                disconnected()
            }
        }
    }

    private fun post(block: () -> Unit) {
        try {
            queue.execute(block)
        } catch (_: RejectedExecutionException) {
            // Already ended; late transport callbacks are dropped.
        }
    }

    private fun <T> runSync(block: () -> T): T? = try {
        queue.submit(block).get()
    } catch (_: RejectedExecutionException) {
        null
    }
}
