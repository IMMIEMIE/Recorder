package com.localrecorder.shengjian

import android.app.LocaleManager
import android.content.Context
import android.content.ContextWrapper
import android.content.res.AssetManager
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Build
import android.os.LocaleList
import androidx.activity.ComponentActivity
import com.localrecorder.live.InterfaceLanguage
import java.util.Locale
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * In-app interface language manager compatible with Android 8–12 (in-place Compose Configuration
 * context wrapping) and Android 13+ (native LocaleManager per-app locales, synced bidirectionally
 * with System Settings without Activity recreation).
 */
internal object AppLocale {
    private val _language = MutableStateFlow(InterfaceLanguage.SYSTEM)
    val language: StateFlow<InterfaceLanguage> = _language.asStateFlow()

    /** Reads the active language without performing any disk writes (safe during composition). */
    fun currentLanguage(context: Context): InterfaceLanguage {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val locales = context.getSystemService(LocaleManager::class.java)?.applicationLocales
            if (locales != null) {
                return if (locales.isEmpty) InterfaceLanguage.SYSTEM
                else InterfaceLanguage.fromAppLocaleTag(locales[0]?.toLanguageTag())
            }
        }
        return SettingsStore(context).loadInterfaceLanguage()
    }

    /**
     * Synchronizes in-memory state (and persisted preference on API 33+ if changed in System Settings).
     * Returns true if the active language changed compared to the previously observed value.
     */
    fun syncFromSystem(context: Context): Boolean {
        val current = currentLanguage(context)
        val store = SettingsStore(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && store.loadInterfaceLanguage() != current) {
            store.saveInterfaceLanguage(current)
        }
        val changed = _language.value != current
        _language.value = current
        return changed
    }

    fun applyLanguage(activity: ComponentActivity, language: InterfaceLanguage) {
        val store = SettingsStore(activity)
        if (store.loadInterfaceLanguage() != language) {
            store.saveInterfaceLanguage(language)
        }
        _language.value = language
        val controller = (activity.application as? ShengjianApp)?.controller
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val locales = if (language == InterfaceLanguage.SYSTEM) LocaleList.getEmptyLocaleList()
            else LocaleList.forLanguageTags(language.tag)
            activity.getSystemService(LocaleManager::class.java)?.applicationLocales = locales
            // Refresh immediately in case the resolved locale is unchanged (e.g. SYSTEM <-> matching tag);
            // when the locale changes, MainActivity.onConfigurationChanged refreshes again after resources update.
            controller?.onInterfaceLanguageChanged()
        } else {
            controller?.onInterfaceLanguageChanged()
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
        return base.createConfigurationContext(localizedConfiguration(base.resources.configuration, selection))
    }

    /** Builds a Configuration + Activity-delegating ContextWrapper for in-place Compose locale updates on API 26–32. */
    fun localizedOverlay(activity: ComponentActivity, baseConfig: Configuration, selection: InterfaceLanguage): Pair<Configuration, Context> {
        val config = localizedConfiguration(baseConfig, selection)
        val resContext = activity.createConfigurationContext(config)
        return config to LocalizedContextWrapper(activity, resContext.resources)
    }

    /** Returns a context whose Resources reflect the current interface language (for Application/Service helpers). */
    fun localizedContext(base: Context): Context = wrapContext(base)

    private fun localizedConfiguration(baseConfig: Configuration, selection: InterfaceLanguage): Configuration {
        val tag = InterfaceLanguage.resolveTag(selection, systemPreferredTags())
        val locale = Locale.forLanguageTag(tag)
        return Configuration(baseConfig).apply {
            setLocales(LocaleList(locale))
        }
    }

    private fun systemPreferredTags(): List<String> {
        val locales = Resources.getSystem().configuration.locales
        return List(locales.size()) { index -> locales[index].toLanguageTag() }
    }
}

private class LocalizedContextWrapper(
    base: Context,
    private val localizedResources: Resources,
) : ContextWrapper(base) {
    override fun getResources(): Resources = localizedResources
    override fun getAssets(): AssetManager = localizedResources.assets
}

internal tailrec fun Context.findComponentActivity(): ComponentActivity? = when (this) {
    is ComponentActivity -> this
    is ContextWrapper -> baseContext.findComponentActivity()
    else -> null
}

internal tailrec fun Context.findMainActivity(): MainActivity? = when (this) {
    is MainActivity -> this
    is ContextWrapper -> baseContext.findMainActivity()
    else -> null
}
