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
data class EndCause(val kind: Kind = Kind.OTHER, val detail: String = "") {
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
        fun onEvent(event: LiveSessionEvent)

        /**
         * [recoverable]: the connection itself failed or the server closed the session, so a new session may work.
         * [cause] says why, for recoverable ends that need different handling and for the status line.
         */
        fun onEnd(error: String?, recoverable: Boolean, cause: EndCause = EndCause())
    }

    fun connect(configuration: LiveTranslateConfig, key: String)

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

        fun serviceError(code: String): String {
            val value = code.lowercase()
            if ("auth" in value || "key" in value || "permission" in value) {
                return "LiveTranslate API Key 无效或无权访问，请核对密钥、区域和工作空间"
            }
            if ("limit" in value || "quota" in value || "balance" in value) {
                return "LiveTranslate 请求受限或额度不足，请检查账户余额并稍后重试"
            }
            return "LiveTranslate 服务处理失败，请检查模型权限和会话配置；已有文字已保留"
        }
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
    private var started = false
    private var httpStatus: Int? = null
    private var deadline: ScheduledFuture<*>? = null

    /** The last transport detail, for [EndCause.detail]. */
    private var cause = ""

    @Volatile private var acceptingAudio = false

    // OkHttp's queue holds base64 JSON; convert back to an estimate of raw PCM bytes.
    override val queuedAudioBytes: Int
        get() = ((socket?.queueSize() ?: 0L) * 3 / 4).toInt()

    override fun connect(configuration: LiveTranslateConfig, key: String) {
        if (key.isEmpty()) throw LiveTranslateException("请在 LiveTranslate 设置中保存专用 API Key")
        if (key.any { it.code !in 33..126 }) throw LiveTranslateException("API Key 格式无效，请重新填写")
        val url = configuration.url(allowLocalhost)
        val request = Request.Builder().url(url).header("Authorization", "Bearer $key").build()
        runSync {
            check(!started) { "LiveTranslateClient is single use" }
            started = true
            this.configuration = configuration
            socket = httpClient.newWebSocket(request, SocketListener())
            armTimeout(20_000, "LiveTranslate 连接或会话配置超时，请检查网络和服务地址", recoverable = true, detail = "连接超时：20 秒内未完成会话配置")
        }
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
            armTimeout(finishTimeoutMs, "LiveTranslate 尾句处理超时，已保留收到的文字，末句可能不完整")
            send(JSONObject().put("type", "session.finish"))
        }
    }

    override fun cancel() {
        runSync { end(null, notify = false) }
    }

    private fun armTimeout(ms: Long, message: String, recoverable: Boolean = false, detail: String = "") {
        deadline?.cancel(false)
        deadline = try {
            queue.schedule({
                if (detail.isNotEmpty()) note(detail)
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
            end("LiveTranslate 返回无效数据"); return
        }
        val configuration = configuration ?: return
        when (type) {
            "session.created" -> if (!configured) {
                configured = true
                send(configuration.sessionUpdate())
            }
            "session.updated" -> {
                if (!configured) {
                    end("LiveTranslate 会话配置顺序异常"); return
                }
                val session = event.optJSONObject("session")
                val modalities = session?.optJSONArray("output_modalities").toStringSet()
                val language = session?.optJSONObject("translation")?.optStringOrNull("language")
                if (session == null || modalities != configuration.outputModalities.toSet() || language != configuration.language) {
                    end("LiveTranslate 未确认所选输出方式及目标语言，请检查模型和接口兼容性"); return
                }
                if (configuration.audioOutput) {
                    val format = session.optJSONObject("audio")?.optJSONObject("output")?.optJSONObject("format")
                    if (format?.optStringOrNull("type") != "pcm" || format.optInt("sample_rate") != LiveTranslateConfig.OUTPUT_SAMPLE_RATE) {
                        end("LiveTranslate 未确认 24 kHz PCM 译音格式"); return
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
                    note("服务端结束会话")
                    end("LiveTranslate 会话意外结束，已保留收到的文字", recoverable = true)
                }
                return
            }
            "error", "conversation.item.input_audio_transcription.failed" -> {
                val error = event.optJSONObject("error")
                val code = error?.optStringOrNull("code") ?: ""
                val message = error?.optStringOrNull("message") ?: ""
                when {
                    isNoResult(message) || isNoResult(code) -> {
                        note("服务端长时间无结果")
                        end(NO_RESULT_ERROR, recoverable = true, kind = EndCause.Kind.NO_RESULT)
                    }
                    isRateLimit(code) || isRateLimit(message) -> {
                        note("服务限流")
                        end(RATE_LIMITED_ERROR, recoverable = true, kind = EndCause.Kind.RATE_LIMITED)
                    }
                    else -> end(serviceError(code))
                }
                return
            }
            "response.done" -> {
                if (event.optJSONObject("response")?.optStringOrNull("status") != "completed") {
                    end("LiveTranslate 译文未完成，已保留收到的文字"); return
                }
            }
        }
        val decoded = Qwen38Adapter.decode(event)
        if (decoded != null || wireObserver != null) callbackExecutor.execute {
            wireObserver?.invoke(event)
            if (decoded != null) listener.onEvent(decoded)
        }
    }

    private fun connectionError(): String = when (httpStatus) {
        401, 403 -> "LiveTranslate API Key 无效或无权访问，请核对密钥、区域和工作空间"
        429 -> "LiveTranslate 请求受限或额度不足，请稍后重试"
        else -> "LiveTranslate 连接中断或无法连接，请检查网络、服务地址及 API Key；已有文字已保留"
    }

    /** Transport-level failure: worth a new session unless the server answered with a client error. */
    private fun disconnected() {
        val status = httpStatus
        if (status == 429) {
            end(RATE_LIMITED_ERROR, recoverable = true, kind = EndCause.Kind.RATE_LIMITED)
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
                note("服务端关闭：$code")
                end(NO_RESULT_ERROR, recoverable = true, kind = EndCause.Kind.NO_RESULT)
            }
            code == RATE_LIMIT_CLOSE_CODE || isRateLimit(reason) -> {
                note("服务限流：$code")
                end(RATE_LIMITED_ERROR, recoverable = true, kind = EndCause.Kind.RATE_LIMITED)
            }
            else -> {
                note("服务端关闭：$code")
                disconnected()
            }
        }
    }

    /** Records the short cause for [EndCause.detail]; the first one wins (later lines are consequences). */
    private fun note(detail: String) {
        if (cause.isEmpty()) cause = detail
    }

    private fun end(error: String?, notify: Boolean = true, recoverable: Boolean = false, kind: EndCause.Kind = EndCause.Kind.OTHER) {
        if (closed) return
        closed = true
        ready = false
        acceptingAudio = false
        deadline?.cancel(false)
        deadline = null
        socket?.cancel()
        socket = null
        if (notify) {
            val ended = EndCause(kind, cause.ifEmpty { if (error != null && recoverable) "连接断开" else "" })
            callbackExecutor.execute { listener.onEnd(error, recoverable, ended) }
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
                    note(if (status != null) "握手失败：HTTP $status" else "网络故障：" + t.javaClass.simpleName)
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
