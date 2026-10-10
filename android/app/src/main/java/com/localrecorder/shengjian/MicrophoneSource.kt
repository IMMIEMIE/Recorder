package com.localrecorder.shengjian

import android.annotation.SuppressLint
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.LiveTranslateException

/**
 * 16 kHz mono PCM16 from the microphone, delivered in 100 ms chunks on a dedicated thread.
 * [communication] selects the voice-call path with echo cancellation, for when translated speech
 * plays from the loudspeaker or a Bluetooth headset ([preferredDevice]) is the input.
 */
class MicrophoneSource(
    private val onChunk: (ByteArray) -> Unit,
    private val onError: (String) -> Unit,
    private val communication: Boolean = false,
    private val preferredDevice: AudioDeviceInfo? = null,
) {
    @Volatile private var running = false
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private var echoCanceler: AcousticEchoCanceler? = null

    /** Identifies this capture in the system's recording configurations. */
    var sessionId = 0
        private set
    val echoCancelled: Boolean get() = echoCanceler != null

    /** The caller must hold RECORD_AUDIO. */
    @SuppressLint("MissingPermission")
    fun start() {
        val rate = LiveTranslateConfig.INPUT_SAMPLE_RATE
        val minimum = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) throw LiveTranslateException("设备不支持 16 kHz 单声道录音")
        val recorder = AudioRecord(
            if (communication) MediaRecorder.AudioSource.VOICE_COMMUNICATION else MediaRecorder.AudioSource.VOICE_RECOGNITION, rate,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum, CHUNK_BYTES * 4),
        )
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            throw LiveTranslateException("无法打开麦克风，请检查录音权限或是否被其他应用占用")
        }
        preferredDevice?.let(recorder::setPreferredDevice)
        if (communication) echoCanceler = enableEchoCanceler(recorder.audioSessionId)
        recorder.startRecording()
        if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            releaseEffects()
            recorder.release()
            throw LiveTranslateException("麦克风启动失败，可能正被其他应用占用")
        }
        sessionId = recorder.audioSessionId
        record = recorder
        running = true
        thread = Thread({ loop(recorder) }, "microphone").also { it.start() }
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
                        onError("麦克风读取失败（$count），已停止录音；已有文字已保留")
                    }
                    return
                }
                filled += count
            }
            if (filled > 0) onChunk(buffer.copyOf(filled))
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
        releaseEffects()
        recorder.release()
    }

    /** Best effort: many devices already cancel echo on the voice-call path. */
    private fun enableEchoCanceler(session: Int): AcousticEchoCanceler? {
        try {
            if (!AcousticEchoCanceler.isAvailable()) return null
            val effect = AcousticEchoCanceler.create(session) ?: return null
            effect.enabled = true
            if (effect.enabled) return effect
            effect.release()
        } catch (_: Exception) {
        }
        return null
    }

    private fun releaseEffects() {
        try {
            echoCanceler?.release()
        } catch (_: Exception) {
        }
        echoCanceler = null
    }

    private companion object {
        const val CHUNK_BYTES = LiveTranslateConfig.INPUT_SAMPLE_RATE * 2 / 10
    }
}
