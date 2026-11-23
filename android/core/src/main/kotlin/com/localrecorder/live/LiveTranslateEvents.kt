package com.localrecorder.live

import org.json.JSONObject

/** Source and translation arrive independently. Join by IDs, never by text or arrival order. */
class LiveTranslateEvents {
    data class Part(val text: String = "", val done: Boolean = false)

    data class Row(
        val id: String,
        var source: Part = Part(),
        var seconds: Double = 0.0,
        val outputs: MutableList<String> = mutableListOf(),
        var audioStartMs: Long? = null,
        var targetLanguage: String? = null,
        var languageSwitch: String? = null,
    )

    private val rowMap = LinkedHashMap<String, Row>()
    private val outputMap = HashMap<String, Part>()
    private val seenEvents = RecentIds()
    private val retired = HashSet<String>()

    val rows: Map<String, Row> get() = rowMap
    val order: List<String> get() = rowMap.keys.toList()
    val outputs: Map<String, Part> get() = outputMap

    private fun ensure(id: String): Row = rowMap.getOrPut(id) { Row(id) }

    /**
     * Forgets a row and its translations once the caller has copied them out (long sessions).
     * Late events for the retired IDs are ignored instead of recreating the row.
     */
    fun retire(id: String) {
        val row = rowMap.remove(id) ?: return
        retired.add(id)
        for (output in row.outputs) {
            outputMap.remove(output)
            retired.add(output)
        }
    }

    fun apply(event: LiveSessionEvent) {
        if (event.eventID?.let { !seenEvents.add(it) } == true) return
        when (event) {
            is LiveSessionEvent.Link -> if (event.source !in retired && event.output !in retired) {
                val row = ensure(event.source)
                if (event.output !in row.outputs) row.outputs.add(event.output)
            }
            is LiveSessionEvent.SpeechStart -> if (event.source !in retired) ensure(event.source).seconds = event.milliseconds / 1000.0
            is LiveSessionEvent.Text -> if (event.item !in retired) {
                if (event.source) {
                    val row = ensure(event.item)
                    row.source = row.source.updated(event)
                } else {
                    outputMap[event.item] = (outputMap[event.item] ?: Part()).updated(event)
                }
            }
            is LiveSessionEvent.Audio, is LiveSessionEvent.SpeechEnd -> Unit
        }
    }

    private fun Part.updated(event: LiveSessionEvent.Text) = when {
        event.final -> Part(event.value, done = true)
        done -> this
        else -> Part(text + event.value)
    }

    fun translation(row: Row): Part = Part(
        text = row.outputs.mapNotNull { outputMap[it]?.text }.joinToString(" "),
        done = row.outputs.isNotEmpty() && row.outputs.all { outputMap[it]?.done == true },
    )

    val unmatchedOutputs: List<Pair<String, Part>>
        get() {
            val matched = rowMap.values.flatMap { it.outputs }.toSet()
            return outputMap.filter { it.key !in matched && it.value.text.isNotEmpty() }
                .toSortedMap().map { it.key to it.value }
        }

    val hasUnmatchedOutput: Boolean get() = unmatchedOutputs.isNotEmpty()
}

/** Duplicates arrive close together, so remembering the most recent event IDs keeps hours-long sessions bounded. */
internal class RecentIds(private val limit: Int = 4096) {
    private val ids = object : LinkedHashMap<String, Unit>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Unit>?): Boolean = size > limit
    }

    /** False when the ID was seen recently. */
    fun add(id: String): Boolean = ids.put(id, Unit) == null
}

internal fun JSONObject.optStringOrNull(key: String): String? =
    if (has(key) && !isNull(key)) opt(key) as? String else null
