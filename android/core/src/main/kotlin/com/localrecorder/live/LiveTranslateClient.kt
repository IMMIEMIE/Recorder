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

/**
 * One LiveTranslate session over the realtime WebSocket. Single use: create a new client per session.
 * All transport state lives on one serial executor; audio producers only enqueue bounded data.
 * Callbacks are delivered on [callbackExecutor] (the main thread in the app).
 */
class LiveTranslateClient(
    private val listener: Listener,
    private val callbackExecutor: Executor,
    private val finishTimeoutMs: Long = 30_000,
    private val allowLocalhost: Boolean = false,
    private val httpClient: OkHttpClient = sharedHttpClient,
) {
    interface Listener {
        fun onReady()
        fun onEvent(event: JSONObject)
        fun onEnd(error: String?)
    }

    companion object {
        /** Raw PCM bytes allowed to wait in the outgoing queue (~10 s of 16 kHz PCM16). */
        const val MAX_QUEUED_AUDIO_BYTES = 320_000

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
    private var socket: WebSocket? = null
    private var configuration: LiveTranslateConfig? = null
    private var ready = false
    private var finishing = false
    private var closed = false
    private var configured = false
    private var started = false
    private var httpStatus: Int? = null
    private var deadline: ScheduledFuture<*>? = null

    @Volatile private var acceptingAudio = false

    fun connect(configuration: LiveTranslateConfig, key: String) {
        if (key.isEmpty()) throw LiveTranslateException("请在 LiveTranslate 设置中保存专用 API Key")
        val url = configuration.url(allowLocalhost)
        val request = Request.Builder().url(url).header("Authorization", "Bearer $key").build()
        runSync {
            check(!started) { "LiveTranslateClient is single use" }
            started = true
            this.configuration = configuration
            socket = httpClient.newWebSocket(request, SocketListener())
            armTimeout(20_000, "LiveTranslate 连接或会话配置超时，请检查网络和服务地址")
        }
    }

    /** Queues 16 kHz mono PCM16; returns false when not ready, finishing, or the queue is full. */
    fun append(pcm: ByteArray): Boolean {
        if (!acceptingAudio) return false
        return runSync {
            val socket = socket
            if (!ready || finishing || closed || socket == null) return@runSync false
            // OkHttp's queue holds base64 JSON; convert back to an estimate of raw PCM bytes.
            if (socket.queueSize() * 3 / 4 + pcm.size > MAX_QUEUED_AUDIO_BYTES) return@runSync false
            send(JSONObject().put("type", "input_audio_buffer.append").put("audio", Base64.getEncoder().encodeToString(pcm)))
        } ?: false
    }

    /** Asks the server to drain the tail; [Listener.onEnd] follows `session.finished` or a timeout. */
    fun finish() {
        post {
            if (!ready || closed || finishing) return@post
            finishing = true
            acceptingAudio = false
            armTimeout(finishTimeoutMs, "LiveTranslate 尾句处理超时，已保留收到的文字，末句可能不完整")
            send(JSONObject().put("type", "session.finish"))
        }
    }

    /** Closes immediately without a callback. */
    fun cancel() {
        runSync { end(null, notify = false) }
    }

    private fun armTimeout(ms: Long, message: String) {
        deadline?.cancel(false)
        deadline = try {
            queue.schedule({ end(message) }, ms, TimeUnit.MILLISECONDS)
        } catch (_: RejectedExecutionException) {
            null
        }
    }

    private fun send(event: JSONObject): Boolean {
        event.put("event_id", UUID.randomUUID().toString())
        // OkHttp keeps send order, so session.finish always follows the queued audio.
        if (socket?.send(event.toString()) != true) {
            end(connectionError())
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
                end(if (finishing) null else "LiveTranslate 会话意外结束，已保留收到的文字"); return
            }
            "error", "conversation.item.input_audio_transcription.failed" -> {
                end(serviceError(event.optJSONObject("error")?.optStringOrNull("code") ?: "")); return
            }
            "response.done" -> {
                if (event.optJSONObject("response")?.optStringOrNull("status") != "completed") {
                    end("LiveTranslate 译文未完成，已保留收到的文字"); return
                }
            }
        }
        callbackExecutor.execute { listener.onEvent(event) }
    }

    private fun connectionError(): String = when (httpStatus) {
        401, 403 -> "LiveTranslate API Key 无效或无权访问，请核对密钥、区域和工作空间"
        429 -> "LiveTranslate 请求受限或额度不足，请稍后重试"
        else -> "LiveTranslate 连接中断或无法连接，请检查网络、服务地址及 API Key；已有文字已保留"
    }

    private fun end(error: String?, notify: Boolean = true) {
        if (closed) return
        closed = true
        ready = false
        acceptingAudio = false
        deadline?.cancel(false)
        deadline = null
        socket?.cancel()
        socket = null
        if (notify) callbackExecutor.execute { listener.onEnd(error) }
        queue.shutdown()
    }

    private inner class SocketListener : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) = post { handle(text) }
        override fun onMessage(webSocket: WebSocket, bytes: ByteString) = post { handle(bytes.utf8()) }
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) = post { end(connectionError()) }
        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = post { end(connectionError()) }
        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            val status = response?.code
            response?.close()
            post {
                httpStatus = status
                end(connectionError())
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
