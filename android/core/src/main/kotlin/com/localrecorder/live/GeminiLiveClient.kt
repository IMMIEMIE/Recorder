package com.localrecorder.live

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * One Gemini Live API (`BidiGenerateContent`) session over WebSocket. Single use: create a new client per session.
 * All transport and turn state lives on one serial executor; callbacks are delivered on [callbackExecutor].
 */
class GeminiLiveClient(
    private val listener: LiveTransport.Listener,
    private val callbackExecutor: Executor,
    private val finishTimeoutMs: Long = 15_000,
    private val allowLocalhost: Boolean = false,
    private val httpClient: OkHttpClient = LiveTranslateClient.sharedHttpClient,
    private val wireObserver: ((JSONObject) -> Unit)? = null,
    private val diagnostic: (String) -> Unit = {},
) : LiveTransport {
    private val queue = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "gemini-live").apply { isDaemon = true }
    }

    @Volatile private var socket: WebSocket? = null
    @Volatile private var acceptingAudio = false

    private var configuration: LiveTranslateConfig? = null
    private var decoder = GeminiLiveTurnDecoder(audioOutput = false)
    private var started = false
    private var setupSent = false
    private var ready = false
    private var finishing = false
    private var closed = false
    private var goAwayReceived = false
    private var httpStatus: Int? = null
    private var deadline: ScheduledFuture<*>? = null
    private var idleFinishTimer = false
    private var cause: LiveMessage? = null

    private var sentBytes = 0L
    private var hasSentAudio = false
    private var hasAudioSinceLastTurn = false

    // OkHttp's queue holds base64 JSON; convert back to an estimate of raw PCM bytes.
    override val queuedAudioBytes: Int
        get() = ((socket?.queueSize() ?: 0L) * 3 / 4).toInt()

    private fun currentAudioMs(): Int = (sentBytes / (LiveTranslateConfig.INPUT_SAMPLE_RATE * 2 / 1000)).toInt()

    override fun connect(configuration: LiveTranslateConfig, key: String) {
        if (key.isEmpty()) throw LiveTranslateException(LiveMessage.MissingApiKey)
        if (key.any { it.code !in 33..126 }) throw LiveTranslateException(LiveMessage.InvalidApiKeyFormat)
        val url = configuration.url(allowLocalhost)
        val builder = Request.Builder().url(url)
        if (GeminiLiveAdapter.usesBearerAuth(url, key)) {
            builder.header("Authorization", "Bearer $key")
        } else {
            builder.header("x-goog-api-key", key)
        }
        val request = builder.build()
        runSync {
            check(!started) { "GeminiLiveClient is single use" }
            started = true
            this.configuration = configuration
            this.decoder = GeminiLiveTurnDecoder(audioOutput = configuration.audioOutput)
            socket = httpClient.newWebSocket(request, SocketListener())
            armTimeout(20_000, LiveMessage.ConnectTimeout, recoverable = true, detail = LiveMessage.CauseConnectTimeout)
        }
    }

    override fun append(pcm: ByteArray): AppendResult {
        if (!acceptingAudio) return AppendResult.CLOSED
        return runSync {
            val current = socket
            if (!ready || finishing || closed || current == null) return@runSync AppendResult.CLOSED
            if (queuedAudioBytes + pcm.size > LiveTranslateClient.MAX_QUEUED_AUDIO_BYTES) return@runSync AppendResult.FULL
            val sent = send(GeminiLiveAdapter.realtimeAudioMessage(pcm))
            if (sent) {
                sentBytes += pcm.size
                hasSentAudio = true
                hasAudioSinceLastTurn = true
                AppendResult.SENT
            } else {
                AppendResult.CLOSED
            }
        } ?: AppendResult.CLOSED
    }

    override fun finish() {
        post {
            if (!ready || closed || finishing) return@post
            finishing = true
            acceptingAudio = false
            if (!hasSentAudio || (!decoder.turnOpen && !hasAudioSinceLastTurn)) {
                end(null)
                return@post
            }
            if (!send(GeminiLiveAdapter.audioStreamEndMessage())) return@post
            if (!decoder.turnOpen && decoder.completedTurns > 0) {
                idleFinishTimer = true
                armTimeout(minOf(finishTimeoutMs, 3_000L), error = null)
            } else {
                idleFinishTimer = false
                armTimeout(finishTimeoutMs, error = LiveMessage.FinishTimeout)
            }
        }
    }

    override fun cancel() {
        runSync { end(null, notify = false) }
    }

    private fun armTimeout(ms: Long, error: LiveMessage?, recoverable: Boolean = false, detail: LiveMessage? = null) {
        deadline?.cancel(false)
        deadline = try {
            queue.schedule({
                if (detail != null) note(detail)
                end(error, recoverable = recoverable)
            }, ms, TimeUnit.MILLISECONDS)
        } catch (_: RejectedExecutionException) {
            null
        }
    }

    private fun send(payload: JSONObject): Boolean {
        if (socket?.send(payload.toString()) != true) {
            disconnected()
            return false
        }
        return true
    }

    private fun handle(text: String) {
        if (closed) return
        val json = try {
            JSONObject(text)
        } catch (_: Exception) {
            null
        }
        if (json == null) {
            end(LiveMessage.InvalidServerData)
            return
        }
        wireObserver?.let { observer -> callbackExecutor.execute { observer(json) } }

        val errorObj = json.optJSONObject("error")
        if (errorObj != null) {
            val status = errorObj.optStringOrNull("status") ?: ""
            val code = if (errorObj.has("code") && !errorObj.isNull("code")) errorObj.optInt("code", -1).takeIf { it > 0 } else null
            val message = errorObj.optStringOrNull("message") ?: ""
            val classified = GeminiLiveAdapter.classifyError(code, null, "$status $message")
            classified.cause?.let(::note)
            end(classified.error, recoverable = classified.recoverable, kind = classified.kind)
            return
        }

        if (json.has("setupComplete")) {
            if (!ready) {
                ready = true
                acceptingAudio = true
                deadline?.cancel(false)
                deadline = null
                callbackExecutor.execute { listener.onReady() }
            }
            return
        }

        val serverContent = json.optJSONObject("serverContent")
        if (serverContent != null) {
            val wasTurnOpen = decoder.turnOpen
            val decoded = decoder.decode(serverContent, currentAudioMs())
            if (!wasTurnOpen && decoder.turnOpen && finishing && idleFinishTimer) {
                idleFinishTimer = false
                armTimeout(finishTimeoutMs, error = LiveMessage.FinishTimeout)
            }
            if (decoded.events.isNotEmpty()) {
                callbackExecutor.execute {
                    for (ev in decoded.events) listener.onEvent(ev)
                }
            }
            if (decoded.turnComplete) {
                hasAudioSinceLastTurn = false
                if (finishing) {
                    end(null)
                    return
                }
                if (goAwayReceived) {
                    note(LiveMessage.CauseServerFinished)
                    end(LiveMessage.SessionEndedUnexpectedly, recoverable = true)
                    return
                }
            }
        }

        if (json.has("goAway")) {
            goAwayReceived = true
            if (!decoder.turnOpen) {
                if (finishing) {
                    end(null)
                } else {
                    note(LiveMessage.CauseServerFinished)
                    end(LiveMessage.SessionEndedUnexpectedly, recoverable = true)
                }
            }
        }
    }

    private fun closing(code: Int, reason: String) {
        if (closed) return
        diagnostic("gemini server closing: code=$code")
        if (finishing && code == 1000) {
            flushOpenTurnOnCleanClose()
            end(null)
            return
        }
        if (code == 1000) {
            note(LiveMessage.CauseServerFinished)
            end(LiveMessage.SessionEndedUnexpectedly, recoverable = true)
            return
        }
        val classified = GeminiLiveAdapter.classifyError(httpStatus, code, reason)
        classified.cause?.let(::note)
        end(classified.error, recoverable = classified.recoverable, kind = classified.kind)
    }

    private fun disconnected() {
        val classified = GeminiLiveAdapter.classifyError(httpStatus, null, "")
        classified.cause?.let(::note)
        end(classified.error, recoverable = classified.recoverable, kind = classified.kind)
    }

    private fun flushOpenTurnOnCleanClose() {
        val tail = decoder.finalizeOpenTurn(currentAudioMs())
        if (tail.isNotEmpty()) {
            callbackExecutor.execute {
                for (ev in tail) listener.onEvent(ev)
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
            response.close()
            post {
                if (closed || setupSent) return@post
                val config = configuration ?: return@post
                setupSent = true
                send(GeminiLiveAdapter.setupMessage(config))
            }
        }

        override fun onMessage(webSocket: WebSocket, text: String) = post { handle(text) }
        override fun onMessage(webSocket: WebSocket, bytes: ByteString) = post { handle(bytes.utf8()) }
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) = post { closing(code, reason) }
        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = post { closing(code, reason) }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            val status = response?.code
            val detail = "gemini failure: ${t.javaClass.simpleName}" + (status?.let { " (HTTP $it)" } ?: "")
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
