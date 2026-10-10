package com.localrecorder.shengjian

import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.MAX_PENDING_SPEECH_BYTES
import com.localrecorder.live.SpeechOutput
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Plays 24 kHz mono PCM16 translated speech with at most 30 s queued.
 * Writes are non-blocking so stop() always returns promptly. Other apps are ducked while it is
 * active; [onFocusLost] runs on [handler] when a call or another player takes the output.
 * [voiceRoute] plays through the voice-call path, which a Bluetooth headset microphone requires.
 */
class SpeechPlayer(
    private val manager: AudioManager,
    private val handler: Handler,
    private val voiceRoute: Boolean,
    private val onFocusLost: () -> Unit,
    private val onStopped: () -> Unit,
) : SpeechOutput {
    private val queue = LinkedBlockingQueue<ByteArray>()
    private val queuedBytes = AtomicInteger()
    @Volatile private var active = false
    @Volatile private var draining = false
    private var track: AudioTrack? = null
    private var thread: Thread? = null
    private var onDrained: (() -> Unit)? = null
    private var focus: AudioFocusRequest? = null

    override fun start(volume: Float) {
        release()
        val rate = LiveTranslateConfig.OUTPUT_SAMPLE_RATE
        val minimum = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val attributes = AudioAttributes.Builder()
            .setUsage(if (voiceRoute) AudioAttributes.USAGE_VOICE_COMMUNICATION else AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val audio = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build()
            )
            .setBufferSizeInBytes(maxOf(minimum, rate * 2 / 5))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        audio.setVolume(volume.coerceIn(0f, 1f))
        audio.play()
        track = audio
        // A refused request (e.g. during a call) still lets subtitles work; the call silences the output anyway.
        focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(attributes)
            .setOnAudioFocusChangeListener({ change ->
                if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) onFocusLost()
            }, handler)
            .build()
            .also(manager::requestAudioFocus)
        active = true
        draining = false
        thread = Thread({ writeLoop(audio) }, "speech-player").also { it.start() }
    }

    /** Returns false when more than 30 s would be waiting; the caller stops playback. */
    override fun append(pcm: ByteArray): Boolean {
        if (!active || draining) return false
        if (queuedBytes.get() + pcm.size > MAX_PENDING_SPEECH_BYTES) return false
        queuedBytes.addAndGet(pcm.size)
        queue.put(pcm)
        return true
    }

    /** Lets queued speech finish, then releases the player; [done] runs on the writer thread. */
    override fun finish(done: () -> Unit) {
        if (!active) {
            done(); return
        }
        onDrained = done
        draining = true
    }

    override fun stop() {
        release()
        onStopped()
    }

    private fun release() {
        focus?.let(manager::abandonAudioFocusRequest)
        focus = null
        active = false
        draining = false
        onDrained = null
        thread?.let {
            it.interrupt()
            it.join(500)
        }
        thread = null
        track?.let {
            try {
                it.pause()
                it.flush()
            } catch (_: IllegalStateException) {
            }
            it.release()
        }
        track = null
        queue.clear()
        queuedBytes.set(0)
    }

    private fun writeLoop(audio: AudioTrack) {
        var framesWritten = 0L
        try {
            while (active) {
                val data = queue.poll(100, TimeUnit.MILLISECONDS)
                if (data == null) {
                    if (draining) break
                    continue
                }
                var offset = 0
                while (active && offset < data.size) {
                    val count = audio.write(data, offset, data.size - offset, AudioTrack.WRITE_NON_BLOCKING)
                    if (count < 0) return
                    offset += count
                    if (count == 0) Thread.sleep(10)
                }
                framesWritten += data.size / 2
                queuedBytes.addAndGet(-data.size)
            }
            // Wait (bounded) for the hardware to play out what was written.
            val deadline = System.currentTimeMillis() + 32_000
            while (active && System.currentTimeMillis() < deadline &&
                (audio.playbackHeadPosition.toLong() and 0xFFFFFFFFL) < framesWritten
            ) Thread.sleep(20)
            if (active) onDrained?.invoke()
        } catch (_: InterruptedException) {
        }
    }
}
