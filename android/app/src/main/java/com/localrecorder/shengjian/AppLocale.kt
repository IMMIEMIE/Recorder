package com.localrecorder.shengjian

import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Build
import android.os.LocaleList
import androidx.activity.ComponentActivity
import com.localrecorder.live.InterfaceLanguage
import java.util.Locale

/**
 * In-app interface language manager compatible with Android 8–12 (Configuration context wrapping)
 * and Android 13+ (native LocaleManager per-app locales, synced bidirectionally with System Settings).
 */
internal object AppLocale {
    fun currentLanguage(context: Context): InterfaceLanguage {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val locales = context.getSystemService(LocaleManager::class.java)?.applicationLocales
            if (locales != null) {
                val synced = if (locales.isEmpty) InterfaceLanguage.SYSTEM
                else InterfaceLanguage.fromAppLocaleTag(locales[0]?.toLanguageTag())
                SettingsStore(context).saveInterfaceLanguage(synced)
                return synced
            }
        }
        return SettingsStore(context).loadInterfaceLanguage()
    }

    fun applyLanguage(activity: ComponentActivity, language: InterfaceLanguage) {
        SettingsStore(activity).saveInterfaceLanguage(language)
        val controller = (activity.application as? ShengjianApp)?.controller
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val locales = if (language == InterfaceLanguage.SYSTEM) LocaleList.getEmptyLocaleList()
            else LocaleList.forLanguageTags(language.tag)
            activity.getSystemService(LocaleManager::class.java)?.applicationLocales = locales
            controller?.onInterfaceLanguageChanged()
        } else {
            controller?.onInterfaceLanguageChanged()
            activity.recreate()
        }
    }

    /** Wraps Activity and Service base contexts on API 26–32; no-op on API 33+ where LocaleManager manages locales. */
    fun wrapContext(base: Context): Context {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return base
        val selection = try {
            val prefs = base.getSharedPreferences("settings", Context.MODE_PRIVATE)
            InterfaceLanguage.of(prefs.getString(InterfaceLanguage.PREFERENCE_KEY, null))
        } catch (_: Exception) {
            InterfaceLanguage.SYSTEM
        }
        val tag = InterfaceLanguage.resolveTag(selection, systemPreferredTags())
        val locale = Locale.forLanguageTag(tag)
        val config = Configuration(base.resources.configuration)
        config.setLocales(LocaleList(locale))
        return base.createConfigurationContext(config)
    }

    /** Returns a context whose Resources reflect the current interface language (for Application/Service helpers). */
    fun localizedContext(base: Context): Context = wrapContext(base)

    private fun systemPreferredTags(): List<String> {
        val locales = Resources.getSystem().configuration.locales
        return List(locales.size()) { index -> locales[index].toLanguageTag() }
    }
}
