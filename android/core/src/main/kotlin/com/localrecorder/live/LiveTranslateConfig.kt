package com.localrecorder.live

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

class LiveTranslateException(message: String) : Exception(message)

enum class PlaybackTiming(val id: String, val title: String) {
    STREAMING("streaming", "边说边播放"),
    AFTER_FINAL("afterFinal", "定稿后播放");

    companion object {
        fun of(id: String?): PlaybackTiming = entries.firstOrNull { it.id == id } ?: STREAMING
    }
}

/** Mirrors the macOS LiveTranslateConfiguration; the persisted JSON uses the same keys. */
data class LiveTranslateConfig(
    val endpoint: String = DEFAULT_ENDPOINT,
    val language: String = "zh",
    val audioOutput: Boolean = false,
    val volume: Float = 0.8f,
    val playbackTiming: PlaybackTiming = PlaybackTiming.STREAMING,
) {
    companion object {
        const val MODEL = "qwen3.8-livetranslate-flash-realtime"
        const val DEFAULT_ENDPOINT = "wss://maas.qianwenaiapi.com/api-ws/v1/realtime"
        const val INPUT_SAMPLE_RATE = 16_000
        const val OUTPUT_SAMPLE_RATE = 24_000
        val LANGUAGES = listOf(
            "zh" to "中文", "en" to "English", "ja" to "日本語", "ko" to "한국어",
            "fr" to "Français", "de" to "Deutsch", "es" to "Español", "ru" to "Русский",
        )

        fun fromJson(text: String?): LiveTranslateConfig {
            if (text.isNullOrEmpty()) return LiveTranslateConfig()
            return try {
                val json = JSONObject(text)
                LiveTranslateConfig(
                    endpoint = json.getString("endpoint"),
                    language = json.getString("language"),
                    audioOutput = json.optBoolean("audioOutput", false),
                    volume = json.optDouble("volume", 0.8).toFloat(),
                    playbackTiming = PlaybackTiming.of(json.optString("playbackTiming", "streaming")),
                )
            } catch (_: Exception) {
                LiveTranslateConfig()
            }
        }
    }

    val outputModalities: List<String> get() = if (audioOutput) listOf("text", "audio") else listOf("text")
    val languageName: String get() = LANGUAGES.firstOrNull { it.first == language }?.second ?: language

    /** Separate credential namespace per endpoint, as on macOS. */
    val keyAccount: String get() = "livetranslate:$endpoint"

    /** Validated connection URL with the fixed model query. */
    fun url(allowLocalhost: Boolean = false): String {
        val invalid = LiveTranslateException("请填写有效的 WSS 实时服务地址，并选择支持的目标语言")
        val uri = try {
            URI(endpoint.trim())
        } catch (_: Exception) {
            throw invalid
        }
        val host = uri.host
        val scheme = uri.scheme
        val path = uri.rawPath
        val queryNames = uri.rawQuery?.split('&')?.map { it.substringBefore('=') } ?: emptyList()
        if (host.isNullOrEmpty() || uri.rawUserInfo != null || uri.rawFragment != null ||
            !(scheme == "wss" || (allowLocalhost && scheme == "ws" && host == "127.0.0.1")) ||
            path.isNullOrEmpty() || path == "/" ||
            !queryNames.all { it == "model" } ||
            !volume.isFinite() || volume !in 0f..1f ||
            LANGUAGES.none { it.first == language }
        ) throw invalid
        val port = if (uri.port == -1) "" else ":${uri.port}"
        return "$scheme://$host$port$path?model=$MODEL"
    }

    fun normalized(): LiveTranslateConfig {
        val uri = URI(url())
        val port = if (uri.port == -1 || uri.port == 443) "" else ":${uri.port}"
        return copy(endpoint = "${uri.scheme}://${uri.host.lowercase()}$port${uri.rawPath}")
    }

    fun toJson(): String = JSONObject()
        .put("enabled", true)
        .put("endpoint", endpoint)
        .put("language", language)
        .put("audioOutput", audioOutput)
        .put("volume", volume.toDouble())
        .put("playbackTiming", playbackTiming.id)
        .toString()

    fun sessionUpdate(): JSONObject {
        val audio = JSONObject().put(
            "input", JSONObject()
                .put("format", JSONObject().put("type", "pcm").put("sample_rate", INPUT_SAMPLE_RATE))
                .put(
                    "turn_detection", JSONObject().put("type", "server_vad")
                        .put("threshold", 0.5).put("silence_duration_ms", 1000)
                )
        )
        if (audioOutput) {
            audio.put("output", JSONObject().put("format", JSONObject().put("type", "pcm").put("sample_rate", OUTPUT_SAMPLE_RATE)))
        }
        return JSONObject().put("type", "session.update").put(
            "session", JSONObject()
                .put("output_modalities", JSONArray(outputModalities))
                .put("translation", JSONObject().put("language", language))
                .put("audio", audio)
        )
    }
}
