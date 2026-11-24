package com.localrecorder.live

import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

/** Qwen 3.8 wire events used by the transcript and playback reducers. Other events are transport-only. */
internal object Qwen38Adapter {
    fun sessionUpdate(config: LiveTranslateConfig): JSONObject {
        val audio = JSONObject().put(
            "input", JSONObject()
                .put("format", JSONObject().put("type", config.profile.inputFormat).put("sample_rate", LiveTranslateConfig.INPUT_SAMPLE_RATE))
                .put("turn_detection", config.profile.detectionParameters())
        )
        if (config.audioOutput) {
            audio.put("output", JSONObject().put("format", JSONObject().put("type", "pcm").put("sample_rate", LiveTranslateConfig.OUTPUT_SAMPLE_RATE)))
        }
        return JSONObject().put("type", "session.update").put(
            "session", JSONObject()
                .put("output_modalities", JSONArray(config.outputModalities))
                .put("translation", JSONObject().put("language", config.language))
                .put("audio", audio)
        )
    }

    fun decode(event: JSONObject): LiveSessionEvent? {
        val type = event.optString("type")
        val eventID = event.optStringOrNull("event_id")
        val item = event.optStringOrNull("item_id")
        if (type == "response.audio.delta" || type == "response.audio.done") {
            val samples = event.optStringOrNull("delta")?.let {
                try { Base64.getDecoder().decode(it) } catch (_: IllegalArgumentException) { null }
            }
            return LiveSessionEvent.Audio(item, samples, type == "response.audio.done", eventID)
        }
        if (type == "conversation.item.created") {
            val output = event.optJSONObject("item") ?: return null
            val source = event.optStringOrNull("previous_item_id") ?: return null
            if (output.optString("role") != "assistant") return null
            return LiveSessionEvent.Link(source, output.optStringOrNull("id") ?: return null, eventID)
        }
        item ?: return null
        return when (type) {
            "input_audio_buffer.speech_stopped" -> LiveSessionEvent.SpeechEnd(event.optInt("audio_end_ms"), eventID, item)
            "input_audio_buffer.speech_started" -> LiveSessionEvent.SpeechStart(item, event.optInt("audio_start_ms"), eventID)
            "conversation.item.input_audio_transcription.delta" -> LiveSessionEvent.Text(item, event.optString("delta"), true, false, eventID)
            "conversation.item.input_audio_transcription.completed" -> LiveSessionEvent.Text(item, event.optString("transcript"), true, true, eventID)
            "response.text.delta", "response.audio_transcript.delta" -> LiveSessionEvent.Text(item, event.optString("delta"), false, false, eventID)
            "response.text.done", "response.audio_transcript.done" -> LiveSessionEvent.Text(item,
                event.optStringOrNull("text") ?: event.optString("transcript"), false, true, eventID)
            else -> null
        }
    }
}
