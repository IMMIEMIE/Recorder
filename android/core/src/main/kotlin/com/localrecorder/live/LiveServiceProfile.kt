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
    /** Optional source language for protocols that support/require it (e.g. volc-ast). Empty means automatic. */
    val sourceLanguage: String = "",
    /**
     * Optional legacy App Key (App ID) for volc-ast dual-credential auth (`X-Api-App-Key` + `X-Api-Access-Key`).
     * Leave blank to authenticate with the single `X-Api-Key` header. Never stores the secret API/Access Key.
     */
    val appKey: String = "",
) {
    val isGeminiLive: Boolean get() = protocolID == GEMINI_PROTOCOL_ID
    val isVolcAst: Boolean get() = protocolID == VOLC_AST_PROTOCOL_ID

    fun resolvedSourceLanguage(targetLanguage: String): String {
        val trimmed = sourceLanguage.trim()
        if (trimmed.isNotEmpty()) return trimmed
        return if (targetLanguage == "zh") "en" else "zh"
    }

    fun switchingProtocol(targetProtocolID: String): LiveServiceProfile {
        if (targetProtocolID == protocolID) return this
        val targetProtocol: String
        val targetVersion: String
        val targetEndpoint: String
        val targetModel: String
        val targetName: String
        when (targetProtocolID) {
            GEMINI_PROTOCOL_ID -> {
                targetProtocol = GEMINI_PROTOCOL_ID
                targetVersion = GEMINI_VERSION
                targetEndpoint = GEMINI_DEFAULT_ENDPOINT
                targetModel = GEMINI_DEFAULT_MODEL
                targetName = "Gemini Live"
            }
            VOLC_AST_PROTOCOL_ID -> {
                targetProtocol = VOLC_AST_PROTOCOL_ID
                targetVersion = VOLC_AST_VERSION
                targetEndpoint = VOLC_AST_DEFAULT_ENDPOINT
                targetModel = VOLC_AST_DEFAULT_RESOURCE_ID
                targetName = "Seed-LiveInterpret 2.0"
            }
            else -> {
                targetProtocol = QWEN_PROTOCOL_ID
                targetVersion = QWEN_VERSION
                targetEndpoint = LiveTranslateConfig.DEFAULT_ENDPOINT
                targetModel = LiveTranslateConfig.MODEL
                targetName = "Qwen LiveTranslate"
            }
        }

        val knownEndpoints = setOf(LiveTranslateConfig.DEFAULT_ENDPOINT, GEMINI_DEFAULT_ENDPOINT, VOLC_AST_DEFAULT_ENDPOINT)
        val knownModels = setOf(LiveTranslateConfig.MODEL, GEMINI_DEFAULT_MODEL, VOLC_AST_DEFAULT_RESOURCE_ID)
        val knownNames = setOf("Qwen LiveTranslate", "Gemini Live", "Seed-LiveInterpret 2.0")

        val trimmedEndpoint = endpoint.trim()
        val trimmedModel = modelID.trim()
        return copy(
            protocolID = targetProtocol,
            version = targetVersion,
            endpoint = if (trimmedEndpoint.isEmpty() || trimmedEndpoint in knownEndpoints) targetEndpoint else endpoint,
            modelID = if (trimmedModel.isEmpty() || trimmedModel in knownModels) targetModel else modelID,
            name = if (name in knownNames) targetName else name,
        )
    }

    fun transport(listener: LiveTransport.Listener, executor: java.util.concurrent.Executor, allowLocalhost: Boolean): LiveTransport {
        validate()
        return when {
            isGeminiLive -> GeminiLiveClient(listener, executor, allowLocalhost = allowLocalhost)
            isVolcAst -> SeedLiveInterpretClient(listener, executor, allowLocalhost = allowLocalhost)
            else -> LiveTranslateClient(listener, executor, allowLocalhost = allowLocalhost)
        }
    }

    fun validate() {
        val supportedProtocol = (protocolID == QWEN_PROTOCOL_ID && version == QWEN_VERSION) ||
            (protocolID == GEMINI_PROTOCOL_ID && version == GEMINI_VERSION) ||
            (protocolID == VOLC_AST_PROTOCOL_ID && version == VOLC_AST_VERSION)
        if (!supportedProtocol || inputFormat != "pcm")
            throw LiveTranslateException(LiveMessage.UnsupportedProtocol)
        if (name.isBlank() || modelID.isBlank() || modelID.any { it.isWhitespace() || it.isISOControl() })
            throw LiveTranslateException(LiveMessage.InvalidProfileNameOrModel)
        if (isVolcAst) {
            if (LiveTranslateConfig.SOURCE_LANGUAGES.none { it.first == sourceLanguage })
                throw LiveTranslateException(LiveMessage.InvalidSourceLanguage)
            val trimmedAppKey = appKey.trim()
            if (trimmedAppKey.isNotEmpty() && trimmedAppKey.any { it.code !in 33..126 })
                throw LiveTranslateException(LiveMessage.InvalidAppKeyFormat)
        } else if (!isGeminiLive) {
            if (turnDetection !in setOf("server_vad", "speaker_detection") || threshold !in 0.0..1.0 || silenceMS !in 1..60000)
                throw LiveTranslateException(LiveMessage.InvalidTurnDetection)
        }
    }

    fun detectionParameters(): JSONObject = JSONObject().put("type", turnDetection).apply {
        if (turnDetection == "server_vad") put("threshold", threshold).put("silence_duration_ms", silenceMS)
    }

    fun json(): JSONObject = JSONObject()
        .put("id", id).put("name", name).put("endpoint", endpoint).put("modelID", modelID)
        .put("protocolID", protocolID).put("version", version).put("turnDetection", turnDetection)
        .put("threshold", threshold).put("silenceMS", silenceMS).put("inputFormat", inputFormat)
        .apply {
            if (sourceLanguage.isNotEmpty()) put("sourceLanguage", sourceLanguage)
            if (appKey.isNotEmpty()) put("appKey", appKey)
        }

    companion object {
        const val QWEN_PROTOCOL_ID = "qwen-livetranslate"
        const val QWEN_VERSION = "3.8"
        const val GEMINI_PROTOCOL_ID = GeminiLiveAdapter.PROTOCOL_ID
        const val GEMINI_VERSION = GeminiLiveAdapter.VERSION
        const val GEMINI_DEFAULT_ENDPOINT = GeminiLiveAdapter.DEFAULT_ENDPOINT
        const val GEMINI_DEFAULT_MODEL = GeminiLiveAdapter.DEFAULT_MODEL
        const val VOLC_AST_PROTOCOL_ID = "volc-ast"
        const val VOLC_AST_VERSION = "2.0"
        const val VOLC_AST_DEFAULT_ENDPOINT = "wss://openspeech.bytedance.com/api/v4/ast/v2/translate"
        const val VOLC_AST_DEFAULT_RESOURCE_ID = "volc.service_type.10053"

        fun seedLiveInterpret(
            id: String = "volc-ast-default",
            name: String = "Seed-LiveInterpret 2.0",
            endpoint: String = VOLC_AST_DEFAULT_ENDPOINT,
            resourceID: String = VOLC_AST_DEFAULT_RESOURCE_ID,
            sourceLanguage: String = "",
            appKey: String = "",
        ) = LiveServiceProfile(
            id = id,
            name = name,
            endpoint = endpoint,
            modelID = resourceID,
            protocolID = VOLC_AST_PROTOCOL_ID,
            version = VOLC_AST_VERSION,
            sourceLanguage = sourceLanguage,
            appKey = appKey,
        )

        fun parse(json: JSONObject) = LiveServiceProfile(
            id = json.getString("id"), name = json.getString("name"), endpoint = json.getString("endpoint"),
            modelID = json.getString("modelID"), protocolID = json.getString("protocolID"), version = json.getString("version"),
            inputFormat = json.optString("inputFormat", "pcm"), turnDetection = json.optString("turnDetection", "server_vad"),
            threshold = json.optDouble("threshold", 0.5), silenceMS = json.optInt("silenceMS", 1000),
            sourceLanguage = json.optString("sourceLanguage", ""),
            appKey = json.optString("appKey", ""),
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
