package com.localrecorder.live

import org.junit.Assert.assertEquals
import org.junit.Test

class SubtitleTailWindowTest {
    private fun fixedWidthWrap(width: Int): (String) -> List<String> = { text ->
        text.split('\n').flatMap { paragraph ->
            if (paragraph.isEmpty()) {
                listOf("")
            } else {
                val out = mutableListOf<String>()
                var start = 0
                while (start < paragraph.length) {
                    val end = minOf(start + width, paragraph.length)
                    out += paragraph.substring(start, end)
                    start = end
                }
                out
            }
        }
    }

    @Test
    fun returnsEmptyForBlankInputOrNonPositiveLimit() {
        assertEquals("", SubtitleTailWindow.tail("   \n\t ", 3, fixedWidthWrap(10)))
        assertEquals("", SubtitleTailWindow.tail("hello world", 0, fixedWidthWrap(10)))
        assertEquals("", SubtitleTailWindow.tail("hello world", -2, fixedWidthWrap(10)))
    }

    @Test
    fun keepsAllLinesWhenWithinLimit() {
        val text = "Depending on the weather"
        val result = SubtitleTailWindow.tail(text, 3, fixedWidthWrap(12))
        assertEquals("Depending on\nthe weather", result)
    }

    @Test
    fun keepsNewestTrailingLinesWhenLongSentenceOverflows() {
        val text = "根据天气状况，宝可梦可以获得额外的属性抗性。还能获得新的能力和特殊招式，能够同时伤害多个对手。我们还首次看到了全新机制"
        val lines = SubtitleTailWindow.tailLines(text, 3, fixedWidthWrap(14))
        assertEquals(3, lines.size)
        assertEquals(
            "能力和特殊招式，能够同时伤害\n多个对手。我们还首次看到了全\n新机制",
            lines.joinToString("\n"),
        )
    }

    @Test
    fun rollingStreamAlwaysRevealsLatestAppendedWords() {
        fun wordWrap(width: Int): (String) -> List<String> = { text ->
            val out = mutableListOf<String>()
            val current = StringBuilder()
            for (word in text.split(' ')) {
                if (current.isEmpty()) {
                    current.append(word)
                } else if (current.length + 1 + word.length <= width) {
                    current.append(' ').append(word)
                } else {
                    out += current.toString()
                    current.clear()
                    current.append(word)
                }
            }
            if (current.isNotEmpty()) out += current.toString()
            out
        }

        val prefix = "Depending on the weather conditions, the Pokémon could gain additional type resistances. "
        val step1 = SubtitleTailWindow.tail(prefix + "We also saw", 2, wordWrap(28))
        val step2 = SubtitleTailWindow.tail(prefix + "We also saw a brand new move!", 2, wordWrap(28))
        assertEquals(true, step1.replace('\n', ' ').endsWith("We also saw"))
        assertEquals(true, step2.replace('\n', ' ').endsWith("a brand new move!"))
        assertEquals(2, step1.lines().size)
        assertEquals(2, step2.lines().size)
    }

    @Test
    fun filtersBlankWrappedLinesSoTrailingNewlinesDoNotConsumeCapacity() {
        val raw = "line one\n\nline two\n   \nline three\n\n"
        val result = SubtitleTailWindow.tail(raw, 2) { it.split('\n') }
        assertEquals("line two\nline three", result)
    }

    @Test
    fun fallsBackToTrimmedTextWhenWrapperProducesNoNonBlankLines() {
        val result = SubtitleTailWindow.tail("  hello  ", 2) { emptyList() }
        assertEquals("hello", result)
    }
}
