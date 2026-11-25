package com.localrecorder.live

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

enum class AppendResult { SENT, FULL, CLOSED }

/**
 * Why a connection ended, beyond `recoverable`: [kind] picks how a session retries, [detail] is a short
 * category plus transport detail for the reconnecting status (never the key; empty when nothing is known).
 */
data class EndCause(
    val kind: Kind = Kind.OTHER,
    val detail: String = "",
    val detailMessage: LiveMessage? = null,
    val errorMessage: LiveMessage? = null,
) {
    enum class Kind {
        OTHER,

        /** The service refused the request rate (close code 1007 or a rate-limit reason): wait before the next attempt. */
        RATE_LIMITED,

        /** The service closed a session that produced no result for 60 s of audio (long silence): just open a new one. */
        NO_RESULT,
    }
}

/** What a session needs from the realtime connection; [LiveTranslateClient] is the only production implementation. */
interface LiveTransport {
    interface Listener {
        fun onReady()
        /** Result of an in-session language change. A rejection leaves the connection available for handoff. */
        fun onLanguageUpdate(language: String, confirmed: Boolean) {}
        fun onEvent(event: LiveSessionEvent)

        /**
         * [recoverable]: the connection itself failed or the server closed the session, so a new session may work.
         * [cause] says why, for recoverable ends that need different handling and for the status line.
         */
        fun onEnd(error: String?, recoverable: Boolean, cause: EndCause = EndCause())
    }

    fun connect(configuration: LiveTranslateConfig, key: String)

    /** False if this transport has no in-session update support. */
    fun updateLanguage(language: String): Boolean = false

    /** Queues 16 kHz mono PCM16: FULL when the outgoing queue is at its limit, CLOSED when not ready, finishing or ended. */
    fun append(pcm: ByteArray): AppendResult

    /** Estimated raw PCM bytes still waiting to be sent (current, also between appends); 0 once ended. */
    val queuedAudioBytes: Int

    /** Asks the server to drain the tail; `onEnd` follows `session.finished` or a timeout. */
    fun finish()

    /** Closes immediately without a callback. */
    fun cancel()
}

/**
 * One LiveTranslate session over the realtime WebSocket. Single use: create a new client per session.
 * All transport state lives on one serial executor; audio producers only enqueue bounded data.
 * Callbacks are delivered on [callbackExecutor] (the main thread in the app).
 */
