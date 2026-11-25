package com.localrecorder.live

import java.io.ByteArrayOutputStream

/** At most 30 s of 24 kHz PCM16 waits for playback. */
const val MAX_PENDING_SPEECH_BYTES = LiveTranslateConfig.OUTPUT_SAMPLE_RATE * 2 * 30

/** Reassembles PCM16 samples across websocket messages; duplicate events never replay sound. */
class LiveTranslateAudioDecoder {
    private val seen = RecentIds()
    private val completed = HashSet<String>()
    private val tails = HashMap<String, Byte>()

    val hasIncompleteSample: Boolean get() = tails.isNotEmpty()

    /** Returns whole little-endian PCM16 samples, or null when the event carries none. */
    fun consume(event: LiveSessionEvent): ByteArray? {
        if (event !is LiveSessionEvent.Audio) return null
        if (event.eventID?.let { !seen.add(it) } == true) return null
        val item = event.item ?: throw LiveTranslateException(LiveMessage.AudioMissingItemId)
        if (item in completed) return null
        if (event.final) {
            completed.add(item)
            if (tails.remove(item) != null) throw LiveTranslateException(LiveMessage.AudioIncomplete)
            return null
        }
        val chunk = event.samples ?: throw LiveTranslateException(LiveMessage.AudioInvalidFormat)
        val out = ByteArrayOutputStream(chunk.size + 1)
        tails.remove(item)?.let { out.write(it.toInt()) }
        out.write(chunk)
        var data = out.toByteArray()
        if (data.size % 2 == 1) {
            tails[item] = data.last()
            data = data.copyOf(data.size - 1)
        }
        return if (data.isEmpty()) null else data
    }
}

/**
 * Delayed mode releases whole utterances only after source, translation and audio are final,
 * using the server's source/output associations, including when those arrive after the audio.
 */
class LiveTranslatePlaybackQueue(val timing: PlaybackTiming) {
    private val decoder = LiveTranslateAudioDecoder()
    private val buffers = HashMap<String, ByteArrayOutputStream>()
    private val audioDone = HashSet<String>()
    private val released = HashSet<String>()
    private var bufferedBytes = 0

    val hasPendingAudio: Boolean get() = bufferedBytes > 0
    val hasIncompleteSample: Boolean get() = decoder.hasIncompleteSample

    fun consume(event: LiveSessionEvent, transcripts: LiveTranslateEvents): List<ByteArray> {
        val pcm = decoder.consume(event)
        if (timing == PlaybackTiming.STREAMING) return listOfNotNull(pcm)
        (event as? LiveSessionEvent.Audio)?.item?.let { id ->
            if (pcm != null && id !in released) {
                if (bufferedBytes + pcm.size > MAX_PENDING_SPEECH_BYTES) {
                    throw LiveTranslateException(LiveMessage.AudioPendingTimeout)
                }
                buffers.getOrPut(id) { ByteArrayOutputStream() }.write(pcm)
                bufferedBytes += pcm.size
            }
            if (event.final) audioDone.add(id)
        }
        val ready = mutableListOf<ByteArray>()
        for (source in transcripts.order) {
            val row = transcripts.rows[source] ?: continue
            val waiting = row.outputs.filter { it !in released }
            if (row.outputs.isNotEmpty() && waiting.isEmpty()) continue
            // An earlier utterance must not be overtaken by later completed output.
            if (!row.source.done) break
            if (row.outputs.isEmpty()) {
                if (row.source.text.isEmpty()) continue
                break
            }
            if (!waiting.all { it in audioDone && transcripts.outputs[it]?.done == true }) break
            for (output in waiting) {
                released.add(output)
                buffers.remove(output)?.toByteArray()?.let {
                    bufferedBytes -= it.size
                    ready.add(it)
                }
            }
        }
        return ready
    }
}
