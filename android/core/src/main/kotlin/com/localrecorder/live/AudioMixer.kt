package com.localrecorder.live

/** Selected audio capture source for one-way live translation on Android. */
enum class AudioSourceMode(val id: String) {
    MICROPHONE("microphone"),
    SYSTEM_AUDIO("system"),
    SYSTEM_AND_MIC("system_and_mic");

    val usesSystemAudio: Boolean get() = this != MICROPHONE
    val usesMicrophone: Boolean get() = this != SYSTEM_AUDIO

    companion object {
        fun of(id: String?): AudioSourceMode = entries.firstOrNull { it.id == id } ?: MICROPHONE
    }
}

/**
 * Pure JVM 16 kHz mono PCM16 mixer combining system playback capture and microphone capture into
 * fixed-size chunks (100 ms / 3,200 bytes by default).
 *
 * - Thread-safe: [pushSystem], [pushMic], [mixNextChunk], [flush], and [reset] may be called from
 *   separate threads.
 * - Non-blocking: if one source is silent or temporarily delayed, missing samples are zero-padded so
 *   the other source continues smoothly.
 * - Bounded latency: each channel caps buffered audio to [maxBufferedBytes] by dropping the oldest
 *   whole samples on overflow.
 * - No clipping wrap-around: samples are summed in Int32 and clamped to signed 16-bit range.
 */
