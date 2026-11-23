package com.localrecorder.sessions

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/** One recording (the first one or a "continue recording") inside a session. */
data class SessionSegment(
    val startedAtMs: Long,
    /** Null while recording. */
    val endedAtMs: Long?,
    /** Null when the segment had no translation. */
    val targetLanguage: String?,
    val mode: String = SessionRecord.MODE_LIVE_TRANSLATE,
)

/** A finalized row: text, or a connection break (`kind = break`, empty texts). */
data class SessionRow(
    /** Index into [SessionRecord.segments]. */
    val segment: Int,
    val kind: String,
    /** Relative to the start of its segment. */
    val offsetMs: Long,
    val source: String = "",
    val translation: String = "",
    val targetLanguage: String? = null,
    val sourceLanguage: String? = null,
    val speaker: String? = null,
    val languageSwitch: String? = null,
) {
    val switchMarker: String? get() = languageSwitch?.let(SessionText::clean)?.takeIf { it.isNotEmpty() }
        ?.let { "译文语言已切换为 $it" }
    val speakerPrefix: String get() = when (speaker) {
        "A", "B" -> "$speaker："
        "unknown" -> "未识别："
        else -> ""
    }

    val isBreak: Boolean get() = kind == KIND_BREAK

    companion object {
        const val KIND_TEXT = "text"
        const val KIND_BREAK = "break"
    }
}

/** Session file v1 (docs/SESSIONS.md). Only finalized text is ever stored; never audio or partials. */
data class SessionRecord(
    val id: String,
    val title: String,
    val titleEdited: Boolean,
    val createdAtMs: Long,
    val updatedAtMs: Long,
    val segments: List<SessionSegment>,
    val rows: List<SessionRow>,
) {
    val summary: SessionSummary get() = SessionSummary(id, title, createdAtMs, updatedAtMs)

    fun toJson(): String {
        val segmentArray = JSONArray()
        for (segment in segments) {
            segmentArray.put(
                JSONObject()
                    .put("started_at_ms", segment.startedAtMs)
                    .put("ended_at_ms", segment.endedAtMs ?: JSONObject.NULL)
                    .put("target_language", segment.targetLanguage ?: JSONObject.NULL)
                    .put("mode", segment.mode),
            )
        }
        val rowArray = JSONArray()
        for (row in rows) {
            rowArray.put(
                JSONObject()
                    .put("segment", row.segment)
                    .put("kind", row.kind)
                    .put("offset_ms", row.offsetMs)
                    .put("source", row.source)
                    .put("translation", row.translation)
                    .put("target_language", row.targetLanguage)
                    .put("source_language", row.sourceLanguage)
                    .put("speaker", row.speaker)
                    .put("language_switch", row.languageSwitch),
            )
        }
        return JSONObject()
            .put("schema_version", SCHEMA_VERSION)
            .put("id", id)
            .put("title", title)
            .put("title_edited", titleEdited)
            .put("created_at_ms", createdAtMs)
            .put("updated_at_ms", updatedAtMs)
            .put("segments", segmentArray)
            .put("rows", rowArray)
            .toString()
    }

    /** The title to use after rows change: kept when the user renamed the session, otherwise regenerated. */
    fun retitled(zone: ZoneId): SessionRecord =
        if (titleEdited) this else copy(title = SessionText.defaultTitle(createdAtMs, rows, zone))

    companion object {
        const val SCHEMA_VERSION = 1
        const val MODE_LIVE_TRANSLATE = "live_translate"

        private val ID = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

        /** Lowercase UUIDs only: the ID is also the file name. */
        fun isValidId(id: String): Boolean = ID.matches(id)

        /**
         * Parses a session file; unknown fields are ignored. Throws [UnsupportedSessionVersion] for a newer
         * schema and [SessionFormatException] for anything malformed.
         */
        fun fromJson(text: String): SessionRecord {
            val json = try {
                JSONObject(text)
            } catch (e: Exception) {
                throw SessionFormatException("not a JSON object")
            }
            try {
                val version = json.getInt("schema_version")
                if (version > SCHEMA_VERSION) throw UnsupportedSessionVersion(version)
                if (version < 1) throw SessionFormatException("schema_version $version")
                val id = json.getString("id")
                if (!isValidId(id)) throw SessionFormatException("id")
                val segmentArray = json.getJSONArray("segments")
                val segments = (0 until segmentArray.length()).map { index ->
                    val item = segmentArray.getJSONObject(index)
                    SessionSegment(
                        startedAtMs = item.getLong("started_at_ms"),
                        endedAtMs = if (item.isNull("ended_at_ms")) null else item.getLong("ended_at_ms"),
                        targetLanguage = if (item.isNull("target_language")) null else item.getString("target_language"),
                        mode = item.getString("mode"),
                    )
                }
                val rowArray = json.getJSONArray("rows")
                val rows = (0 until rowArray.length()).map { index ->
                    val item = rowArray.getJSONObject(index)
                    val segment = item.getInt("segment")
                    if (segment !in segments.indices) throw SessionFormatException("row segment $segment")
                    SessionRow(
                        segment = segment,
                        kind = item.getString("kind"),
                        offsetMs = item.getLong("offset_ms"),
                        source = item.getString("source"),
                        translation = item.getString("translation"),
                        targetLanguage = item.opt("target_language") as? String,
                        sourceLanguage = item.opt("source_language") as? String,
                        speaker = item.opt("speaker") as? String,
                        languageSwitch = item.opt("language_switch") as? String,
                    )
                }
                return SessionRecord(
                    id = id,
                    title = json.getString("title"),
                    titleEdited = json.getBoolean("title_edited"),
                    createdAtMs = json.getLong("created_at_ms"),
                    updatedAtMs = json.getLong("updated_at_ms"),
                    segments = segments,
                    rows = rows,
                )
            } catch (e: SessionFormatException) {
                throw e
            } catch (e: UnsupportedSessionVersion) {
                throw e
            } catch (e: Exception) {
                throw SessionFormatException(e.message ?: e.javaClass.simpleName)
            }
        }
    }
}

