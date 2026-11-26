package com.localrecorder.live

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class AudioMixerTest {
    private fun pcm(vararg samples: Int): ByteArray {
        val buf = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) buf.putShort(s.toShort())
        return buf.array()
    }

    private fun decode(bytes: ByteArray): IntArray {
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        return IntArray(bytes.size / 2) { buf.short.toInt() }
    }

    @Test
    fun audioSourceModeRoundTripAndFlags() {
        assertEquals(AudioSourceMode.MICROPHONE, AudioSourceMode.of("microphone"))
        assertEquals(AudioSourceMode.SYSTEM_AUDIO, AudioSourceMode.of("system"))
        assertEquals(AudioSourceMode.SYSTEM_AND_MIC, AudioSourceMode.of("system_and_mic"))
        assertEquals(AudioSourceMode.MICROPHONE, AudioSourceMode.of("unknown"))
        assertEquals(AudioSourceMode.MICROPHONE, AudioSourceMode.of(null))

        assertFalse(AudioSourceMode.MICROPHONE.usesSystemAudio)
        assertTrue(AudioSourceMode.MICROPHONE.usesMicrophone)
        assertTrue(AudioSourceMode.SYSTEM_AUDIO.usesSystemAudio)
        assertFalse(AudioSourceMode.SYSTEM_AUDIO.usesMicrophone)
        assertTrue(AudioSourceMode.SYSTEM_AND_MIC.usesSystemAudio)
        assertTrue(AudioSourceMode.SYSTEM_AND_MIC.usesMicrophone)
    }

    @Test
    fun mixPcm16SumsAndClampsWithoutWrapAround() {
        val a = pcm(1_000, 30_000, -30_000, 0, Short.MAX_VALUE.toInt(), Short.MIN_VALUE.toInt())
        val b = pcm(2_500, 20_000, -20_000, -500, 100, -100)
        val mixed = AudioMixer.mixPcm16(a, b)
        assertArrayEquals(
            intArrayOf(3_500, Short.MAX_VALUE.toInt(), Short.MIN_VALUE.toInt(), -500, Short.MAX_VALUE.toInt(), Short.MIN_VALUE.toInt()),
            decode(mixed),
        )
    }

    @Test
    fun mixNextChunkZeroPadsSilentOrDelayedSource() {
        val mixer = AudioMixer(chunkBytes = 8)
        assertNull(mixer.mixNextChunk(requireData = true))

        mixer.pushSystem(pcm(100, 200, 300, 400))
        // Mic has no data: system passes through unchanged.
        val first = mixer.mixNextChunk(requireData = true)
        assertNotNull(first)
        assertArrayEquals(intArrayOf(100, 200, 300, 400), decode(first!!))

        // Only mic arrives with half a chunk: remainder is zero-padded.
        mixer.pushMic(pcm(-50, 75))
        val second = mixer.mixNextChunk(requireData = true)
        assertNotNull(second)
        assertArrayEquals(intArrayOf(-50, 75, 0, 0), decode(second!!))
        assertEquals(0, mixer.systemBufferedBytes)
        assertEquals(0, mixer.micBufferedBytes)
    }

    @Test
    fun mixNextChunkPreservesOddByteBoundaryAcrossPushes() {
        val mixer = AudioMixer(chunkBytes = 4)
        val full = pcm(0x1234, -1000)
        // Push split across an odd byte boundary.
        mixer.pushSystem(full.copyOfRange(0, 1))
        assertNull(mixer.mixNextChunk(requireData = true))
        mixer.pushSystem(full.copyOfRange(1, 3))
        mixer.pushSystem(full.copyOfRange(3, 4))
        mixer.pushMic(pcm(10, 20))

        val out = mixer.mixNextChunk(requireData = true)!!
        assertArrayEquals(intArrayOf(0x1234 + 10, -980), decode(out))
    }

    @Test
    fun overflowDropsOldestSamplesKeepingLatestAudio() {
        val mixer = AudioMixer(chunkBytes = 4, maxBufferedBytes = 8)
        // Push 6 samples (12 bytes) into an 8-byte cap -> oldest 2 samples (1, 2) dropped.
        mixer.pushSystem(pcm(1, 2, 3, 4, 5, 6))
        assertEquals(8, mixer.systemBufferedBytes)

        val c1 = decode(mixer.mixNextChunk()!!)
        val c2 = decode(mixer.mixNextChunk()!!)
        assertArrayEquals(intArrayOf(3, 4), c1)
        assertArrayEquals(intArrayOf(5, 6), c2)
        assertNull(mixer.mixNextChunk())
    }

    @Test
    fun flushDrainsAllRemainingChunksAndClearsState() {
        val mixer = AudioMixer(chunkBytes = 4)
        mixer.pushSystem(pcm(10, 20, 30))
        mixer.pushMic(pcm(1, 2))

        val flushed = mixer.flush()
        assertEquals(2, flushed.size)
        assertArrayEquals(intArrayOf(11, 22), decode(flushed[0]))
        assertArrayEquals(intArrayOf(30), decode(flushed[1]))
        assertEquals(0, mixer.systemBufferedBytes)
        assertEquals(0, mixer.micBufferedBytes)
        assertTrue(mixer.flush().isEmpty())
    }

    @Test
    fun defaultChunkMatches100msAt16kHzMonoPcm16() {
        assertEquals(1600, AudioMixer.CHUNK_SAMPLES)
        assertEquals(3200, AudioMixer.CHUNK_BYTES)
        val mixer = AudioMixer()
        val sys = ByteArray(AudioMixer.CHUNK_BYTES)
        val mic = ByteArray(AudioMixer.CHUNK_BYTES)
        sys[0] = 5
        mic[0] = 7
        mixer.pushSystem(sys)
        mixer.pushMic(mic)
        val out = mixer.mixNextChunk()!!
        assertEquals(AudioMixer.CHUNK_BYTES, out.size)
        assertEquals(12, out[0].toInt())
    }

    @Test
    fun concurrentPushAndDrainIsThreadSafe() {
        val mixer = AudioMixer(chunkBytes = 320, maxBufferedBytes = 320 * 20)
        val start = CountDownLatch(1)
        val done = CountDownLatch(2)
        val unit = pcm(*IntArray(160) { 100 })
        val t1 = Thread {
            start.await()
            repeat(50) { mixer.pushSystem(unit) }
            done.countDown()
        }
        val t2 = Thread {
            start.await()
            repeat(50) { mixer.pushMic(unit) }
            done.countDown()
        }
        t1.start()
        t2.start()
        start.countDown()
        assertTrue(done.await(5, TimeUnit.SECONDS))
        val drained = mixer.flush()
        assertTrue(drained.isNotEmpty())
        assertEquals(0, mixer.systemBufferedBytes)
        assertEquals(0, mixer.micBufferedBytes)
    }

    @Test
    fun silenceTrackerFiresOnceAfterThresholdAndResetsOnNonZero() {
        val tracker = SilenceTracker(thresholdMs = 300L) // 3 chunks of 100ms (3200 bytes each)
        val zeros = ByteArray(AudioMixer.CHUNK_BYTES)
        val voiced = ByteArray(AudioMixer.CHUNK_BYTES).also { it[100] = 1 }

        assertFalse(tracker.observe(zeros))
        assertFalse(tracker.observe(zeros))
        // Non-zero sample resets streak before 300ms threshold.
        assertFalse(tracker.observe(voiced))
        assertFalse(tracker.triggered)

        assertFalse(tracker.observe(zeros))
        assertFalse(tracker.observe(zeros))
        assertTrue(tracker.observe(zeros))
        assertTrue(tracker.triggered)
        // Subsequent silence does not re-trigger.
        assertFalse(tracker.observe(zeros))

        tracker.reset()
        assertFalse(tracker.triggered)
        assertFalse(tracker.observe(zeros))
    }
}
