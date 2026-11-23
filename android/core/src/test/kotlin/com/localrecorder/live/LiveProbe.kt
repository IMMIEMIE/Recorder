package com.localrecorder.live

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.random.Random

/**
 * Real-API timing probe. Streams a 16 kHz mono PCM16 WAV through the app's own [LiveTranslateClient] at
 * real-time pace (100 ms chunks, like `MicrophoneSource`) and reports the uplink backlog the app would see,
 * the server's latency per utterance, and the exact transport cause of any disconnect.
 *
 * Run it through `scripts/probe_livetranslate.sh`. The key comes from `LIVETRANSLATE_API_KEY` and is never
 * printed or written. Arguments: `--audio=<wav> [--language=en] [--endpoint=wss://…] [--speech=on]
 * [--label=…] [--json=<summary.json>] [--burst-ms=N] [--session]`.
 *
 * `--session` runs the WAV through the app's [LiveSession] instead (see [LiveSessionProbe]): its catch-up limit,
 * load shedding and reconnects, as on the phone. There `--burst-ms=N` holds the first connection's readiness back
 * by N ms, so N ms of speech waits in the session's buffer like after a reconnect.
 */
fun main(args: Array<String>) {
    val options = args.associate { it.removePrefix("--").substringBefore('=') to it.substringAfter('=', "") }
    val audio = File(options["audio"] ?: error("--audio=<16 kHz mono PCM16 WAV> is required"))
    val key = System.getenv("LIVETRANSLATE_API_KEY").orEmpty()
    // Only for checking the probe itself against tests/mock_livetranslate_server.py.
    val allowLocalhost = options["allow-localhost"] == "on"
    require(key.isNotBlank()) { "LIVETRANSLATE_API_KEY is not set" }
    val config = LiveTranslateConfig(
        endpoint = options["endpoint"]?.takeIf { it.isNotBlank() } ?: LiveTranslateConfig.DEFAULT_ENDPOINT,
        language = options["language"]?.takeIf { it.isNotBlank() } ?: "en",
        audioOutput = options["speech"] == "on",
    ).normalized(allowLocalhost)
    val burstMs = options["burst-ms"]?.toIntOrNull() ?: 0
    val label = options["label"] ?: audio.name
    val result = if ("session" in options) {
        LiveSessionProbe(config, key, readWav(audio), label, allowLocalhost, holdReadyMs = burstMs.toLong()).run()
    } else {
        LiveProbe(config, key, readWav(audio), label, allowLocalhost, burstMs).run()
    }
    options["json"]?.takeIf { it.isNotBlank() }?.let { File(it).writeText(result.toString(2)) }
}

