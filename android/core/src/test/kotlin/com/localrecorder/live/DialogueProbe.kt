package com.localrecorder.live

import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Base64
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Wire probe for Qwen 3.8. Takes two connections, never reconnects. Only use with a public test utterance. */
internal class DialogueProbe(
    private val config: LiveTranslateConfig,
    private val key: String,
    private val localhost: Boolean = false,
    private val timeoutMs: Long = 10_000,
) {
    private inner class Lane(val language: String) : WebSocketListener(), AutoCloseable {
        val starts = JSONArray()
        private var queuedBytes = 0L
        val queuedAudioMs get() = queuedBytes / BYTES_PER_MS
        private val sourceByOutput = mutableMapOf<String, String>()
        private val finalByOutput = linkedMapOf<String, String>()
        private var terminal: JSONObject? = null
        val events = LinkedBlockingQueue<JSONObject>()
        val socket: WebSocket = LiveTranslateClient.sharedHttpClient.newWebSocket(
            Request.Builder().url(config.copy(language = language).url(localhost)).header("Authorization", "Bearer $key").build(), this,
        )

        override fun onMessage(webSocket: WebSocket, text: String) {
            events.offer(runCatching { JSONObject(text) }.getOrElse { JSONObject().put("type", "invalid_json") })
        }
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            val cause = when {
                LiveTranslateClient.isNoResult(reason) -> "no_result"
                code == 1007 || LiveTranslateClient.isRateLimit(reason) -> "rate_limited"
                else -> "closed"
            }
            events.offer(JSONObject().put("type", cause).put("close_code", code))
            webSocket.close(1000, null)
        }
        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            val type = if (response?.code == 429) "rate_limited" else "transport_failure"
            events.offer(JSONObject().put("type", type).put("http_status", response?.code))
        }
        override fun close() = socket.cancel()

        fun sendAudio(frame: String, bytes: Int): Boolean {
            if (!socket.send(frame)) return false
            queuedBytes += bytes
            return true
        }

        fun await(type: String, waitMs: Long = timeoutMs): JSONObject {
            terminal?.let { return it }
            val until = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(waitMs)
            while (true) {
                val event = events.poll(until - System.nanoTime(), TimeUnit.NANOSECONDS)
                    ?: return JSONObject().put("type", "timeout")
                val received = event.optString("type")
                if (received == "input_audio_buffer.speech_started") {
                    starts.put(JSONObject().put("item_id", event.opt("item_id"))
                        .put("audio_start_ms", event.opt("audio_start_ms")).put("speaker_id", event.opt("speaker_id")))
                }
                when (received) {
                    type -> return event
                    "closed", "rate_limited", "no_result", "invalid_json", "transport_failure" -> {
                        terminal = event
                        return event
                    }
                    "conversation.item.created" -> {
                        val item = event.optJSONObject("item")
                        val previous = event.optStringOrNull("previous_item_id")
                        if (item?.optString("role") == "assistant" && previous != null) {
                            item.optStringOrNull("id")?.let { sourceByOutput[it] = previous }
                        }
                    }
                    "response.text.done" -> event.optStringOrNull("item_id")?.let { finalByOutput[it] = event.optString("text") }
                    "session.finished" -> return JSONObject().put("type", "finished_early")
                    "error" -> {
                        val error = event.optJSONObject("error")
                        val detail = error?.toString().orEmpty()
                        val cause = when {
                            LiveTranslateClient.isNoResult(detail) -> "no_result"
                            LiveTranslateClient.isRateLimit(detail) -> "rate_limited"
                            else -> "server_error"
                        }
                        return JSONObject().put("type", cause)
                    }
                }
            }
        }

        fun configure(target: String, initial: Boolean): JSONObject {
            if (initial) {
                val created = await("session.created")
                if (created.optString("type") != "session.created") return created
            }
            val update = config.copy(language = target, audioOutput = false).sessionUpdate()
            update.getJSONObject("session").getJSONObject("audio").getJSONObject("input")
                .put("turn_detection", JSONObject().put("type", "speaker_detection"))
            // A peer can close during playback. Its listener has the classified reason even
            // when this send is rejected before the probe gets around to reading the queue.
            val sent = socket.send(update.toString())
            val ack = await("session.updated")
            if (ack.optString("type") != "session.updated") return ack
            if (!sent) return JSONObject().put("type", "closed")
            val session = ack.optJSONObject("session")
            val actual = session?.optJSONObject("translation")?.optString("language")
            val textOnly = session?.optJSONArray("output_modalities")?.let { it.length() == 1 && it.optString(0) == "text" } == true
            return JSONObject().put("type", if (actual == target && textOnly) "confirmed" else "mismatch")
                .put("ack_language", actual)
        }

        fun result(): JSONObject {
            val finals = JSONArray()
            for ((output, text) in finalByOutput) {
                finals.put(JSONObject().put("item_id", sourceByOutput[output]).put("output_id", output).put("translation", text))
            }
            return JSONObject().put("starts", starts).put("final_translations", finals).put("queued_audio_ms", queuedAudioMs)
        }
    }

    fun run(pcm: ByteArray, peer: String, next: String, pace: Boolean = true): JSONObject {
        require(config.language != next && config.language != peer && next != peer)
        require(listOf(peer, next).all { lang -> LiveTranslateConfig.LANGUAGES.any { it.first == lang } })
        require(pcm.isNotEmpty() && pcm.size % 2 == 0)
        val report = JSONObject().put("language_A", config.language).put("language_B", peer).put("requested_A", next)
        Lane(config.language).use { a ->
            Lane(peer).use { b ->
                val aReady = a.configure(config.language, initial = true)
                val bReady = b.configure(peer, initial = true)
                report.put("initial_A", aReady).put("initial_B", bReady)
                if (listOf(aReady, bReady).any { it.optString("type") != "confirmed" }) return report
                val stream = pcm + ByteArray(32_000 * 2) // Give the first sentence a silence boundary before changing target.
                fun play() {
                    var offset = 0
                    while (offset < stream.size) {
                        val end = minOf(offset + 3200, stream.size)
                        val frame = JSONObject().put("type", "input_audio_buffer.append")
                            .put("audio", Base64.getEncoder().encodeToString(stream.copyOfRange(offset, end))).toString()
                        val sentA = a.sendAudio(frame, end - offset)
                        val sentB = b.sendAudio(frame, end - offset)
                        if (!sentA && !sentB) break
                        if (pace) Thread.sleep(((end - offset) / BYTES_PER_MS).toLong())
                        offset = end
                    }
                }
                play()
                val changed = a.configure(next, initial = false)
                report.put("update_A", changed).put("switch_audio_ms", a.queuedAudioMs)
                if (changed.optString("type") == "confirmed") play()
                for (lane in listOf(a, b)) lane.socket.send("""{"type":"session.finish"}""")
                report.put("end_A", a.await("session.finished")).put("end_B", b.await("session.finished"))
                report.put("A", a.result()).put("B", b.result())
            }
        }
        return report
    }
}

/** No real credential is needed for DialogueProbe's offline mock tests. This entry uses an explicitly supplied WAV and key. */
fun main(args: Array<String>) {
    require(args.size == 1) { "Pass a short public 16 kHz mono PCM16 test WAV as the sole argument" }
    val key = System.getenv("LIVETRANSLATE_API_KEY").orEmpty()
    require(key.isNotBlank()) { "Set LIVETRANSLATE_API_KEY for the selected test endpoint" }
    val config = LiveTranslateConfig(
        endpoint = System.getenv("LIVETRANSLATE_ENDPOINT") ?: LiveTranslateConfig.DEFAULT_ENDPOINT,
        language = System.getenv("PROBE_TARGET") ?: "en",
    )
    val report = DialogueProbe(config, key).run(readWav(File(args.single())),
        peer = System.getenv("PROBE_PEER") ?: "zh", next = System.getenv("PROBE_NEXT") ?: "ja")
    println(report.toString(2))
}
