package com.localrecorder.live

import kotlin.math.abs

/** A pair of lanes can use unrelated IDs for the same microphone samples. Keep the UI/persistence
 * key stable when the other lane, a final translation or a language classification arrives late. */
internal class DialogueTranscript(
    private val languageA: String,
    private val languageB: String,
    private val identify: (String, String, String, (String?) -> Unit) -> Unit,
    private val now: () -> Long,
    private val changed: () -> Unit,
) {
    private class Turn(val key: String, val at: Long) {
        val sides = arrayOfNulls<SubtitleRow>(2)
        var display: SubtitleRow? = null
    }
    private data class Detection(var ready: Boolean = false, var language: String? = null)
    private val detections = HashMap<String, Detection>()
    private val byId = arrayOf(HashMap<String, Turn>(), HashMap<String, Turn>())
    private val turns = mutableListOf<Turn>()
    private var sequence = 0
    private var closed = false
    var trimmed = false
        private set

    val identifying get() = detections.values.any { !it.ready }

    fun observe(lane: Int, row: SubtitleRow) {
        if (row.marker.isNotEmpty() || (row.source.isBlank() && row.audioStartMs == null)) return
        val start = row.audioStartMs ?: now()
        val turn = byId[lane][row.key] ?: run {
            val match = turns.asReversed().asSequence()
                .filter { it.sides[lane] == null && abs(it.at - start) <= DialogueTurns.ALIGNMENT_WINDOW_MS }
                .minByOrNull { abs(it.at - start) }
            (match ?: Turn("turn:${sequence++}", start).also { fresh ->
                val position = turns.binarySearchBy(start) { it.at }
                turns.add(if (position >= 0) position + 1 else -position - 1, fresh)
            }).also { byId[lane][row.key] = it }
        }
        if (row == turn.sides[lane]) return
        turn.sides[lane] = row
        turn.display = null
        if (row.sourceDone && row.source.isNotBlank() && row.source !in detections) {
            val detection = Detection()
            detections[row.source] = detection
            identify(row.source, languageA, languageB) { result ->
                if (!closed && !detection.ready) {
                    detection.language = result
                    detection.ready = true
                    turns.filter { t -> t.sides.any { it?.source == row.source } }.forEach { it.display = null }
                    changed()
                }
            }
        }
        if (turns.size > LiveSession.MAX_ROWS) {
            val oldest = turns.removeAt(0)
            oldest.sides.forEachIndexed { index, old -> if (old != null) byId[index].remove(old.key) }
            val visible = turns.flatMap { t -> t.sides.mapNotNull { it?.source } }.toHashSet()
            detections.keys.retainAll(visible)
            trimmed = true
        }
    }

    private fun language(row: SubtitleRow?): String? {
        if (row == null) return null
        val detection = detections[row.source]
        return if (detection?.ready == true) detection.language
        else DialogueTurns.scriptLanguage(row.source, languageA, languageB)
    }

    private fun resolvedSpeaker(turn: Turn): String? =
        DialogueTurns.speaker(language(turn.sides[0]), language(turn.sides[1]), languageA, languageB)

    /** Null defers routing; false discards a self-translation/ambiguous utterance permanently. */
    fun shouldPlay(lane: Int, key: String, otherHealthy: Boolean): Boolean? {
        val turn = byId[lane][key] ?: return null
        val row = turn.sides[lane] ?: return null
        if (otherHealthy && turn.sides[1 - lane]?.source.isNullOrBlank()) return null
        if (!row.sourceDone || detections[row.source]?.ready != true) return null
        if (turn.sides.filterNotNull().any { it.source.isNotBlank() && (!it.sourceDone || detections[it.source]?.ready != true) }) return null
        return when (resolvedSpeaker(turn)) { "A" -> lane == 1; "B" -> lane == 0; else -> false }
    }

    fun rows(): List<SubtitleRow> = turns.map { turn -> turn.display ?: display(turn).also { turn.display = it } }

    private fun display(turn: Turn): SubtitleRow {
        val speaker = resolvedSpeaker(turn)
        val ownIndex = if (speaker == "B") 1 else 0
        val own = turn.sides[ownIndex]?.takeIf { it.source.isNotBlank() } ?: turn.sides[1 - ownIndex]
        val target = if (speaker == null) null else turn.sides[1 - ownIndex]
        return SubtitleRow(
            turn.key, own?.source.orEmpty(), own?.sourceDone == true, target?.translation.orEmpty(),
            target?.translationDone == true, speaker = speaker ?: "unknown",
            sourceLanguage = when (speaker) { "A" -> languageA; "B" -> languageB; else -> language(own) },
            targetLanguage = when (speaker) { "A" -> languageB; "B" -> languageA; else -> null },
            audioStartMs = turn.at,
        )
    }

    /** The network can finish before a slow device classifier. Settle based on script on teardown. */
    fun settle() {
        closed = true
        turns.forEach { it.display = null }
        detections.forEach { (text, value) ->
            if (!value.ready) {
                value.language = DialogueTurns.scriptLanguage(text, languageA, languageB)
                value.ready = true
            }
        }
    }
}
