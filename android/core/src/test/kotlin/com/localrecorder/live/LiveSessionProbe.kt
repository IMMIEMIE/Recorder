package com.localrecorder.live

import org.json.JSONArray
import org.json.JSONObject
import java.util.IdentityHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * `LiveProbe --session`: the WAV goes through the app's own [LiveSession] (catch-up limit, load shedding,
 * reconnects, rate-limit waits) with a plain JVM [SessionPlatform]: one scheduler thread is the session thread,
 * capture starts at `start()` like the microphone and is paced at 100 ms chunks, and the transports are real
 * [LiveTranslateClient]s. Reports what the app would have done (connections, dropped audio, markers, statuses)
 * and the server's latency per utterance, measured from the moment the speech was captured.
 *
 * [holdReadyMs] delays the first connection's readiness, so that much speech waits in the session's buffer
 * like after a reconnect (`PROBE_BURST_MS` in the script).
 */
internal class LiveSessionProbe(
    private val config: LiveTranslateConfig,
    private val key: String,
    pcm: ByteArray,
    private val label: String,
    private val allowLocalhost: Boolean,
    private val holdReadyMs: Long = 0,
) : SessionPlatform {
    private val started = System.nanoTime()
    private fun now(): Long = (System.nanoTime() - started) / 1_000_000

    private val chunk = BYTES_PER_MS * 100
    private val audioSeconds = pcm.size / (BYTES_PER_MS * 1000.0)
    private val stream = pcm + ByteArray(BYTES_PER_MS * 3000).also(::roomTone)

    private val thread = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "probe-session").apply { isDaemon = true } }
    private val microphone = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "probe-microphone").apply { isDaemon = true } }
    private val ended = CountDownLatch(1)

    /** One connection: what was sent on it (to map the server's audio offsets back to capture time) and its events. */
    private inner class Link(val index: Int, val openedAt: Long) {
        var client: LiveTranslateClient? = null
        var readyAt = -1L
        var endAt = -1L
        var endError: String? = null
        var endRecoverable = false
        var cause = EndCause()
        var sentBytes = 0L

        /** (offset in this connection's audio, capture time of that chunk), in send order. */
        val spans = ArrayList<LongArray>()
        val speechStart = HashMap<String, Int>()
        val speechEnd = HashMap<String, Int>()
        val firstSourceDelta = HashMap<String, Long>()
        val sourceDone = HashMap<String, Long>()
        val outputSource = HashMap<String, String>()
        val firstOutputDelta = HashMap<String, Long>()
        val outputDone = HashMap<String, Long>()

        /** Capture time of the speech at [ms] in this connection's audio; null before any was sent. */
        fun captured(ms: Int): Long? {
            val bytes = ms.toLong() * BYTES_PER_MS
            val span = spans.lastOrNull { it[0] <= bytes } ?: return null
            if (span[1] < 0) return null
            return span[1] + (bytes - span[0]) / BYTES_PER_MS
        }
    }

    // Guarded by lock.
    private val lock = Any()
    private val links = ArrayList<Link>()
    private val captureTimes = IdentityHashMap<ByteArray, Long>()
    private var capturedBytes = 0L
    private var sentBytes = 0L
    private var full = 0
    private var maxQueue = 0
    private var captureEndedAt = -1L
    private val diagnostics = mutableListOf<String>()
    private val statuses = mutableListOf<String>()
    private var last = SessionSnapshot()
    private var sawActive = false

    private var capture: ScheduledFuture<*>? = null
    private var nextChunk = 0

    val session = LiveSession(this) { snapshot -> changed(snapshot) }

    fun run(): JSONObject {
        println("[$label] session mode: ${"%.1f".format(audioSeconds)} s of speech + 3 s room tone → ${config.language}" +
            (if (holdReadyMs > 0) "; first connection held back ${holdReadyMs} ms after it is ready" else ""))
        thread.execute {
            session.start(config, key)
            if (session.snapshot.state == SessionState.IDLE) ended.countDown()
        }
        val reporter = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "probe-report").apply { isDaemon = true } }
        reporter.scheduleAtFixedRate({ report() }, 1, 1, TimeUnit.SECONDS)
        val finished = ended.await(stream.size / (chunk * 10L) + holdReadyMs / 1000 + 180, TimeUnit.SECONDS)
        reporter.shutdownNow()
        if (!finished) thread.submit { session.stop() }.get(5, TimeUnit.SECONDS)
        return summary(finished)
    }

    // SessionPlatform

    override fun post(block: () -> Unit) = thread.execute(block)

    override fun schedule(delayMs: Long, block: () -> Unit): Cancellable {
        val future = thread.schedule(block, delayMs, TimeUnit.MILLISECONDS)
        return Cancellable { future.cancel(false) }
    }

    override fun transport(listener: LiveTranslateClient.Listener): LiveTransport {
        val link = synchronized(lock) { Link(links.size, now()).also(links::add) }
        val client = LiveTranslateClient(Tap(link, listener), thread, allowLocalhost = allowLocalhost, diagnostic = { line ->
            synchronized(lock) { diagnostics += "${now()} ms #${link.index} $line" }
            println("  ! ${now()} ms connection #${link.index}: $line")
        })
        link.client = client
        return Counted(link, client)
    }

    override fun startCapture(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit) {
        capture = microphone.scheduleAtFixedRate({
            val offset = nextChunk * chunk
            if (offset >= stream.size) {
                capture?.cancel(false)
                synchronized(lock) { captureEndedAt = now() }
                thread.execute { session.stop() }
                return@scheduleAtFixedRate
            }
            nextChunk++
            val pcm = stream.copyOfRange(offset, minOf(stream.size, offset + chunk))
            synchronized(lock) {
                captureTimes[pcm] = now()
                capturedBytes += pcm.size
            }
            onChunk(pcm)
        }, 0, 100, TimeUnit.MILLISECONDS)
    }

    override fun stopCapture() {
        capture?.cancel(false)
        // Waits for a chunk being delivered right now (the microphone thread is serial).
        microphone.submit {}.get()
    }

    override fun speech(): SpeechOutput = object : SpeechOutput {
        override fun start(volume: Float) = Unit
        override fun append(pcm: ByteArray) = true
        override fun finish(done: () -> Unit) = done()
        override fun stop() = Unit
    }

    override fun sessionActive(active: Boolean) = Unit

    /** Counts what the session actually sends on each connection. */
    private inner class Counted(private val link: Link, private val client: LiveTranslateClient) : LiveTransport by client {
        override fun append(pcm: ByteArray): AppendResult {
            val result = client.append(pcm)
            synchronized(lock) {
                when (result) {
                    AppendResult.SENT -> {
                        link.spans += longArrayOf(link.sentBytes, captureTimes[pcm] ?: -1)
                        link.sentBytes += pcm.size
                        sentBytes += pcm.size
                        maxQueue = maxOf(maxQueue, client.queuedAudioBytes)
                    }
                    AppendResult.FULL -> full++
                    AppendResult.CLOSED -> Unit
                }
            }
            return result
        }
    }

    /** Records each connection's events and forwards them to the session (on the session thread). */
    private inner class Tap(private val link: Link, private val session: LiveTranslateClient.Listener) : LiveTranslateClient.Listener {
        override fun onReady() {
            synchronized(lock) { link.readyAt = now() }
            if (link.index == 0 && holdReadyMs > 0) {
                println("  ${now()} ms connection #0 ready; holding it back ${holdReadyMs} ms")
                thread.schedule({ session.onReady() }, holdReadyMs, TimeUnit.MILLISECONDS)
            } else {
                session.onReady()
            }
        }

        override fun onEvent(event: JSONObject) {
            val at = now()
            val item = event.optString("item_id")
            synchronized(lock) {
                when (event.optString("type")) {
                    "input_audio_buffer.speech_started" -> link.speechStart[item] = event.optInt("audio_start_ms", -1)
                    "input_audio_buffer.speech_stopped" -> link.speechEnd[item] = event.optInt("audio_end_ms", -1)
                    "conversation.item.input_audio_transcription.delta" -> link.firstSourceDelta.putIfAbsent(item, at)
                    "conversation.item.input_audio_transcription.completed" -> link.sourceDone.putIfAbsent(item, at)
                    "conversation.item.created" -> {
                        val output = event.optJSONObject("item")
                        val source = event.optString("previous_item_id")
                        if (output?.optString("role") == "assistant" && source.isNotEmpty()) link.outputSource[output.optString("id")] = source
                    }
                    "response.text.delta", "response.audio_transcript.delta" -> link.firstOutputDelta.putIfAbsent(item, at)
                    "response.text.done", "response.audio_transcript.done" -> link.outputDone.putIfAbsent(item, at)
                }
            }
            session.onEvent(event)
        }

        override fun onEnd(error: String?, recoverable: Boolean, cause: EndCause) {
            synchronized(lock) {
                link.endAt = now()
                link.endError = error
                link.endRecoverable = recoverable
                link.cause = cause
            }
            println("  ${now()} ms connection #${link.index} ended: ${error ?: "normal"}${if (cause.detail.isNotEmpty()) " (${cause.kind}: ${cause.detail})" else ""}")
            session.onEnd(error, recoverable, cause)
        }
    }

    /** Session thread. */
    private fun changed(snapshot: SessionSnapshot) {
        val previous = synchronized(lock) {
            val before = last
            last = snapshot
            if (snapshot.status.isNotEmpty() && statuses.lastOrNull() != snapshot.status) statuses += snapshot.status
            before
        }
        if (snapshot.state != previous.state || snapshot.status != previous.status || snapshot.slowNetwork != previous.slowNetwork) {
            println("  ${now()} ms ${snapshot.state}${if (snapshot.slowNetwork) " (网络较慢)" else ""}: ${snapshot.status}")
        }
        if (snapshot.notice.isNotEmpty() && snapshot.notice != previous.notice) println("  ${now()} ms notice: ${snapshot.notice}")
        snapshot.rows.filter { it.marker.isNotEmpty() && previous.rows.none { old -> old.key == it.key } }
            .forEach { println("  ${now()} ms marker: ${it.marker}") }
        if (snapshot.state != SessionState.IDLE) sawActive = true
        if (sawActive && snapshot.state == SessionState.IDLE) ended.countDown()
    }

    private fun report() {
        val line = synchronized(lock) {
            val current = links.lastOrNull()?.client
            // The backlog only matters while audio is still being sent; after stop it is just the tail draining.
            val queue = if (captureEndedAt >= 0 || current == null) "sending done  " else "queue ${"%5d".format(current.queuedAudioBytes / BYTES_PER_MS)} ms"
            "  ${"%6.1f".format(now() / 1000.0)} s  captured ${"%5.1f".format(capturedBytes / (BYTES_PER_MS * 1000.0))} s" +
                "  sent ${"%5.1f".format(sentBytes / (BYTES_PER_MS * 1000.0))} s  $queue  ${last.state}"
        }
        println(line)
    }

    private fun summary(finished: Boolean): JSONObject = synchronized(lock) {
        val partialLag = ArrayList<Long>()
        val finalLag = ArrayList<Long>()
        val firstTranslationLag = ArrayList<Long>()
        val translationLag = ArrayList<Long>()
        var utterances = 0
        for (link in links) {
            utterances += link.sourceDone.size
            link.firstSourceDelta.forEach { (item, at) -> link.speechStart[item]?.takeIf { it >= 0 }?.let(link::captured)?.let { partialLag += at - it } }
            link.sourceDone.forEach { (item, at) -> link.speechEnd[item]?.takeIf { it >= 0 }?.let(link::captured)?.let { finalLag += at - it } }
            link.firstOutputDelta.forEach { (output, at) ->
                link.outputSource[output]?.let { link.speechStart[it] }?.takeIf { it >= 0 }?.let(link::captured)?.let { firstTranslationLag += at - it }
            }
            link.outputDone.forEach { (output, at) ->
                link.outputSource[output]?.let { link.speechEnd[it] }?.takeIf { it >= 0 }?.let(link::captured)?.let { translationLag += at - it }
            }
        }
        val markers = last.rows.filter { it.marker.isNotEmpty() }.map { it.marker }
        val first = links.firstOrNull()
        val droppedSeconds = (capturedBytes - sentBytes) / (BYTES_PER_MS * 1000.0)
        val json = JSONObject()
            .put("label", label)
            .put("mode", "session")
            .put("language", config.language)
            .put("speech_output", config.audioOutput)
            .put("audio_seconds", audioSeconds)
            .put("hold_ready_ms", holdReadyMs)
            .put("handshake_ms", if (first != null && first.readyAt >= 0) first.readyAt - first.openedAt else JSONObject.NULL)
            .put("connections", links.size)
            .put("reconnects", (links.size - 1).coerceAtLeast(0))
            .put("captured_seconds", capturedBytes / (BYTES_PER_MS * 1000.0))
            .put("sent_seconds", sentBytes / (BYTES_PER_MS * 1000.0))
            .put("dropped_seconds", droppedSeconds)
            .put("max_queue_seconds", maxQueue / (BYTES_PER_MS * 1000.0))
            .put("append_full", full)
            .put("markers", JSONArray(markers))
            .put("statuses", JSONArray(statuses))
            .put("session_ended", finished)
            .put("session_error", last.error)
            .put("connection_ends", JSONArray(links.map { link ->
                JSONObject()
                    .put("opened_ms", link.openedAt)
                    .put("ready_ms", link.readyAt)
                    .put("end_ms", link.endAt)
                    .put("error", link.endError ?: JSONObject.NULL)
                    .put("recoverable", link.endRecoverable)
                    .put("cause", "${link.cause.kind} ${link.cause.detail}".trim())
                    .put("sent_seconds", link.sentBytes / (BYTES_PER_MS * 1000.0))
            }))
            .put("transport_diagnostics", JSONArray(diagnostics))
            .put("utterances", utterances)
            .put("rows", last.rows.count { it.marker.isEmpty() })
            .put("first_partial_after_speech_start_ms", stats(partialLag))
            .put("source_final_after_speech_end_ms", stats(finalLag))
            .put("first_translation_after_speech_start_ms", stats(firstTranslationLag))
            .put("translation_done_after_speech_end_ms", stats(translationLag))
        println("[$label] session summary")
        println("  handshake ${json.opt("handshake_ms")} ms; connections ${links.size} (reconnects ${json.getInt("reconnects")}); $utterances utterances, ${json.getInt("rows")} rows")
        println("  captured ${"%.1f".format(json.getDouble("captured_seconds"))} s, sent ${"%.1f".format(json.getDouble("sent_seconds"))} s, not sent ${"%.1f".format(droppedSeconds)} s (catch-up limit and shedding); uplink backlog max ${"%.1f".format(json.getDouble("max_queue_seconds"))} s; FULL: $full")
        println("  markers: ${if (markers.isEmpty()) "none" else markers.joinToString("; ")}")
        println("  latency is measured from when the speech was captured:")
        println("  first source text after speech start: ${describe(partialLag)}")
        println("  source final after speech end:        ${describe(finalLag)}")
        println("  first translation after speech start: ${describe(firstTranslationLag)}")
        println("  translation done after speech end:    ${describe(translationLag)}")
        println("  end: ${if (!finished) "the session did not end within the wait" else last.error.ifEmpty { "normal" }}")
        links.filter { it.endError != null }.forEach { link ->
            println("  connection #${link.index}: ${link.endError ?: "normal"} (${link.cause.kind}: ${link.cause.detail.ifEmpty { "—" }})")
        }
        diagnostics.forEach { println("  transport: $it") }
        json
    }
}
