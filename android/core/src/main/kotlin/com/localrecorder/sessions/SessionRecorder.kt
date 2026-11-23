package com.localrecorder.sessions

import com.localrecorder.live.Cancellable
import com.localrecorder.live.SessionSnapshot
import com.localrecorder.live.SessionState
import com.localrecorder.live.SubtitleRow
import java.time.ZoneId

/**
 * Turns the snapshots of one recording into a [SessionRecord]: only finalized text is kept. A row is
 * stored once its source is done (a translation-only row once its connection has ended); its
 * translation is stored once that is done, and a later translation updates the same row in place.
 * Break markers become `break` rows. Changes reach [Sink.save] at most about once a second, and
 * immediately on [flush] and when the recording ends. Call everything on the session thread.
 */
class SessionRecorder(
    private val clock: () -> Long,
    private val schedule: (Long, () -> Unit) -> Cancellable,
    private val zone: ZoneId,
    private val sink: Sink,
) {
    interface Sink {
        /** Persist [record] (or keep it in memory when saving is off). */
        fun save(record: SessionRecord)

        /**
         * The recording ended. [record] is the session as it now stands, or null when a new session ended
         * without any text and was dropped (anything saved for it should go too).
         */
        fun ended(id: String, record: SessionRecord?)
    }

    companion object {
        const val SAVE_DELAY_MS = 1_000L
    }

    private class Seen(val row: SubtitleRow, val atMs: Long)

    /** The session being recorded, including rows not yet handed to the sink; null when not recording. */
    var record: SessionRecord? = null
        private set

    /** The session before this recording (null for a new one). */
    var base: SessionRecord? = null
        private set

    private var segment = 0
    private var segmentStart = 0L
    private var earlier: List<SessionRow> = emptyList()
    private val keys = ArrayList<String>()
    private val rows = ArrayList<SessionRow>()
    private val index = HashMap<String, Int>()
    private val seen = HashMap<String, Seen>()
    private var sawActive = false
    private var dirty = false
    private var pending: Cancellable? = null

    /** Starts a new segment in [existing] (continue recording) or in a new session with [newId]. */
    fun begin(existing: SessionRecord?, newId: String, targetLanguage: String?, mode: String = SessionRecord.MODE_LIVE_TRANSLATE): SessionRecord {
        finish()
        val now = clock()
        val start = existing ?: SessionRecord(newId, "", false, now, now, emptyList(), emptyList()).retitled(zone)
        base = existing
        segment = start.segments.size
        segmentStart = now
        earlier = start.rows
        keys.clear()
        rows.clear()
        index.clear()
        seen.clear()
        sawActive = false
        dirty = false
        val started = start.copy(segments = start.segments + SessionSegment(now, null, targetLanguage, mode))
        record = started
        return started
    }

    fun observe(snapshot: SessionSnapshot) {
        if (record == null) return
        if (snapshot.state != SessionState.IDLE) sawActive = true
        var changed = false
        var anchor = -1
        for (row in snapshot.rows) {
            val previous = seen[row.key]
            if (previous != null && previous.row === row) {
                index[row.key]?.let { anchor = it }
                continue
            }
            val at = previous?.atMs ?: clock()
            seen[row.key] = Seen(row, at)
            val position = index[row.key]
            val stored = stored(row, at, position?.let(rows::get))
            if (position != null) {
                anchor = position
                if (stored != null && stored != rows[position]) {
                    rows[position] = stored
                    changed = true
                }
            } else if (stored != null) {
                // Keep the on-screen order even when an earlier row is finalized after a later one.
                val insertAt = when {
                    anchor >= 0 -> anchor + 1
                    snapshot.trimmed -> rows.size
                    else -> 0
                }
                rows.add(insertAt, stored)
                keys.add(insertAt, row.key)
                if (insertAt == rows.size - 1) index[row.key] = insertAt else reindex()
                anchor = insertAt
                changed = true
            }
        }
        if (changed) {
            record = record?.copy(rows = earlier + rows, updatedAtMs = clock())?.retitled(zone)
            dirty = true
            if (pending == null) pending = schedule(SAVE_DELAY_MS) {
                pending = null
                flush()
            }
        }
        if (sawActive && snapshot.state == SessionState.IDLE) finish()
    }

    /** A blank title restores the automatic one. */
    fun rename(title: String) {
        val current = record ?: return
        record = SessionStore.renamed(current, title, zone)
        dirty = true
        flush()
    }

    /** Hands pending changes to the sink now (stop, app in the background). */
    fun flush() {
        pending?.cancel()
        pending = null
        val current = record ?: return
        // A new session is written only once it has text.
        if (!dirty || (base == null && rows.isEmpty())) return
        dirty = false
        sink.save(current)
    }

    /** Ends the segment; safe to call more than once. */
    fun finish() {
        val current = record ?: return
        pending?.cancel()
        pending = null
        record = null
        val previous = base
        base = null
        val final: SessionRecord? = when {
            rows.isNotEmpty() -> {
                val now = clock()
                val segments = current.segments.toMutableList()
                segments[segments.lastIndex] = segments.last().copy(endedAtMs = now)
                current.copy(segments = segments, updatedAtMs = now)
            }
            // Nothing was said: the session stays as it was, apart from a rename.
            previous != null -> previous.copy(title = current.title, titleEdited = current.titleEdited)
            else -> null
        }
        if (final != null && final != previous) sink.save(final)
        sink.ended(current.id, final)
    }

    private fun stored(row: SubtitleRow, firstSeenMs: Long, existing: SessionRow?): SessionRow? {
        val offset = (firstSeenMs - segmentStart).coerceAtLeast(0)
        if (row.marker.isNotEmpty()) return existing ?: SessionRow(segment, SessionRow.KIND_BREAK, offset)
        if (!row.sourceDone) return existing
        val translation = if (row.translationDone) row.translation else existing?.translation.orEmpty()
        if (row.source.isEmpty() && translation.isEmpty()) return existing
        return SessionRow(segment, SessionRow.KIND_TEXT, existing?.offsetMs ?: offset, row.source, translation)
    }

    private fun reindex() {
        index.clear()
        keys.forEachIndexed { position, key -> index[key] = position }
    }
}
