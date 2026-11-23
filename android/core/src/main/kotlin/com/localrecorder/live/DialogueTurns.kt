package com.localrecorder.live

/** A finalized utterance from one lane. startMs is on the shared capture timeline, including after reconnect. */
data class DialogueUtterance(val startMs: Long, val source: String, val translation: String, val sourceLanguage: String?)

data class DialogueTurn(
    val startMs: Long,
    val speaker: String, // A, B, or unknown. The receiving panel is the other side.
    val source: String,
    val sourceLanguage: String?,
    val translation: String,
    val targetLanguage: String?,
)

/** Reconciles a settled window for one fixed pair of languages. Inputs may arrive in any order. */
object DialogueTurns {
    const val ALIGNMENT_WINDOW_MS = 250L

    internal fun speaker(a: String?, b: String?, languageA: String, languageB: String): String? =
        when (listOfNotNull(a, b).distinct().singleOrNull()) {
            languageA -> "A"
            languageB -> "B"
            else -> null
        }

    fun align(a: List<DialogueUtterance>, b: List<DialogueUtterance>, languageA: String, languageB: String): List<DialogueTurn> {
        require(languageA != languageB)
        val left = a.sortedBy { it.startMs }
        val right = b.sortedBy { it.startMs }
        var i = 0
        var j = 0
        return buildList {
            while (i < left.size || j < right.size) {
                val x = left.getOrNull(i)
                val y = right.getOrNull(j)
                val takeLeft = y == null || (x != null && x.startMs <= y.startMs)
                val first = if (takeLeft) x!! else y!!
                val other = if (takeLeft) y else x
                val next = if (takeLeft) left.getOrNull(i + 1) else right.getOrNull(j + 1)
                val distance = other?.let { it.startMs - first.startMs }
                val match = distance != null && distance <= ALIGNMENT_WINDOW_MS &&
                    (next == null || kotlin.math.abs(next.startMs - other.startMs) >= distance)
                val fromA = if (takeLeft || match) x else null
                val fromB = if (!takeLeft || match) y else null
                val languages = listOfNotNull(fromA?.sourceLanguage, fromB?.sourceLanguage).distinct()
                val sourceLanguage = languages.singleOrNull()
                val speaker = speaker(fromA?.sourceLanguage, fromB?.sourceLanguage, languageA, languageB) ?: "unknown"
                val own = if (speaker == "B") fromB else fromA
                val source = own?.source?.takeIf { it.isNotBlank() }
                    ?: listOfNotNull(fromA, fromB).firstOrNull { it.source.isNotBlank() }?.source.orEmpty()
                val receiving = when (speaker) { "A" -> fromB; "B" -> fromA; else -> null }
                val target = when (speaker) { "A" -> languageB; "B" -> languageA; else -> null }
                add(DialogueTurn(first.startMs, speaker, source, sourceLanguage, receiving?.translation.orEmpty(), target))
                if (fromA != null) i++
                if (fromB != null) j++
            }
        }
    }

    /** Pre-29 fallback. Only infer a script when it distinguishes the two selected languages. */
    fun scriptLanguage(text: String, languageA: String, languageB: String): String? {
        val scripts = text.codePoints().iterator().asSequence().filter(Character::isLetter)
            .map(Character.UnicodeScript::of).toSet()
        if (scripts.isEmpty()) return null
        val possible = mapOf(
            "zh" to setOf(Character.UnicodeScript.HAN),
            "ja" to setOf(Character.UnicodeScript.HAN, Character.UnicodeScript.HIRAGANA, Character.UnicodeScript.KATAKANA),
            "ko" to setOf(Character.UnicodeScript.HANGUL, Character.UnicodeScript.HAN),
            "ru" to setOf(Character.UnicodeScript.CYRILLIC),
        )
        val latin = setOf(Character.UnicodeScript.LATIN)
        return listOf(languageA, languageB).filter { language ->
            val accepted = possible[language] ?: latin
            scripts.all { it in accepted }
        }.singleOrNull()
    }
}
