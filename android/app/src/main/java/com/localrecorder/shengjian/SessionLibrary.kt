package com.localrecorder.shengjian

import android.os.Handler
import com.localrecorder.live.SubtitleRow
import com.localrecorder.sessions.SessionExport
import com.localrecorder.sessions.SessionRecord
import com.localrecorder.sessions.SessionStore
import com.localrecorder.sessions.SessionSummary
import java.io.File
import java.time.ZoneId
import java.util.concurrent.Executors

/**
 * Saved sessions for the UI. Called on the main thread; file work runs in order on one I/O thread, so a
 * load queued after a save sees it. Records that may not be written (the "保存会话记录" switch is off)
 * live in [memory] for this run only and take precedence over the file of the same ID.
 */
class SessionLibrary(directory: File, private val main: Handler, private val onError: (String) -> Unit) {
    private val store = SessionStore(directory)
    private val io = Executors.newSingleThreadExecutor { Thread(it, "sessions-io") }
    private val disk = HashMap<String, SessionSummary>()
    private val memory = HashMap<String, SessionRecord>()

    /** Deleted before the initial listing arrived; that listing may still contain them. */
    private val deletedEarly = HashSet<String>()
    private var clearedEarly = false
    private var listed = false

    /** Called on the main thread whenever [summaries] may have changed. */
    var onChange: () -> Unit = {}

    init {
        io.execute {
            val found = store.list().map { it.summary }
            main.post {
                // Sessions saved before the list arrived are newer than what was read.
                if (!clearedEarly) for (summary in found) if (summary.id !in deletedEarly) disk.putIfAbsent(summary.id, summary)
                deletedEarly.clear()
                listed = true
                onChange()
            }
        }
    }

    /** Most recently updated first. */
    fun summaries(): List<SessionSummary> {
        val merged = HashMap(disk)
        for (record in memory.values) merged[record.id] = record.summary
        return merged.values.sortedWith(compareByDescending<SessionSummary> { it.updatedAtMs }.thenBy { it.id })
    }

    fun save(record: SessionRecord, persist: Boolean) {
        if (persist) {
            memory.remove(record.id)
            disk[record.id] = record.summary
            io.execute {
                try {
                    store.save(record)
                } catch (e: Exception) {
                    main.post { onError("会话记录保存失败：${e.message ?: e.javaClass.simpleName}") }
                }
            }
        } else {
            memory[record.id] = record
        }
        onChange()
    }

    /** [done] runs on the main thread with null when the session is gone or unreadable. */
    fun load(id: String, done: (SessionRecord?) -> Unit) {
        memory[id]?.let {
            done(it)
            return
        }
        io.execute {
            val record = store.load(id)
            main.post { done(record) }
        }
    }

    fun rename(id: String, title: String, zone: ZoneId, persist: Boolean, done: (SessionRecord?) -> Unit) {
        load(id) { record ->
            val renamed = record?.let { SessionStore.renamed(it, title, zone) }
            if (renamed != null) save(renamed, persist)
            done(renamed)
        }
    }

    fun delete(id: String) {
        if (!listed) deletedEarly += id
        memory.remove(id)
        disk.remove(id)
        io.execute { store.delete(id) }
        onChange()
    }

    fun deleteAll() {
        if (!listed) clearedEarly = true
        memory.clear()
        disk.clear()
        io.execute { store.deleteAll() }
        onChange()
    }

    /** Other file work (writing an export) on the same thread. */
    fun background(block: () -> Unit) = io.execute { block() }
}

/** Rows of a saved session for the subtitle list: breaks and "continue recording" become marker rows. */
fun SessionRecord.subtitleRows(zone: ZoneId): List<SubtitleRow> {
    val out = ArrayList<SubtitleRow>(rows.size + segments.size)
    var previous: Int? = null
    rows.forEachIndexed { index, row ->
        if (previous != null && row.segment != previous) {
            out += marker("seg:$index", SessionExport.continuedMarker(segments[row.segment].startedAtMs, zone))
        }
        previous = row.segment
        row.switchMarker?.let { out += marker("lang:$index", it) }
        when {
            row.isBreak -> out += marker("b:$index", SessionExport.BREAK_MARKER)
            row.source.isNotBlank() || row.translation.isNotBlank() -> {
                val source = row.source.trim()
                val translation = row.translation.trim()
                out += if (source.isEmpty()) SubtitleRow("r:$index", "", true, row.speakerPrefix + translation, true)
                    else SubtitleRow("r:$index", row.speakerPrefix + source, true, translation, true)
            }
        }
    }
    return out
}

private fun marker(key: String, text: String) = SubtitleRow(key, "", true, "", true, text)
