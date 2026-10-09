package com.localrecorder.shengjian

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.LiveTranslateException

/** 16 kHz mono PCM16 from the microphone, delivered in 100 ms chunks on a dedicated thread. */
class MicrophoneSource(
    private val onChunk: (ByteArray) -> Unit,
    private val onError: (String) -> Unit,
) {
    @Volatile private var running = false
    private var record: AudioRecord? = null
    private var thread: Thread? = null

    /** The caller must hold RECORD_AUDIO. */
    @SuppressLint("MissingPermission")
    fun start() {
        val rate = LiveTranslateConfig.INPUT_SAMPLE_RATE
        val minimum = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) throw LiveTranslateException("设备不支持 16 kHz 单声道录音")
        val recorder = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION, rate,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum, CHUNK_BYTES * 4),
        )
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            throw LiveTranslateException("无法打开麦克风，请检查录音权限或是否被其他应用占用")
        }
        recorder.startRecording()
        if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            recorder.release()
            throw LiveTranslateException("麦克风启动失败，可能正被其他应用占用")
        }
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
        recorder.release()
    }

    private companion object {
        const val CHUNK_BYTES = LiveTranslateConfig.INPUT_SAMPLE_RATE * 2 / 10
    }
}