class AudioMixer(
    val chunkBytes: Int = CHUNK_BYTES,
    val maxBufferedBytes: Int = chunkBytes * 5,
) {
    init {
        require(chunkBytes > 0 && chunkBytes % 2 == 0) { "chunkBytes must be a positive even integer" }
        require(maxBufferedBytes >= chunkBytes && maxBufferedBytes % 2 == 0) {
            "maxBufferedBytes must be an even integer >= chunkBytes"
        }
    }

    private val lock = Any()
    private val system = ChannelQueue(maxBufferedBytes)
    private val mic = ChannelQueue(maxBufferedBytes)

    val systemBufferedBytes: Int get() = synchronized(lock) { system.size }
    val micBufferedBytes: Int get() = synchronized(lock) { mic.size }

    fun pushSystem(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        synchronized(lock) { system.push(pcm) }
    }

    fun pushMic(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        synchronized(lock) { mic.push(pcm) }
    }

    /**
     * Produces one [chunkBytes] mixed PCM16 chunk, zero-padding whichever source has fewer bytes
     * queued. When [requireData] is true and both channels hold less than one whole sample (2 bytes),
     * returns null.
     */
    fun mixNextChunk(requireData: Boolean = true): ByteArray? = synchronized(lock) {
        if (requireData && system.size < 2 && mic.size < 2) return@synchronized null
        val sysBytes = system.poll(chunkBytes)
        val micBytes = mic.poll(chunkBytes)
        mixFixed(sysBytes, micBytes, chunkBytes)
    }

    /**
     * Drains all remaining queued samples from both channels in slices up to [chunkBytes].
     * The final slice is sized to the longer remaining channel (even bytes) to avoid trailing zeros.
     */
    fun flush(): List<ByteArray> = synchronized(lock) {
        val chunks = mutableListOf<ByteArray>()
        while (system.size >= 2 || mic.size >= 2) {
            val remaining = maxOf(system.size, mic.size)
            val targetBytes = minOf(chunkBytes, remaining and 1.inv())
            if (targetBytes <= 0) break
            val sysBytes = system.poll(targetBytes)
            val micBytes = mic.poll(targetBytes)
            chunks += mixFixed(sysBytes, micBytes, targetBytes)
        }
        system.clear()
        mic.clear()
        chunks
    }

    fun reset() = synchronized(lock) {
        system.clear()
        mic.clear()
    }

    private class ChannelQueue(private val limit: Int) {
        private val chunks = ArrayDeque<ByteArray>()
        private var headOffset = 0
        private var carry: Byte? = null
        var size = 0
            private set

        fun push(data: ByteArray) {
            val normalized: ByteArray
            val pending = carry
            if (pending != null) {
                val combined = ByteArray(data.size + 1)
                combined[0] = pending
                data.copyInto(combined, destinationOffset = 1)
                carry = null
                normalized = combined
            } else {
                normalized = data
            }
            val usable = normalized.size and 1.inv()
            if (normalized.size % 2 == 1) carry = normalized.last()
            if (usable == 0) return
            chunks.addLast(if (usable == normalized.size) normalized.copyOf() else normalized.copyOf(usable))
            size += usable
            trimToLimit()
        }

        fun poll(maxBytes: Int): ByteArray {
            val count = minOf(maxBytes and 1.inv(), size)
            if (count <= 0) return ByteArray(0)
            val out = ByteArray(count)
            var written = 0
            while (written < count) {
                val head = chunks.first()
                val available = head.size - headOffset
                val take = minOf(available, count - written)
                head.copyInto(out, destinationOffset = written, startIndex = headOffset, endIndex = headOffset + take)
                written += take
                headOffset += take
                size -= take
                if (headOffset >= head.size) {
                    chunks.removeFirst()
                    headOffset = 0
                }
            }
            return out
        }

        fun clear() {
            chunks.clear()
            headOffset = 0
            carry = null
            size = 0
        }

        private fun trimToLimit() {
            var excess = size - limit
            if (excess <= 0) return
            // Keep sample alignment (even byte count).
            if (excess % 2 == 1) excess++
            while (excess > 0 && chunks.isNotEmpty()) {
                val head = chunks.first()
                val available = head.size - headOffset
                if (available <= excess) {
                    chunks.removeFirst()
                    headOffset = 0
                    size -= available
                    excess -= available
                } else {
                    headOffset += excess
                    size -= excess
                    excess = 0
                }
            }
        }
    }

    companion object {
        /** 100 ms of 16 kHz mono signed 16-bit little-endian PCM. */
        const val CHUNK_MS = 100L
        const val CHUNK_SAMPLES = LiveTranslateConfig.INPUT_SAMPLE_RATE / 10
        const val CHUNK_BYTES = CHUNK_SAMPLES * 2

        /**
         * Mixes two little-endian signed PCM16 buffers of arbitrary lengths, zero-padding the
         * shorter one and clamping Int32 sums to [Short.MIN_VALUE]..[Short.MAX_VALUE].
         */
        fun mixPcm16(a: ByteArray, b: ByteArray): ByteArray {
            val bytes = maxOf(a.size, b.size) and 1.inv()
            return mixFixed(a, b, bytes)
        }

        private fun mixFixed(a: ByteArray, b: ByteArray, outBytes: Int): ByteArray {
            val out = ByteArray(outBytes)
            val aLimit = a.size and 1.inv()
            val bLimit = b.size and 1.inv()
            var i = 0
            while (i < outBytes) {
                val sampleA = if (i < aLimit) readLe16(a, i) else 0
                val sampleB = if (i < bLimit) readLe16(b, i) else 0
                val sum = (sampleA + sampleB).coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                out[i] = (sum and 0xFF).toByte()
                out[i + 1] = ((sum ushr 8) and 0xFF).toByte()
                i += 2
            }
            return out
        }

        private fun readLe16(buf: ByteArray, offset: Int): Int {
            val lo = buf[offset].toInt() and 0xFF
            val hi = buf[offset + 1].toInt()
            return (hi shl 8) or lo
        }
    }
}

/**
 * Detects continuous digital-zero silence on a 16 kHz mono PCM16 system audio stream (for example,
 * when an app opts out of AudioPlaybackCapture or plays DRM-protected media).
 *
 * Returns true at most once per session after [thresholdMs] of uninterrupted all-zero audio.
 */
class SilenceTracker(
    thresholdMs: Long = DEFAULT_THRESHOLD_MS,
    bytesPerMs: Int = LiveTranslateConfig.INPUT_SAMPLE_RATE * 2 / 1000,
) {
    private val thresholdBytes: Long = thresholdMs * bytesPerMs
    private var silentBytes: Long = 0L
    var triggered: Boolean = false
        private set

    fun observe(pcm: ByteArray): Boolean {
        if (triggered || pcm.isEmpty()) return false
        val usable = pcm.size and 1.inv()
        var allZero = true
        for (i in 0 until usable) {
            if (pcm[i] != 0.toByte()) {
                allZero = false
                break
            }
        }
        if (allZero) {
            silentBytes += usable
            if (silentBytes >= thresholdBytes) {
                triggered = true
                return true
            }
        } else {
            silentBytes = 0L
        }
        return false
    }

    fun reset() {
        silentBytes = 0L
        triggered = false
    }

    companion object {
        const val DEFAULT_THRESHOLD_MS = 7_000L
    }
}
