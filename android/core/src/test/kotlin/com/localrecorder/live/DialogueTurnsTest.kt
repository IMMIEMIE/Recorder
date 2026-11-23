package com.localrecorder.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DialogueTurnsTest {
    @Test
    fun pairsNearbyStartsWithoutStealingTheNextTurnAndKeepsTheSurvivingLane() {
        val left = listOf(
            DialogueUtterance(930, "短句", "短句", "zh"),
            DialogueUtterance(1000, "你好", "你好", "zh"),
            DialogueUtterance(5000, "42", "四十二", null),
        )
        val right = listOf(
            DialogueUtterance(4020, "こんにちは", "こんにちは", "ja"),
            DialogueUtterance(1010, "您好", "こんにちは", "zh"),
            DialogueUtterance(5050, "42", "四十二", null),
        )
        val turns = DialogueTurns.align(left, right, "zh", "ja")
        assertEquals(listOf(930L, 1000L, 4020L, 5000L), turns.map { it.startMs })
        assertEquals(listOf("A", "A", "B", "unknown"), turns.map { it.speaker })
        assertEquals(listOf("", "こんにちは", "", ""), turns.map { it.translation })
        assertEquals(listOf("短句", "你好", "こんにちは", "42"), turns.map { it.source })
        val disputed = DialogueTurns.align(left.take(1), listOf(right[1].copy(sourceLanguage = "ja")), "zh", "ja").single()
        assertEquals("unknown", disputed.speaker)
        val swapped = DialogueTurns.align(right, left, "ja", "zh")
        assertEquals(listOf("B", "B", "A", "unknown"), swapped.map { it.speaker })
        assertEquals(turns.map { it.translation }, swapped.map { it.translation })
    }

    @Test
    fun scriptDetectionOnlyPicksAnUnambiguousSelectedLanguage() {
        assertEquals("zh", DialogueTurns.scriptLanguage("下午好", "en", "zh"))
        assertEquals("ja", DialogueTurns.scriptLanguage("今日は雨です。", "zh", "ja"))
        assertEquals("en", DialogueTurns.scriptLanguage("Hello!", "en", "zh"))
        assertNull(DialogueTurns.scriptLanguage("東京", "zh", "ja"))
        assertNull(DialogueTurns.scriptLanguage("Bonjour", "fr", "en"))
        assertNull(DialogueTurns.scriptLanguage("42", "en", "zh"))
    }
}
