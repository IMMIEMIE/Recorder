package com.localrecorder.live

import org.json.JSONObject
import java.net.URI

class LiveTranslateException(val liveMessage: LiveMessage) : Exception(liveMessage.defaultText) {
    constructor(message: String) : this(LiveMessage.Raw(message))
}

enum class PlaybackTiming(val id: String, val title: String) {
    STREAMING("streaming", "边说边播放"),
    AFTER_FINAL("afterFinal", "定稿后播放");

    companion object {
        fun of(id: String?): PlaybackTiming = entries.firstOrNull { it.id == id } ?: STREAMING
    }
}

/** Mirrors the macOS LiveTranslateConfiguration; the persisted JSON uses the same keys. */
data class LiveTranslateConfig(
    val catalog: LiveServiceCatalog = LiveServiceCatalog(LiveServiceProfile()),
    val language: String = "zh",
    val audioOutput: Boolean = false,
    val volume: Float = 0.8f,
    val playbackTiming: PlaybackTiming = PlaybackTiming.STREAMING,
) {
    constructor(endpoint: String, language: String = "zh", audioOutput: Boolean = false, volume: Float = 0.8f,
                playbackTiming: PlaybackTiming = PlaybackTiming.STREAMING) :
        this(LiveServiceCatalog(LiveServiceProfile(endpoint = endpoint)), language, audioOutput, volume, playbackTiming)

    val profile get() = catalog.selected
    val endpoint get() = profile.endpoint
    companion object {
        const val MODEL = "qwen3.8-livetranslate-flash-realtime"
        const val DEFAULT_ENDPOINT = "wss://maas.qianwenaiapi.com/api-ws/v1/realtime"
        const val INPUT_SAMPLE_RATE = 16_000
        const val OUTPUT_SAMPLE_RATE = 24_000
        val LANGUAGES = listOf(
            "zh" to "中文", "en" to "English", "ja" to "日本語", "ko" to "한국어",
            "fr" to "Français", "de" to "Deutsch", "es" to "Español", "ru" to "Русский",
        )
        val SOURCE_LANGUAGES = listOf(
            "" to "自动",
            "zhen" to "中英双语 (zhen)",
        ) + LANGUAGES

        fun fromJson(text: String?): LiveTranslateConfig {
            if (text.isNullOrEmpty()) return LiveTranslateConfig()
            return try {
                val json = JSONObject(text)
                LiveTranslateConfig(
                    catalog = json.optJSONObject("catalog")?.let(LiveServiceCatalog::parse)
                        ?: LiveServiceCatalog(LiveServiceProfile(endpoint = json.getString("endpoint"))),
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

    /** Validated connection URL with the selected model query. */
    fun url(allowLocalhost: Boolean = false): String {
        profile.validate()
        val invalid = LiveTranslateException(LiveMessage.InvalidEndpointOrLanguage)
        val uri = try {
            URI(endpoint.trim())
        } catch (_: Exception) {
            throw invalid
        }
        val host = uri.host
        val scheme = uri.scheme
        val path = uri.rawPath
        val queryNames = uri.rawQuery?.split('&')?.map { it.substringBefore('=') } ?: emptyList()
        val queryValid = if (profile.isVolcAst) queryNames.isEmpty() else queryNames.all { it == "model" }
        if (host.isNullOrEmpty() || uri.rawUserInfo != null || uri.rawFragment != null ||
            !(scheme == "wss" || (allowLocalhost && scheme == "ws" && host == "127.0.0.1")) ||
            path.isNullOrEmpty() || path == "/" || uri.port == 0 || uri.port > 65535 ||
            !queryValid ||
            !volume.isFinite() || volume !in 0f..1f ||
            LANGUAGES.none { it.first == language }
        ) throw invalid
        val port = if (uri.port == -1) "" else ":${uri.port}"
        if (profile.isVolcAst) {
            return "$scheme://$host$port$path"
        }
        val model = java.net.URLEncoder.encode(profile.modelID, "UTF-8")
        return "$scheme://$host$port$path?model=$model"
    }

    fun normalized(allowLocalhost: Boolean = false): LiveTranslateConfig {
        val uri = URI(url(allowLocalhost))
        val port = if (uri.port == -1 || (uri.port == 443 && uri.scheme == "wss")) "" else ":${uri.port}"
        val address = "${uri.scheme}://${uri.host.lowercase()}$port${uri.rawPath}"
        return copy(catalog = catalog.using(profile.copy(endpoint = address)))
    }

    /** Shared by the connection and probes that construct their own WebSocket request. */
    fun sessionUpdate(): JSONObject {
        profile.validate()
        return Qwen38Adapter.sessionUpdate(this)
    }

    fun toJson(): String = JSONObject()
        .put("enabled", true)
        .put("catalog", catalog.json())
        .put("language", language)
        .put("audioOutput", audioOutput)
        .put("volume", volume.toDouble())
        .put("playbackTiming", playbackTiming.id)
        .toString()

}
