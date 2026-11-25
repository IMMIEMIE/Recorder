package com.localrecorder.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InterfaceLanguageTest {
    @Test
    fun supportedLanguagesAndEndonymsMatchSpec() {
        assertEquals(9, InterfaceLanguage.SUPPORTED.size)
        assertNull(InterfaceLanguage.SYSTEM.nativeName)
        assertEquals("简体中文", InterfaceLanguage.ZH_HANS.nativeName)
        assertEquals("English", InterfaceLanguage.EN.nativeName)
        assertEquals("繁體中文", InterfaceLanguage.ZH_HANT.nativeName)
        assertEquals("日本語", InterfaceLanguage.JA.nativeName)
        assertEquals("한국어", InterfaceLanguage.KO.nativeName)
        assertEquals("Español", InterfaceLanguage.ES.nativeName)
        assertEquals("Français", InterfaceLanguage.FR.nativeName)
        assertEquals("Deutsch", InterfaceLanguage.DE.nativeName)
        assertEquals("தமிழ்", InterfaceLanguage.TA.nativeName)
        assertEquals("interface.language", InterfaceLanguage.PREFERENCE_KEY)
    }

    @Test
    fun distinguishesSimplifiedAndTraditionalChinese() {
        for (tag in listOf("zh-Hant", "zh-Hant-TW", "zh-Hant-HK", "zh-TW", "zh-HK", "zh-MO", "zh_TW")) {
            assertEquals("Expected zh-Hant for $tag", InterfaceLanguage.ZH_HANT, InterfaceLanguage.matchTag(tag))
        }
        for (tag in listOf("zh-Hans", "zh-Hans-CN", "zh-Hans-SG", "zh-CN", "zh-SG", "zh", "zh_CN")) {
            assertEquals("Expected zh-Hans for $tag", InterfaceLanguage.ZH_HANS, InterfaceLanguage.matchTag(tag))
        }
    }

    @Test
    fun matchesPreferredOrderAndFallsBackToEnglish() {
        assertEquals("fr", InterfaceLanguage.resolveTag(InterfaceLanguage.SYSTEM, listOf("fr-FR", "zh-CN", "en-GB")))
        assertEquals("de", InterfaceLanguage.resolveTag(InterfaceLanguage.SYSTEM, listOf("ar-SA", "de-DE", "zh-CN")))
        assertEquals("ja", InterfaceLanguage.resolveTag(InterfaceLanguage.SYSTEM, listOf("ja-JP")))
        assertEquals("ko", InterfaceLanguage.resolveTag(InterfaceLanguage.SYSTEM, listOf("ko-KR")))
        assertEquals("es", InterfaceLanguage.resolveTag(InterfaceLanguage.SYSTEM, listOf("es-419")))
        assertEquals("ta", InterfaceLanguage.resolveTag(InterfaceLanguage.SYSTEM, listOf("ta-IN")))
        assertEquals("en", InterfaceLanguage.resolveTag(InterfaceLanguage.SYSTEM, listOf("ar-SA", "vi-VN")))
        assertEquals("en", InterfaceLanguage.resolveTag(InterfaceLanguage.SYSTEM, emptyList()))

        assertEquals("ta", InterfaceLanguage.resolveTag(InterfaceLanguage.TA, listOf("zh-CN")))
        assertEquals("zh-Hant", InterfaceLanguage.resolveTag(InterfaceLanguage.ZH_HANT, listOf("en-US")))
    }

    @Test
    fun parsesPersistedAndAppLocaleTagsSafely() {
        assertEquals(InterfaceLanguage.SYSTEM, InterfaceLanguage.of(null))
        assertEquals(InterfaceLanguage.SYSTEM, InterfaceLanguage.of(""))
        assertEquals(InterfaceLanguage.SYSTEM, InterfaceLanguage.of("unknown"))
        assertEquals(InterfaceLanguage.ZH_HANT, InterfaceLanguage.of("zh-Hant"))
        assertEquals(InterfaceLanguage.TA, InterfaceLanguage.of("ta"))

        assertEquals(InterfaceLanguage.SYSTEM, InterfaceLanguage.fromAppLocaleTag(null))
        assertEquals(InterfaceLanguage.SYSTEM, InterfaceLanguage.fromAppLocaleTag(""))
        assertEquals(InterfaceLanguage.ZH_HANT, InterfaceLanguage.fromAppLocaleTag("zh-TW"))
        assertEquals(InterfaceLanguage.ZH_HANS, InterfaceLanguage.fromAppLocaleTag("zh-CN"))
        assertEquals(InterfaceLanguage.SYSTEM, InterfaceLanguage.fromAppLocaleTag("vi-VN"))
    }

    @Test
    fun validationAndCausesProduceStructuredLiveMessages() {
        val emptyName = runCatching { LiveServiceProfile(name = "").validate() }.exceptionOrNull()
        assertTrue(emptyName is LiveTranslateException)
        assertEquals(LiveMessage.InvalidProfileNameOrModel, (emptyName as LiveTranslateException).liveMessage)

        val badProtocol = runCatching { LiveServiceProfile(protocolID = "unknown").validate() }.exceptionOrNull()
        assertTrue(badProtocol is LiveTranslateException)
        assertEquals(LiveMessage.UnsupportedProtocol, (badProtocol as LiveTranslateException).liveMessage)

        val badTurn = runCatching { LiveServiceProfile(turnDetection = "invalid").validate() }.exceptionOrNull()
        assertTrue(badTurn is LiveTranslateException)
        assertEquals(LiveMessage.InvalidTurnDetection, (badTurn as LiveTranslateException).liveMessage)

        val badConfig = runCatching { LiveTranslateConfig(endpoint = "http://example.com").url() }.exceptionOrNull()
        assertTrue(badConfig is LiveTranslateException)
        assertEquals(LiveMessage.InvalidEndpointOrLanguage, (badConfig as LiveTranslateException).liveMessage)

        val cause = EndCause(
            detail = LiveMessage.CauseUploadStalled(15).defaultText,
            detailMessage = LiveMessage.CauseUploadStalled(15),
            errorMessage = LiveMessage.NetworkUnavailableStopped,
        )
        assertEquals(LiveMessage.CauseUploadStalled(15), cause.detailMessage)
        assertEquals(LiveMessage.NetworkUnavailableStopped, cause.errorMessage)
    }
}
