package com.localrecorder.live

import org.json.JSONArray
import org.json.JSONObject

data class LiveServiceProfile(
    val id: String = "qwen-default",
    val name: String = "Qwen LiveTranslate",
    val endpoint: String = LiveTranslateConfig.DEFAULT_ENDPOINT,
    val modelID: String = LiveTranslateConfig.MODEL,
    val protocolID: String = "qwen-livetranslate",
    val version: String = "3.8",
    val inputFormat: String = "pcm",
    val turnDetection: String = "server_vad",
    val threshold: Double = 0.5,
    val silenceMS: Int = 1000,
) {
    fun transport(listener: LiveTransport.Listener, executor: java.util.concurrent.Executor, allowLocalhost: Boolean): LiveTransport {
        validate()
        return LiveTranslateClient(listener, executor, allowLocalhost = allowLocalhost)
    }

    fun validate() {
        if (protocolID != "qwen-livetranslate" || version != "3.8" || inputFormat != "pcm")
            throw LiveTranslateException(LiveMessage.UnsupportedProtocol)
        if (name.isBlank() || modelID.isBlank() || modelID.any { it.isWhitespace() || it.isISOControl() })
            throw LiveTranslateException(LiveMessage.InvalidProfileNameOrModel)
        if (turnDetection !in setOf("server_vad", "speaker_detection") || threshold !in 0.0..1.0 || silenceMS !in 1..60000)
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
        fun parse(json: JSONObject) = LiveServiceProfile(
            id = json.getString("id"), name = json.getString("name"), endpoint = json.getString("endpoint"),
            modelID = json.getString("modelID"), protocolID = json.getString("protocolID"), version = json.getString("version"),
            inputFormat = json.getString("inputFormat"), turnDetection = json.getString("turnDetection"),
            threshold = json.getDouble("threshold"), silenceMS = json.getInt("silenceMS"),
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
