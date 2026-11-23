package com.localrecorder.sessions

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.ZoneId

/** Byte-for-byte comparison with tests/fixtures/session_export (shared with macOS). */
class SessionExportTest {
    private val fixtures = File(System.getProperty("session.fixtures") ?: error("session.fixtures is not set"))
    private val meta = JSONObject(File(fixtures, "expected/meta.json").readText(Charsets.UTF_8))
    private val zone = ZoneId.of(meta.getString("zone"))
    private val session = SessionRecord.fromJson(File(fixtures, "session.json").readText(Charsets.UTF_8))

    @Test
    fun readsTheFixtureAndIgnoresUnknownFields() {
        assertEquals("0b8f6c2e-4d1a-4c47-9a53-2f1e6d7c8a90", session.id)
        assertTrue(session.titleEdited)
        assertEquals(2, session.segments.size)
        assertEquals("ja", session.segments[1].targetLanguage)
        assertEquals(9, session.rows.size)
        assertTrue(session.rows[4].isBreak)
        assertEquals("round trip", session, SessionRecord.fromJson(session.toJson()))
    }

    @Test
    fun exportsMatchTheFixturesByteForByte() {
        for (content in ExportContent.entries) {
            for (format in ExportFormat.entries) {
                val expected = File(fixtures, "expected/${content.key}.${format.extension}").readBytes()
                val actual = SessionExport.render(session, format, content, zone).toByteArray(Charsets.UTF_8)
                assertArrayEquals("${content.key}.${format.extension}", expected, actual)
            }
        }
    }

    @Test
    fun fileNamesMatch() {
        val names = meta.getJSONObject("file_names")
        assertEquals(names.getString("txt"), SessionExport.fileName(session, ExportFormat.TXT, zone))
        assertEquals(names.getString("md"), SessionExport.fileName(session, ExportFormat.MARKDOWN, zone))
        val untitled = session.copy(title = "   ")
        assertEquals("声笺 2026-11-23 14-05.txt", SessionExport.fileName(untitled, ExportFormat.TXT, zone))
        val long = session.copy(title = "a".repeat(49) + "😀b/c")
        assertEquals("声笺 2026-11-23 14-05 ${"a".repeat(49)}😀.md", SessionExport.fileName(long, ExportFormat.MARKDOWN, zone))
    }

    @Test
    fun defaultTitlesMatch() {
        val cases = meta.getJSONArray("default_titles")
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val rows = case.getJSONArray("rows").let { array ->
                (0 until array.length()).map { array.getJSONObject(it) }.map {
                    SessionRow(it.getInt("segment"), it.getString("kind"), it.getLong("offset_ms"), it.getString("source"), it.getString("translation"))
                }
            }
            assertEquals(case.getString("expected"), SessionText.defaultTitle(case.getLong("created_at_ms"), rows, zone))
        }
    }

    @Test
    fun emptySessionsAndEscapes() {
        val empty = session.copy(rows = emptyList())
        assertEquals("周会：Q4 *计划* #1 / 草稿?\n2026-11-23 14:05\n", SessionExport.txt(empty, ExportContent.BILINGUAL, zone))
        assertEquals("# 周会：Q4 \\*计划\\* \\#1 / 草稿?\n\n2026-11-23 14:05\n", SessionExport.markdown(empty, ExportContent.SOURCE, zone))
        assertEquals("\\+1", SessionExport.escape("+1"))
        assertEquals("12\\. x", SessionExport.escape("12. x"))
        assertEquals("١٢\\. Arabic-Indic digits", SessionExport.escape("١٢. Arabic-Indic digits"))
        assertEquals("12", SessionExport.escape("12"))
        assertEquals("a", SessionText.strip("\u3000a\u0085 "))
        assertEquals("a", SessionText.clean("　a\u0085 "))
        assertEquals("a b c", SessionText.clean("a\r\nb\rc"))
    }

    @Test
    fun groupsByLastUpdate() {
        val day = 86_400_000L
        val now = session.createdAtMs // 2026-11-23 14:05 in Shanghai
        assertEquals(SessionGroup.TODAY, SessionGroup.of(now - 14 * 3_600_000L, now, zone))
        assertEquals(SessionGroup.YESTERDAY, SessionGroup.of(now - 15 * 3_600_000L, now, zone))
        assertEquals(SessionGroup.WEEK, SessionGroup.of(now - 6 * day, now, zone))
        assertEquals(SessionGroup.EARLIER, SessionGroup.of(now - 7 * day, now, zone))
        assertEquals(SessionGroup.TODAY, SessionGroup.of(now + day, now, zone))
    }
}