data class SessionSummary(val id: String, val title: String, val createdAtMs: Long, val updatedAtMs: Long)

class SessionFormatException(message: String) : Exception(message)

class UnsupportedSessionVersion(val version: Int) : Exception("schema_version $version")

/** Sidebar groups by the last update, in the device's zone. */
enum class SessionGroup(val label: String) {
    TODAY("今天"),
    YESTERDAY("昨天"),
    WEEK("7 天内"),
    EARLIER("更早");

    companion object {
        fun of(updatedAtMs: Long, nowMs: Long, zone: ZoneId): SessionGroup {
            val day = Instant.ofEpochMilli(updatedAtMs).atZone(zone).toLocalDate()
            val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
            val days = ChronoUnit.DAYS.between(day, today)
            return when {
                days <= 0 -> TODAY
                days == 1L -> YESTERDAY
                days < 7 -> WEEK
                else -> EARLIER
            }
        }
    }
}

/** Text rules shared by titles, exports and file names; they mirror scripts/make_session_export_fixtures.py. */
object SessionText {
    const val NEW_SESSION = "新会话"
    private const val TITLE_PREFIX_CODE_POINTS = 20

    /** CR/LF sequences become one space, then surrounding whitespace is trimmed (Python `str.strip`). */
    fun clean(text: String): String = strip(text.replace("\r\n", " ").replace("\r", " ").replace("\n", " "))

    /** Python's `str.strip()`: Kotlin's `trim()` disagrees on U+0085 (NEL). */
    fun strip(text: String): String {
        var start = 0
        var end = text.length
        while (start < end && isSpace(text[start])) start++
        while (end > start && isSpace(text[end - 1])) end--
        return text.substring(start, end)
    }

    /** Python's `str.isspace` set (all of it lies in the BMP). */
    fun isSpace(c: Char): Boolean = when (c) {
        '\t', '\n', '\u000b', '\u000c', '\r', '\u001c', '\u001d', '\u001e', '\u001f', ' ',
        '\u0085', '\u00a0', '\u1680', '\u2028', '\u2029', '\u202f', '\u205f', '\u3000' -> true
        else -> c in '\u2000'..'\u200a'
    }

    /** The first [count] Unicode code points (a surrogate pair counts once). */
    fun prefix(text: String, count: Int): String =
        if (text.codePointCount(0, text.length) <= count) text else text.substring(0, text.offsetByCodePoints(0, count))

    fun stamp(ms: Long, pattern: String, zone: ZoneId): String =
        DateTimeFormatter.ofPattern(pattern).format(Instant.ofEpochMilli(ms).atZone(zone))

    /** `MM-dd HH:mm` plus the first 20 code points of the first non-empty source text, or 新会话. */
    fun defaultTitle(createdAtMs: Long, rows: List<SessionRow>, zone: ZoneId): String {
        val first = rows.asSequence()
            .filter { it.kind == SessionRow.KIND_TEXT }
            .map { clean(it.source) }
            .firstOrNull { it.isNotEmpty() }
        return stamp(createdAtMs, "MM-dd HH:mm", zone) + " " + (first?.let { prefix(it, TITLE_PREFIX_CODE_POINTS) } ?: NEW_SESSION)
    }
}
