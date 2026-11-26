package com.localrecorder.shengjian

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Process
import androidx.annotation.RequiresApi
import com.localrecorder.live.AudioMixer
import com.localrecorder.live.LiveMessage
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.LiveTranslateException
import com.localrecorder.live.SilenceTracker
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 16 kHz mono PCM16 capture of other apps' playback audio via Android 10+ AudioPlaybackCapture.
 * Excludes this app's own UID so Shengjian's translated speech playback is never looped back.
 */
@RequiresApi(Build.VERSION_CODES.Q)
class PlaybackAudioSource(
    private val mediaProjection: MediaProjection,
    private val onChunk: (ByteArray) -> Unit,
    private val onError: (LiveMessage) -> Unit,
    private val onSilent: () -> Unit = {},
) {
    @Volatile private var running = false
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private val silenceTracker = SilenceTracker()

    /** The caller must hold RECORD_AUDIO and an active MediaProjection with a mediaProjection FGS. */
    @SuppressLint("MissingPermission")
    fun start() {
        val rate = LiveTranslateConfig.INPUT_SAMPLE_RATE
        val minimum = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) throw LiveTranslateException(LiveMessage.MicUnsupported)

        val captureConfig = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .excludeUid(Process.myUid())
            .build()

        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(rate)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()

        val recorder = try {
            AudioRecord.Builder()
                .setAudioFormat(format)
                .setBufferSizeInBytes(maxOf(minimum, CHUNK_BYTES * 4))
                .setAudioPlaybackCaptureConfig(captureConfig)
                .build()
        } catch (_: Exception) {
            throw LiveTranslateException(LiveMessage.SystemAudioOpenFailed)
        }

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            throw LiveTranslateException(LiveMessage.SystemAudioOpenFailed)
        }
        try {
            recorder.startRecording()
        } catch (_: Exception) {
            recorder.release()
            throw LiveTranslateException(LiveMessage.SystemAudioStartFailed)
        }
        if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            recorder.release()
            throw LiveTranslateException(LiveMessage.SystemAudioStartFailed)
        }

        silenceTracker.reset()
        record = recorder
        running = true
        thread = Thread({ loop(recorder) }, "playback-capture").also { it.start() }
    }

    private fun loop(recorder: AudioRecord) {
        val buffer = ByteArray(CHUNK_BYTES)
        while (running) {
            var filled = 0
            while (running && filled < CHUNK_BYTES) {
                val count = recorder.read(buffer, filled, CHUNK_BYTES - filled)
                if (count < 0) {
                    if (running) {
                        running = false
                        onError(LiveMessage.SystemAudioReadFailed(count))
                    }
                    return
                }
                filled += count
            }
            if (filled > 0) {
                val chunk = buffer.copyOf(filled)
                if (silenceTracker.observe(chunk)) onSilent()
                onChunk(chunk)
            }
        }
    }

    /** Stops capture and waits for the last chunk to be delivered. */
    fun stop() {
        running = false
        val recorder = record ?: return
        record = null
        try {
            recorder.stop()
        } catch (_: IllegalStateException) {
        }
        thread?.join(1_000)
        thread = null
        recorder.release()
    }

    private companion object {
        const val CHUNK_BYTES = AudioMixer.CHUNK_BYTES
    }
}

/**
 * Concurrently captures system playback audio and microphone input, combining both streams through
 * [AudioMixer] on a fixed 100 ms monotonic cadence into 16 kHz mono PCM16 chunks.
 */
@RequiresApi(Build.VERSION_CODES.Q)
class MixedAudioSource(
    private val mediaProjection: MediaProjection,
    private val onChunk: (ByteArray) -> Unit,
    private val onError: (LiveMessage) -> Unit,
    private val onSystemSilent: () -> Unit = {},
    private val communication: Boolean = false,
    private val preferredDevice: AudioDeviceInfo? = null,
) {
    private val mixer = AudioMixer()
    private val failed = AtomicBoolean(false)
    @Volatile private var running = false
    private var playback: PlaybackAudioSource? = null
    private var microphone: MicrophoneSource? = null
    private var mixerThread: Thread? = null

    val micSessionId: Int get() = microphone?.sessionId ?: 0
    val echoCancelled: Boolean get() = microphone?.echoCancelled == true

    fun start() {
        failed.set(false)
        mixer.reset()
        val sys = PlaybackAudioSource(
            mediaProjection = mediaProjection,
            onChunk = mixer::pushSystem,
            onError = ::failOnce,
            onSilent = onSystemSilent,
        )
        val mic = MicrophoneSource(
            onChunk = mixer::pushMic,
            onError = ::failOnce,
            communication = communication,
            preferredDevice = preferredDevice,
        )
        sys.start()
        try {
            mic.start()
        } catch (e: Exception) {
            sys.stop()
            throw e
        }
        playback = sys
        microphone = mic
        running = true
        mixerThread = Thread(::mixLoop, "audio-mixer").also { it.start() }
    }

    private fun failOnce(message: LiveMessage) {
        if (failed.compareAndSet(false, true)) {
            running = false
            onError(message)
        }
    }

    private fun mixLoop() {
        val periodNs = AudioMixer.CHUNK_MS * 1_000_000L
        var nextTickNs = System.nanoTime() + periodNs
        while (running) {
            val sleepNs = nextTickNs - System.nanoTime()
            if (sleepNs > 0) {
                try {
                    Thread.sleep(sleepNs / 1_000_000L, (sleepNs % 1_000_000L).toInt())
                } catch (_: InterruptedException) {
                    if (!running) break
                }
            } else if (-sleepNs > periodNs * 4) {
                // Re-anchor after a long OS pause instead of firing a burst of catch-up ticks.
                nextTickNs = System.nanoTime()
            }
            if (!running) break
            mixer.mixNextChunk(requireData = true)?.let(onChunk)
            nextTickNs += periodNs
        }
    }

    /** Stops both sources and the mixer thread, then flushes any remaining mixed samples. */
    fun stop() {
        running = false
        playback?.stop()
        playback = null
        microphone?.stop()
        microphone = null
        mixerThread?.let {
            it.interrupt()
            it.join(1_000)
        }
        mixerThread = null
        for (tail in mixer.flush()) {
            onChunk(tail)
        }
    }
}