private class LiveProbe(
    private val config: LiveTranslateConfig,
    private val key: String,
    private val pcm: ByteArray,
    private val label: String,
    private val allowLocalhost: Boolean,
    /** Sends this much audio at once when the session is ready (like the app's connect/reconnect buffer), then real time. */
    private val burstMs: Int = 0,
) {
    private val started = System.nanoTime()
    private fun now(): Long = (System.nanoTime() - started) / 1_000_000

    private val lock = Any()
    private val callbacks = Executors.newSingleThreadExecutor { r -> Thread(r, "probe-callbacks").apply { isDaemon = true } }
    private val sender = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "probe-microphone").apply { isDaemon = true } }
    private val ready = CountDownLatch(1)
    private val ended = CountDownLatch(1)

    // Guarded by lock.
    private var readyAt = -1L
    private var audioStart = -1L
    private var chunksSent = 0
    private var full = 0
    private var closed = 0
    private var maxQueue = 0
    private var slowChunks = 0
    private var maxLateness = 0L
    private var finishSentAt = -1L
    private var endAt = -1L
    private var endError: String? = null
    private var endRecoverable = false
    private var endCause = ""
    private val diagnostics = mutableListOf<String>()
    private val types = sortedMapOf<String, Int>()
    private var downlinkChars = 0L
    private var speechBytes = 0L
    private var windowEvents = 0
    private var windowChars = 0L
    private val speechStart = HashMap<String, Int>()
    private val speechEnd = HashMap<String, Int>()
    private val firstSourceDelta = HashMap<String, Long>()
    private val sourceDone = HashMap<String, Long>()
    private val sourceText = HashMap<String, String>()
    private val outputSource = HashMap<String, String>()
    private val firstOutputDelta = HashMap<String, Long>()
    private val outputDone = HashMap<String, Long>()

    private val tail = ByteArray(LiveTranslateConfig.INPUT_SAMPLE_RATE * 2 * 3).also(::roomTone)
    private val stream = pcm + tail
    private val chunk = LiveTranslateConfig.INPUT_SAMPLE_RATE * 2 / 10

    fun run(): JSONObject {
        val audioSeconds = pcm.size / (LiveTranslateConfig.INPUT_SAMPLE_RATE * 2.0)
        println("[$label] ${"%.1f".format(audioSeconds)} s of speech + 3 s room tone → ${config.language}, speech output ${if (config.audioOutput) "on" else "off"}")
        val client = LiveTranslateClient(Listener(), callbacks, allowLocalhost = allowLocalhost, diagnostic = { line ->
            synchronized(lock) { diagnostics += "${now()} ms $line" }
            println("  ! ${now()} ms transport: $line")
        })
        val connectAt = now()
        client.connect(config, key)
        if (!ready.await(25, TimeUnit.SECONDS) || synchronized(lock) { endAt >= 0 }) {
            ended.await(5, TimeUnit.SECONDS)
            return summary(connectAt, audioSeconds)
        }
        synchronized(lock) { audioStart = now() - burstMs }
        if (burstMs > 0) println("  sending ${burstMs} ms of audio at once, then real time")
        repeat(burstMs / 100) { sendNext(client) }
        sender.scheduleAtFixedRate({ sendNext(client) }, 100, 100, TimeUnit.MILLISECONDS)
        val reporter = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "probe-report").apply { isDaemon = true } }
        reporter.scheduleAtFixedRate({ report(client) }, 1, 1, TimeUnit.SECONDS)
        ended.await((stream.size / (chunk * 10L)) + 90, TimeUnit.SECONDS)
        reporter.shutdownNow()
        sender.shutdownNow()
        client.cancel()
        return summary(connectAt, audioSeconds)
    }

    private fun sendNext(client: LiveTranslateClient) {
        val index: Int
        val due: Long
        synchronized(lock) {
            index = chunksSent
            due = audioStart + index * 100L
        }
        val offset = index * chunk
        if (offset >= stream.size) {
            synchronized(lock) { if (finishSentAt < 0) finishSentAt = now() else return }
            client.finish()
            return
        }
        val result = client.append(stream.copyOfRange(offset, minOf(stream.size, offset + chunk)))
        synchronized(lock) {
            chunksSent++
            maxLateness = maxOf(maxLateness, now() - due)
            val queued = client.queuedAudioBytes
            maxQueue = maxOf(maxQueue, queued)
            if (queued > LiveSession.SHED_AUDIO_BYTES) slowChunks++
            when (result) {
                AppendResult.FULL -> full++
                AppendResult.CLOSED -> closed++
                AppendResult.SENT -> Unit
            }
        }
    }

    private fun report(client: LiveTranslateClient) {
        val line = synchronized(lock) {
            val sent = chunksSent / 10.0
            // The backlog only matters while audio is still being sent; after session.finish it is just the tail draining.
            val queue = if (finishSentAt >= 0) "sending done  " else "queue ${"%5d".format(client.queuedAudioBytes / BYTES_PER_MS)} ms"
            val text = "  ${"%6.1f".format(now() / 1000.0)} s  audio sent ${"%5.1f".format(sent)} s  $queue" +
                "  events/s ${"%3d".format(windowEvents)}  down ${"%5.1f".format(windowChars / 1024.0)} KB/s"
            windowEvents = 0
            windowChars = 0
            text
        }
        println(line)
    }

    private inner class Listener : LiveTranslateClient.Listener {
        override fun onReady() {
            synchronized(lock) { readyAt = now() }
            ready.countDown()
        }

        override fun onEvent(event: JSONObject) {
            val at = now()
            val size = event.toString().length
            val type = event.optString("type")
            val item = event.optString("item_id")
            synchronized(lock) {
                types[type] = (types[type] ?: 0) + 1
                downlinkChars += size
                windowChars += size
                windowEvents++
                when (type) {
                    "input_audio_buffer.speech_started" -> speechStart[item] = event.optInt("audio_start_ms", -1)
                    "input_audio_buffer.speech_stopped" -> speechEnd[item] = event.optInt("audio_end_ms", -1)
                    "conversation.item.input_audio_transcription.delta" -> firstSourceDelta.putIfAbsent(item, at)
                    "conversation.item.input_audio_transcription.completed" -> {
                        sourceDone.putIfAbsent(item, at)
                        sourceText[item] = event.optString("transcript")
                    }
                    "conversation.item.created" -> {
                        val output = event.optJSONObject("item")
                        val source = event.optString("previous_item_id")
                        if (output?.optString("role") == "assistant" && source.isNotEmpty()) outputSource[output.optString("id")] = source
                    }
                    "response.text.delta", "response.audio_transcript.delta" -> firstOutputDelta.putIfAbsent(item, at)
                    "response.text.done", "response.audio_transcript.done" -> outputDone.putIfAbsent(item, at)
                    "response.audio.delta" -> speechBytes += event.optString("delta").length * 3L / 4
                }
            }
        }

        override fun onEnd(error: String?, recoverable: Boolean, cause: EndCause) {
            synchronized(lock) {
                endAt = now()
                endError = error
                endRecoverable = recoverable
                endCause = "${cause.kind} ${cause.detail}".trim()
            }
            ended.countDown()
        }
    }

    private fun summary(connectAt: Long, audioSeconds: Double): JSONObject = synchronized(lock) {
        // Wall time at which the audio at offset `ms` was handed to the client.
        fun wall(ms: Int) = audioStart + ms
        val finalLag = sourceDone.mapNotNull { (item, at) -> speechEnd[item]?.takeIf { it >= 0 }?.let { at - wall(it) } }
        val partialLag = firstSourceDelta.mapNotNull { (item, at) -> speechStart[item]?.takeIf { it >= 0 }?.let { at - wall(it) } }
        val translationLag = outputDone.mapNotNull { (output, at) ->
            outputSource[output]?.let { speechEnd[it] }?.takeIf { it >= 0 }?.let { at - wall(it) }
        }
        val firstTranslationLag = firstOutputDelta.mapNotNull { (output, at) ->
            outputSource[output]?.let { speechStart[it] }?.takeIf { it >= 0 }?.let { at - wall(it) }
        }
        val queueSeconds = maxQueue / (LiveTranslateConfig.INPUT_SAMPLE_RATE * 2.0)
        val endedEarly = endAt >= 0 && finishSentAt < 0
        val json = JSONObject()
            .put("label", label)
            .put("language", config.language)
            .put("speech_output", config.audioOutput)
            .put("audio_seconds", audioSeconds)
            .put("handshake_ms", if (readyAt >= 0) readyAt - connectAt else JSONObject.NULL)
            .put("chunks_sent", chunksSent)
            .put("max_send_lateness_ms", maxLateness)
            .put("max_queue_seconds", queueSeconds)
            .put("chunks_over_slow_threshold", slowChunks)
            .put("append_full", full)
            .put("append_closed", closed)
            .put("ended_before_audio_finished", endedEarly)
            .put("end_ms", endAt)
            .put("end_error", endError ?: JSONObject.NULL)
            .put("end_recoverable", endRecoverable)
            .put("end_cause", endCause)
            .put("tail_ms", if (finishSentAt >= 0 && endAt >= 0) endAt - finishSentAt else JSONObject.NULL)
            .put("transport_diagnostics", JSONArray(diagnostics))
            .put("utterances", sourceDone.size)
            .put("first_partial_after_speech_start_ms", stats(partialLag))
            .put("source_final_after_speech_end_ms", stats(finalLag))
            .put("first_translation_after_speech_start_ms", stats(firstTranslationLag))
            .put("translation_done_after_speech_end_ms", stats(translationLag))
            .put("downlink_kb", downlinkChars / 1024.0)
            .put("speech_audio_seconds", speechBytes / (LiveTranslateConfig.OUTPUT_SAMPLE_RATE * 2.0))
            .put("event_counts", JSONObject(types as Map<*, *>))
        println("[$label] summary")
        println("  handshake ${json.opt("handshake_ms")} ms; ${sourceDone.size} utterances; downlink ${"%.0f".format(downlinkChars / 1024.0)} KB")
        println("  uplink backlog max ${"%.1f".format(queueSeconds)} s (the app drops audio above 1.5 s until it is below 0.3 s); chunks over 1.5 s: $slowChunks; FULL: $full; CLOSED: $closed; sender late max ${maxLateness} ms")
        println("  first source text after speech start: ${describe(partialLag)}")
        println("  source final after speech end:        ${describe(finalLag)}")
        println("  first translation after speech start: ${describe(firstTranslationLag)}")
        println("  translation done after speech end:    ${describe(translationLag)}")
        println("  end: ${if (endAt < 0) "no end within the wait" else (endError ?: "normal (session.finished)")}${if (endedEarly) " — BEFORE the audio was fully sent" else ""}")
        diagnostics.forEach { println("  transport: $it") }
        json
    }
}

