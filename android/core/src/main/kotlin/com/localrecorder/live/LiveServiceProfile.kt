package com.localrecorder.live

import org.json.JSONArray
import org.json.JSONObject

data class LiveServiceProfile(
    val id: String = "qwen-default",
    val name: String = "Qwen LiveTranslate",
    val endpoint: String = LiveTranslateConfig.DEFAULT_ENDPOINT,
    val modelID: String = LiveTranslateConfig.MODEL,
    val protocolID: String = QWEN_PROTOCOL_ID,
    val version: String = QWEN_VERSION,
    val inputFormat: String = "pcm",
    val turnDetection: String = "server_vad",
    val threshold: Double = 0.5,
    val silenceMS: Int = 1000,
) {
    val isGeminiLive: Boolean get() = protocolID == GEMINI_PROTOCOL_ID

    fun switchingProtocol(targetProtocolID: String): LiveServiceProfile {
        val targetIsGemini = targetProtocolID == GEMINI_PROTOCOL_ID
        val targetVersion = if (targetIsGemini) GEMINI_VERSION else QWEN_VERSION
        val targetEndpoint = if (targetIsGemini) GEMINI_DEFAULT_ENDPOINT else LiveTranslateConfig.DEFAULT_ENDPOINT
        val targetModel = if (targetIsGemini) GEMINI_DEFAULT_MODEL else LiveTranslateConfig.MODEL
        val otherEndpoint = if (targetIsGemini) LiveTranslateConfig.DEFAULT_ENDPOINT else GEMINI_DEFAULT_ENDPOINT
        val otherModel = if (targetIsGemini) LiveTranslateConfig.MODEL else GEMINI_DEFAULT_MODEL

        val trimmedEndpoint = endpoint.trim()
        val trimmedModel = modelID.trim()
        return copy(
            protocolID = if (targetIsGemini) GEMINI_PROTOCOL_ID else QWEN_PROTOCOL_ID,
            version = targetVersion,
            endpoint = if (trimmedEndpoint.isEmpty() || trimmedEndpoint == otherEndpoint) targetEndpoint else endpoint,
            modelID = if (trimmedModel.isEmpty() || trimmedModel == otherModel) targetModel else modelID,
        )
    }

    fun transport(listener: LiveTransport.Listener, executor: java.util.concurrent.Executor, allowLocalhost: Boolean): LiveTransport {
        validate()
        return if (isGeminiLive) {
            GeminiLiveClient(listener, executor, allowLocalhost = allowLocalhost)
        } else {
            LiveTranslateClient(listener, executor, allowLocalhost = allowLocalhost)
        }
    }

    fun validate() {
        val supportedProtocol = (protocolID == QWEN_PROTOCOL_ID && version == QWEN_VERSION) ||
            (protocolID == GEMINI_PROTOCOL_ID && version == GEMINI_VERSION)
        if (!supportedProtocol || inputFormat != "pcm")
            throw LiveTranslateException(LiveMessage.UnsupportedProtocol)
        if (name.isBlank() || modelID.isBlank() || modelID.any { it.isWhitespace() || it.isISOControl() })
            throw LiveTranslateException(LiveMessage.InvalidProfileNameOrModel)
        if (!isGeminiLive && (turnDetection !in setOf("server_vad", "speaker_detection") || threshold !in 0.0..1.0 || silenceMS !in 1..60000))
            throw LiveTranslateException(LiveMessage.InvalidTurnDetection)
    }

    fun detectionParameters(): JSONObject = JSONObject().put("type", turnDetection).apply {
        if (turnDetection == "server_vad") put("threshold", threshold).put("silence_duration_ms", silenceMS)
    }

    fun json(): JSONObject = JSONObject()
        .put("id", id).put("name", name).put("endpoint", endpoint).put("modelID", modelID)
        .put("protocolID", protocolID).put("version", version).put("turnDetection", turnDetection)
        .put("threshold", threshold).put("silenceMS", silenceMS).put("inputFormat", inputFormat)

    companion object {
        const val QWEN_PROTOCOL_ID = "qwen-livetranslate"
        const val QWEN_VERSION = "3.8"
        const val GEMINI_PROTOCOL_ID = GeminiLiveAdapter.PROTOCOL_ID
        const val GEMINI_VERSION = GeminiLiveAdapter.VERSION
        const val GEMINI_DEFAULT_ENDPOINT = GeminiLiveAdapter.DEFAULT_ENDPOINT
        const val GEMINI_DEFAULT_MODEL = GeminiLiveAdapter.DEFAULT_MODEL

        fun parse(json: JSONObject) = LiveServiceProfile(
            id = json.getString("id"), name = json.getString("name"), endpoint = json.getString("endpoint"),
            modelID = json.getString("modelID"), protocolID = json.getString("protocolID"), version = json.getString("version"),
            inputFormat = json.optString("inputFormat", "pcm"), turnDetection = json.optString("turnDetection", "server_vad"),
            threshold = json.optDouble("threshold", 0.5), silenceMS = json.optInt("silenceMS", 1000),
        )
    }
}

data class LiveServiceCatalog(val profiles: List<LiveServiceProfile>, val selectedID: String) {
    constructor(profile: LiveServiceProfile) : this(listOf(profile), profile.id)
    val selected get() = profiles.single { it.id == selectedID }

    fun using(profile: LiveServiceProfile): LiveServiceCatalog {
        val updated = if (profiles.any { it.id == profile.id }) profiles.map { if (it.id == profile.id) profile else it }
                      else profiles + profile
        return LiveServiceCatalog(updated, profile.id)
    }

    fun json() = JSONObject().put("selectedID", selectedID).put("profiles", JSONArray(profiles.map { it.json() }))

    companion object {
        fun parse(json: JSONObject): LiveServiceCatalog {
            val list = json.getJSONArray("profiles")
            val profiles = (0 until list.length()).map { LiveServiceProfile.parse(list.getJSONObject(it)) }
            val selected = json.getString("selectedID")
            require(profiles.any { it.id == selected } && profiles.distinctBy { it.id }.size == profiles.size)
            return LiveServiceCatalog(profiles, selected)
        }
    }
}