class LiveTranslateClient(
    private val listener: LiveTransport.Listener,
    private val callbackExecutor: Executor,
    private val finishTimeoutMs: Long = 30_000,
    private val allowLocalhost: Boolean = false,
    private val httpClient: OkHttpClient = sharedHttpClient,
    /** Optional wire-level measurements for the JVM probe and local fixture. */
    private val wireObserver: ((JSONObject) -> Unit)? = null,
    /**
     * Transport detail behind a disconnect (exception class and message, close code), for diagnostics only:
     * the user-facing error stays the generic Chinese text. Never contains the key. Runs on the client's queue.
     */
    private val diagnostic: (String) -> Unit = {},
) : LiveTransport {
    companion object {
        /** Raw PCM bytes allowed to wait in the outgoing queue (~10 s of 16 kHz PCM16). */
        const val MAX_QUEUED_AUDIO_BYTES = 320_000

        const val RATE_LIMITED_ERROR = "LiveTranslate 请求过于频繁（限流），请稍后重试；已有文字已保留"
        const val NO_RESULT_ERROR = "LiveTranslate 长时间没有识别结果，服务端结束了会话；已有文字已保留"

        /** Close code the service uses for a refused request rate (with a "rate limit" reason). */
        const val RATE_LIMIT_CLOSE_CODE = 1007

        fun isRateLimit(text: String): Boolean {
            val value = text.lowercase()
            return "rate limit" in value || "rate_limit" in value || "ratelimit" in value || "throttl" in value
        }

        /** The service ends a session after 60 s of merged audio without a result ("no semantic result after …"). */
        fun isNoResult(text: String): Boolean = "no semantic result" in text.lowercase()

        // Redirects are refused: the bearer token must only ever reach the configured host.
        val sharedHttpClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .followRedirects(false)
                .followSslRedirects(false)
                .retryOnConnectionFailure(false)
                .connectTimeout(20, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.MILLISECONDS)
                .pingInterval(20, TimeUnit.SECONDS)
                .cache(null)
                .build()
        }

        fun serviceErrorMessage(code: String): LiveMessage {
            val value = code.lowercase()
            if ("auth" in value || "key" in value || "permission" in value) {
                return LiveMessage.AuthError
            }
            if ("limit" in value || "quota" in value || "balance" in value) {
                return LiveMessage.QuotaOrLimitError
            }
            return LiveMessage.ServiceFailed
        }

        fun serviceError(code: String): String = serviceErrorMessage(code).defaultText
    }

    private val queue = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "livetranslate").apply { isDaemon = true }
    }

    // Written on the queue; read by [queuedAudioBytes] from any thread (OkHttp's queueSize is synchronized).
    @Volatile private var socket: WebSocket? = null
    private var configuration: LiveTranslateConfig? = null
    private var ready = false
    private var finishing = false
    private var closed = false
    private var configured = false
    private var changingTo: String? = null
    private var started = false
    private var httpStatus: Int? = null
    private var deadline: ScheduledFuture<*>? = null

    /** The last transport detail, for [EndCause.detail]. */
    private var cause: LiveMessage? = null

    @Volatile private var acceptingAudio = false

    // OkHttp's queue holds base64 JSON; convert back to an estimate of raw PCM bytes.
    override val queuedAudioBytes: Int
        get() = ((socket?.queueSize() ?: 0L) * 3 / 4).toInt()

    override fun connect(configuration: LiveTranslateConfig, key: String) {
        if (key.isEmpty()) throw LiveTranslateException(LiveMessage.MissingApiKey)
        if (key.any { it.code !in 33..126 }) throw LiveTranslateException(LiveMessage.InvalidApiKeyFormat)
        val url = configuration.url(allowLocalhost)
        val request = Request.Builder().url(url).header("Authorization", "Bearer $key").build()
        runSync {
            check(!started) { "LiveTranslateClient is single use" }
            started = true
            this.configuration = configuration
            socket = httpClient.newWebSocket(request, SocketListener())
            armTimeout(20_000, LiveMessage.ConnectTimeout, recoverable = true, detail = LiveMessage.CauseConnectTimeout)
        }
    }

    override fun updateLanguage(language: String): Boolean = runSync {
        val current = configuration ?: return@runSync false
        if (!ready || finishing || closed || changingTo != null) return@runSync false
        changingTo = language
        send(current.copy(language = language).sessionUpdate())
    } ?: false

    private fun completeLanguageUpdate(language: String, confirmed: Boolean) {
        changingTo = null
        if (confirmed) configuration = configuration?.copy(language = language)
        callbackExecutor.execute { listener.onLanguageUpdate(language, confirmed) }
    }

    override fun append(pcm: ByteArray): AppendResult {
        if (!acceptingAudio) return AppendResult.CLOSED
        return runSync {
            val socket = socket
            if (!ready || finishing || closed || socket == null) return@runSync AppendResult.CLOSED
            if (queuedAudioBytes + pcm.size > MAX_QUEUED_AUDIO_BYTES) return@runSync AppendResult.FULL
            val sent = send(JSONObject().put("type", "input_audio_buffer.append").put("audio", Base64.getEncoder().encodeToString(pcm)))
            if (sent) AppendResult.SENT else AppendResult.CLOSED
        } ?: AppendResult.CLOSED
    }

    override fun finish() {
        post {
            if (!ready || closed || finishing) return@post
            finishing = true
            acceptingAudio = false
            armTimeout(finishTimeoutMs, LiveMessage.FinishTimeout)
            send(JSONObject().put("type", "session.finish"))
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

    private fun send(event: JSONObject): Boolean {
        event.put("event_id", UUID.randomUUID().toString())
        // OkHttp keeps send order, so session.finish always follows the queued audio.
        if (socket?.send(event.toString()) != true) {
            disconnected()
            return false
        }
        return true
    }

    private fun handle(text: String) {
        if (closed) return
        val event = try {
            JSONObject(text)
        } catch (_: Exception) {
            null
        }
        val type = event?.optStringOrNull("type")
        if (event == null || type == null) {
            end(LiveMessage.InvalidServerData); return
        }
        val configuration = configuration ?: return
        when (type) {
            "session.created" -> if (!configured) {
                configured = true
                send(configuration.sessionUpdate())
            }
            "session.updated" -> {
                if (!configured) {
                    end(LiveMessage.InvalidSessionOrder); return
                }
                val session = event.optJSONObject("session")
                val modalities = session?.optJSONArray("output_modalities").toStringSet()
                val language = session?.optJSONObject("translation")?.optStringOrNull("language")
                val requested = changingTo
                if (ready && requested != null) {
                    // Partial acknowledgements sometimes omit unchanged modalities, but the language itself must match.
                    val confirmed = language == requested && (modalities.isEmpty() || modalities == configuration.outputModalities.toSet())
                    completeLanguageUpdate(requested, confirmed)
                    return
                }
                if (session == null || modalities != configuration.outputModalities.toSet() || language != configuration.language) {
                    end(LiveMessage.UnconfirmedOutputOrLanguage); return
                }
                if (configuration.audioOutput) {
                    val format = session.optJSONObject("audio")?.optJSONObject("output")?.optJSONObject("format")
                    if (format?.optStringOrNull("type") != "pcm" || format.optInt("sample_rate") != LiveTranslateConfig.OUTPUT_SAMPLE_RATE) {
                        end(LiveMessage.UnconfirmedPcmFormat); return
                    }
                }
                if (!ready) {
                    ready = true
                    acceptingAudio = true
                    deadline?.cancel(false)
                    callbackExecutor.execute { listener.onReady() }
                }
            }
            "session.finished" -> {
                // The service may close a session by itself (e.g. a duration limit); a new one can continue.
                if (finishing) {
                    end(null)
                } else {
                    note(LiveMessage.CauseServerFinished)
                    end(LiveMessage.SessionEndedUnexpectedly, recoverable = true)
                }
                return
            }
            "error", "conversation.item.input_audio_transcription.failed" -> {
                val error = event.optJSONObject("error")
                val code = error?.optStringOrNull("code") ?: ""
                val message = error?.optStringOrNull("message") ?: ""
                when {
                    isNoResult(message) || isNoResult(code) -> {
                        note(LiveMessage.CauseNoResult)
                        end(LiveMessage.NoResult, recoverable = true, kind = EndCause.Kind.NO_RESULT)
                    }
                    isRateLimit(code) || isRateLimit(message) -> {
                        note(LiveMessage.CauseRateLimited)
                        end(LiveMessage.RateLimited, recoverable = true, kind = EndCause.Kind.RATE_LIMITED)
                    }
                    type == "error" && changingTo != null -> completeLanguageUpdate(changingTo!!, false)
                    else -> end(serviceErrorMessage(code))
                }
                return
            }
            "response.done" -> {
                if (event.optJSONObject("response")?.optStringOrNull("status") != "completed") {
                    end(LiveMessage.TranslationIncomplete); return
                }
            }
        }
        val decoded = Qwen38Adapter.decode(event)
        if (decoded != null || wireObserver != null) callbackExecutor.execute {
            wireObserver?.invoke(event)
            if (decoded != null) listener.onEvent(decoded)
        }
    }

    private fun connectionError(): LiveMessage = when (httpStatus) {
        401, 403 -> LiveMessage.AuthError
        429 -> LiveMessage.Http429Error
        else -> LiveMessage.ConnectionLost
    }

    /** Transport-level failure: worth a new session unless the server answered with a client error. */
    private fun disconnected() {
        val status = httpStatus
        if (status == 429) {
            end(LiveMessage.RateLimited, recoverable = true, kind = EndCause.Kind.RATE_LIMITED)
            return
        }
        end(connectionError(), recoverable = status == null || status >= 500)
    }

    /** The server closes the WebSocket; the close code and reason say whether this is a rate limit or an idle session. */
    private fun closing(code: Int, reason: String) {
        if (closed) return
        diagnostic("server closing: code=$code")
        when {
            // First: the service may use 1007 for this too.
            isNoResult(reason) -> {
                note(LiveMessage.CauseServerClosed(code))
                end(LiveMessage.NoResult, recoverable = true, kind = EndCause.Kind.NO_RESULT)
            }
            code == RATE_LIMIT_CLOSE_CODE || isRateLimit(reason) -> {
                note(LiveMessage.CauseRateLimitedCode(code))
                end(LiveMessage.RateLimited, recoverable = true, kind = EndCause.Kind.RATE_LIMITED)
            }
            else -> {
                note(LiveMessage.CauseServerClosed(code))
                disconnected()
            }
        }
    }

    /** Records the short cause for [EndCause.detail]; the first one wins (later lines are consequences). */
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
        override fun onMessage(webSocket: WebSocket, text: String) = post { handle(text) }
        override fun onMessage(webSocket: WebSocket, bytes: ByteString) = post { handle(bytes.utf8()) }
        // Only for a connection still in use: a socket this client already closed reports nothing.
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

private fun JSONArray?.toStringSet(): Set<String> {
    if (this == null) return emptySet()
    return (0 until length()).mapNotNull { opt(it) as? String }.toSet()
}
