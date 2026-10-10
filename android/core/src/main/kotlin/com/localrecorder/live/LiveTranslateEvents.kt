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

    fun apply(event: JSONObject) {
        val eventId = event.optStringOrNull("event_id")
        if (eventId != null && !seenEvents.add(eventId)) return
        val type = event.optString("type")
        if (event.optStringOrNull("item_id") in retired) return
        if (type == "conversation.item.created") {
            val item = event.optJSONObject("item")
            val output = item?.optStringOrNull("id")
            val source = event.optStringOrNull("previous_item_id")
            if (item?.optString("role") == "assistant" && output != null && source != null && source !in retired) {
                val row = ensure(source)
                if (output !in row.outputs) row.outputs.add(output)
            }
        }
        val id = event.optStringOrNull("item_id") ?: return
        when (type) {
            "input_audio_buffer.speech_started" ->
                ensure(id).seconds = event.optInt("audio_start_ms", 0) / 1000.0
            "conversation.item.input_audio_transcription.delta" -> {
                val row = ensure(id)
                if (!row.source.done) row.source = Part(row.source.text + event.optString("delta"))
            }
            "conversation.item.input_audio_transcription.completed" ->
                ensure(id).source = Part(event.optString("transcript"), done = true)
            "response.text.delta", "response.audio_transcript.delta" -> {
                val part = outputMap[id] ?: Part()
                outputMap[id] = if (part.done) part else Part(part.text + event.optString("delta"))
            }
            "response.text.done", "response.audio_transcript.done" -> {
                val text = event.optStringOrNull("text") ?: event.optStringOrNull("transcript") ?: ""
                outputMap[id] = Part(text, done = true)
            }
        }
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