internal const val BYTES_PER_MS = LiveTranslateConfig.INPUT_SAMPLE_RATE * 2 / 1000

internal fun stats(values: List<Long>): JSONObject {
    if (values.isEmpty()) return JSONObject().put("n", 0)
    val sorted = values.sorted()
    fun pct(p: Double) = sorted[((sorted.size - 1) * p).toInt()]
    return JSONObject().put("n", sorted.size).put("p50", pct(0.5)).put("p90", pct(0.9)).put("max", sorted.last())
}

internal fun describe(values: List<Long>): String {
    if (values.isEmpty()) return "n/a"
    val sorted = values.sorted()
    return "p50 ${sorted[(sorted.size - 1) / 2]} ms, p90 ${sorted[((sorted.size - 1) * 0.9).toInt()]} ms, max ${sorted.last()} ms (n=${sorted.size})"
}

/** Low-level noise instead of digital zero: a real microphone never delivers exact silence. */
internal fun roomTone(buffer: ByteArray) {
    val random = Random(7)
    for (i in buffer.indices step 2) {
        val sample = random.nextInt(-24, 25)
        buffer[i] = (sample and 0xFF).toByte()
        buffer[i + 1] = (sample shr 8).toByte()
    }
}

/** The data chunk of a 16 kHz mono PCM16 WAV (any other chunks are skipped). */
private fun readWav(file: File): ByteArray {
    val bytes = file.readBytes()
    val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
    require(bytes.size > 12 && String(bytes, 0, 4) == "RIFF" && String(bytes, 8, 4) == "WAVE") { "${file.name} is not a WAV file" }
    var position = 12
    var format = false
    while (position + 8 <= bytes.size) {
        val id = String(bytes, position, 4)
        val size = buffer.getInt(position + 4)
        val body = position + 8
        when (id) {
            "fmt " -> {
                val encoding = buffer.getShort(body).toInt()
                val channels = buffer.getShort(body + 2).toInt()
                val rate = buffer.getInt(body + 4)
                val bits = buffer.getShort(body + 14).toInt()
                require(encoding == 1 && channels == 1 && rate == 16_000 && bits == 16) {
                    "${file.name}: need 16 kHz mono PCM16, got encoding=$encoding channels=$channels rate=$rate bits=$bits"
                }
                format = true
            }
            "data" -> {
                require(format) { "${file.name}: data before fmt" }
                return bytes.copyOfRange(body, minOf(bytes.size, body + size)).let { if (it.size % 2 == 1) it.copyOf(it.size - 1) else it }
            }
        }
        position = body + size + (size and 1)
    }
    error("${file.name}: no data chunk")
}
