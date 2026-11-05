package com.localrecorder.shengjian

import android.content.Context
import com.localrecorder.live.LiveTranslateConfig
import org.json.JSONObject

/** Android-only behaviour, kept apart from the configuration shared with macOS. */
data class AppOptions(
    val autoReconnect: Boolean = true,
    val bluetoothMicrophone: Boolean = false,
)

/** Non-secret settings; the LiveTranslate JSON matches the macOS `livetranslate.configuration.v1` value. */
class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    fun load(): LiveTranslateConfig = LiveTranslateConfig.fromJson(prefs.getString(KEY, null))

    /** Validates and normalizes before saving; throws LiveTranslateException on invalid input. */
    fun save(config: LiveTranslateConfig, allowLocalhost: Boolean = false): LiveTranslateConfig {
        val normalized = config.normalized(allowLocalhost)
        prefs.edit().putString(KEY, normalized.toJson()).apply()
        return normalized
    }

    fun loadOptions(): AppOptions = try {
        val json = JSONObject(prefs.getString(OPTIONS_KEY, null) ?: "{}")
        AppOptions(
            autoReconnect = json.optBoolean("autoReconnect", true),
            bluetoothMicrophone = json.optBoolean("bluetoothMicrophone", false),
        )
    } catch (_: Exception) {
        AppOptions()
    }

    fun saveOptions(options: AppOptions) {
        val json = JSONObject()
            .put("autoReconnect", options.autoReconnect)
            .put("bluetoothMicrophone", options.bluetoothMicrophone)
        prefs.edit().putString(OPTIONS_KEY, json.toString()).apply()
    }

    private companion object {
        const val KEY = "livetranslate.configuration.v1"
        const val OPTIONS_KEY = "android.options.v1"
    }
}
