package com.localrecorder.shengjian

import android.content.Context
import com.localrecorder.live.LiveTranslateConfig

/** Non-secret settings; the JSON matches the macOS `livetranslate.configuration.v1` value. */
class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    fun load(): LiveTranslateConfig = LiveTranslateConfig.fromJson(prefs.getString(KEY, null))

    /** Validates and normalizes before saving; throws LiveTranslateException on invalid input. */
    fun save(config: LiveTranslateConfig): LiveTranslateConfig {
        val normalized = config.normalized()
        prefs.edit().putString(KEY, normalized.toJson()).apply()
        return normalized
    }

    private companion object {
        const val KEY = "livetranslate.configuration.v1"
    }
}
