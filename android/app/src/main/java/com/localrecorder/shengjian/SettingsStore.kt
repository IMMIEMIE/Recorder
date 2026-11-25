package com.localrecorder.shengjian

import android.content.Context
import com.localrecorder.live.InterfaceLanguage
import com.localrecorder.live.LiveMessage
import com.localrecorder.live.LiveTranslateException
import com.localrecorder.live.LiveTranslateConfig
import org.json.JSONObject

/** Android-only behaviour, kept apart from the configuration shared with macOS. */
data class AppOptions(
    val autoReconnect: Boolean = true,
    val bluetoothMicrophone: Boolean = false,
    /** Finalized transcripts are saved under filesDir/sessions (docs/SESSIONS.md); off = memory only. */
    val saveSessions: Boolean = true,
)

/** Non-secret settings; the LiveTranslate JSON matches the macOS `livetranslate.configuration.v1` value. */
class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    fun load(): LiveTranslateConfig = LiveTranslateConfig.fromJson(prefs.getString(KEY, null))

    fun loadDialogueLanguages(): Pair<String, String> {
        val a = prefs.getString("dialogue.languageA", "zh")
        val b = prefs.getString("dialogue.languageB", "en")
        val supported = LiveTranslateConfig.LANGUAGES.map { it.first }
        return if (a != null && b != null && a != b && a in supported && b in supported) a to b else "zh" to "en"
    }

    fun saveDialogueLanguages(a: String, b: String) {
        prefs.edit().putString("dialogue.languageA", a).putString("dialogue.languageB", b).apply()
    }

    /** Validates and normalizes before saving; throws LiveTranslateException on invalid input. */
    fun save(config: LiveTranslateConfig, allowLocalhost: Boolean = false): LiveTranslateConfig {
        val normalized = config.normalized(allowLocalhost)
        // A saved selection must survive an immediate app/process restart.
        if (!prefs.edit().putString(KEY, normalized.toJson()).commit()) {
            throw LiveTranslateException(LiveMessage.SettingsSaveFailed)
        }
        return normalized
    }

    fun loadInterfaceLanguage(): InterfaceLanguage =
        InterfaceLanguage.of(prefs.getString(InterfaceLanguage.PREFERENCE_KEY, null))

    fun saveInterfaceLanguage(language: InterfaceLanguage) {
        prefs.edit().putString(InterfaceLanguage.PREFERENCE_KEY, language.tag).commit()
    }

    fun loadOptions(): AppOptions = try {
        val json = JSONObject(prefs.getString(OPTIONS_KEY, null) ?: "{}")
        AppOptions(
            autoReconnect = json.optBoolean("autoReconnect", true),
            bluetoothMicrophone = json.optBoolean("bluetoothMicrophone", false),
            saveSessions = json.optBoolean("saveSessions", true),
        )
    } catch (_: Exception) {
        AppOptions()
    }

    fun saveOptions(options: AppOptions) {
        val json = JSONObject()
            .put("autoReconnect", options.autoReconnect)
            .put("bluetoothMicrophone", options.bluetoothMicrophone)
            .put("saveSessions", options.saveSessions)
        prefs.edit().putString(OPTIONS_KEY, json.toString()).apply()
    }

    private companion object {
        const val KEY = "livetranslate.configuration.v1"
        const val OPTIONS_KEY = "android.options.v1"
    }
}
