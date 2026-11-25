package com.localrecorder.live

/**
 * Supported interface languages (shared tag vocabulary with macOS).
 * Concrete languages always display their fixed native endonym in selectors.
 */
enum class InterfaceLanguage(val tag: String, val nativeName: String?) {
    SYSTEM("system", null),
    ZH_HANS("zh-Hans", "简体中文"),
    EN("en", "English"),
    ZH_HANT("zh-Hant", "繁體中文"),
    JA("ja", "日本語"),
    KO("ko", "한국어"),
    ES("es", "Español"),
    FR("fr", "Français"),
    DE("de", "Deutsch"),
    TA("ta", "தமிழ்");

    companion object {
        const val PREFERENCE_KEY = "interface.language"

        val SUPPORTED: List<InterfaceLanguage> = entries.filter { it != SYSTEM }

        fun of(tag: String?): InterfaceLanguage =
            entries.firstOrNull { it.tag.equals(tag, ignoreCase = true) } ?: SYSTEM

        /** Maps a system or Android per-app BCP 47 tag to a supported language, distinguishing zh-Hans and zh-Hant. */
        fun matchTag(tag: String): InterfaceLanguage? {
            val cleaned = tag.trim().replace('_', '-')
            if (cleaned.isEmpty()) return null
            val parts = cleaned.split('-').filter { it.isNotEmpty() }
            val language = parts.firstOrNull()?.lowercase() ?: return null
            return when (language) {
                "zh" -> {
                    val rest = parts.drop(1)
                    val script = rest.firstOrNull { it.length == 4 }?.lowercase()
                    when (script) {
                        "hant" -> ZH_HANT
                        "hans" -> ZH_HANS
                        else -> {
                            val region = rest.firstOrNull {
                                it.length == 2 || (it.length == 3 && it.all(Char::isDigit))
                            }?.uppercase()
                            if (region in setOf("TW", "HK", "MO")) ZH_HANT else ZH_HANS
                        }
                    }
                }
                "en" -> EN
                "ja" -> JA
                "ko" -> KO
                "es" -> ES
                "fr" -> FR
                "de" -> DE
                "ta" -> TA
                else -> null
            }
        }

        /** Resolves the effective BCP 47 language tag for the selection and preferred system language list. */
        fun resolveTag(selection: InterfaceLanguage, preferredTags: List<String>): String {
            if (selection != SYSTEM) return selection.tag
            for (tag in preferredTags) {
                val matched = matchTag(tag)
                if (matched != null) return matched.tag
            }
            return EN.tag
        }

        fun fromAppLocaleTag(tag: String?): InterfaceLanguage =
            if (tag.isNullOrBlank()) SYSTEM else matchTag(tag) ?: SYSTEM
    }
}
