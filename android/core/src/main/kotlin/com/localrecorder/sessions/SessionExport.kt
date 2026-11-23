package com.localrecorder.sessions

import java.time.ZoneId

enum class ExportFormat(val extension: String, val mimeType: String, val label: String) {
    TXT("txt", "text/plain", "TXT"),
    MARKDOWN("md", "text/markdown", "Markdown"),
}

enum class ExportContent(val key: String, val label: String) {
    BILINGUAL("bilingual", "双语"),
    SOURCE("source", "仅原文"),
    TRANSLATION("translation", "仅译文"),
}

/**
 * TXT and Markdown export of a session (docs/SESSIONS.md). The reference implementation is
 * scripts/make_session_export_fixtures.py; the output must match its fixtures byte for byte.
 * LF line endings, no BOM, one trailing newline.
 */
object SessionExport {
    const val BREAK_MARKER = "连接中断，此处内容可能有缺失"
    private const val CONTINUED = "继续录制 "
    private const val DATE = "yyyy-MM-dd HH:mm"
    private const val MD_SPECIAL = "\\`*_[]<>#|~"
    private const val FILE_NAME_FORBIDDEN = "/\\:*?\"<>|"
    private const val FILE_TITLE_CODE_POINTS = 50

    private sealed interface Entry
    private class Marker(val text: String) : Entry
    private class Parts(val parts: List<Pair<Boolean, String>>) : Entry // (isTranslation, cleaned text)

    fun render(record: SessionRecord, format: ExportFormat, content: ExportContent, zone: ZoneId): String = when (format) {
        ExportFormat.TXT -> txt(record, content, zone)
        ExportFormat.MARKDOWN -> markdown(record, content, zone)
    }

    fun txt(record: SessionRecord, content: ExportContent, zone: ZoneId): String {
        val blocks = entries(record, content, zone).map { entry ->
            when (entry) {
                is Marker -> "【${entry.text}】"
                is Parts -> entry.parts.joinToString("\n") { it.second }
            }
        }
        val head = SessionText.clean(record.title) + "\n" + SessionText.stamp(record.createdAtMs, DATE, zone) + "\n"
        return head + body(blocks)
    }

    fun markdown(record: SessionRecord, content: ExportContent, zone: ZoneId): String {
        val blocks = entries(record, content, zone).map { entry ->
            when (entry) {
                is Marker -> "*【${entry.text}】*"
                // Bilingual exports set the translation in bold; single-language exports are plain.
                is Parts -> entry.parts.joinToString("  \n") { (isTranslation, text) ->
                    if (content == ExportContent.BILINGUAL && isTranslation) "**${escape(text)}**" else escape(text)
                }
            }
        }
        val head = "# " + escape(SessionText.clean(record.title)) + "\n\n" + SessionText.stamp(record.createdAtMs, DATE, zone) + "\n"
        return head + body(blocks)
    }

    /** `声笺 yyyy-MM-dd HH-mm 标题.ext` (creation time); the title part is left out when it is empty. */
    fun fileName(record: SessionRecord, format: ExportFormat, zone: ZoneId): String {
        val replaced = buildString {
            record.title.forEach { c -> append(if (c in FILE_NAME_FORBIDDEN || c.code < 0x20 || c.code == 0x7F) '_' else c) }
        }
        val title = SessionText.strip(SessionText.prefix(SessionText.clean(replaced), FILE_TITLE_CODE_POINTS))
        val date = SessionText.stamp(record.createdAtMs, "yyyy-MM-dd HH-mm", zone)
        return if (title.isEmpty()) "声笺 $date.${format.extension}" else "声笺 $date $title.${format.extension}"
    }

    /** The marker text before the rows of a later segment ("continue recording"). */
    fun continuedMarker(startedAtMs: Long, zone: ZoneId): String = CONTINUED + SessionText.stamp(startedAtMs, DATE, zone)

    /** Markdown escaping for the title and every text part. */
    fun escape(text: String): String {
        val escaped = StringBuilder(text.length + 8)
        text.forEach { c ->
            if (c in MD_SPECIAL) escaped.append('\\')
            escaped.append(c)
        }
        if (escaped.isNotEmpty() && (escaped[0] == '-' || escaped[0] == '+')) escaped.insert(0, '\\')
        // A leading "<digits>." would start an ordered list (Python's \d: any Unicode decimal digit).
        var index = 0
        while (index < escaped.length) {
            val codePoint = Character.codePointAt(escaped, index)
            if (!Character.isDigit(codePoint)) break
            index += Character.charCount(codePoint)
        }
        if (index > 0 && index < escaped.length && escaped[index] == '.') escaped.insert(index, '\\')
        return escaped.toString()
    }

    private fun body(blocks: List<String>): String = if (blocks.isEmpty()) "" else "\n" + blocks.joinToString("\n\n") + "\n"

    private fun entries(record: SessionRecord, content: ExportContent, zone: ZoneId): List<Entry> {
        val out = ArrayList<Entry>()
        var previous: Int? = null
        for (row in record.rows) {
            if (previous != null && row.segment != previous) {
                out += Marker(continuedMarker(record.segments[row.segment].startedAtMs, zone))
            }
            previous = row.segment
            if (row.isBreak) {
                out += Marker(BREAK_MARKER)
                continue
            }
            val source = SessionText.clean(row.source)
            val translation = SessionText.clean(row.translation)
            val parts = when (content) {
                ExportContent.SOURCE -> listOf(false to source)
                ExportContent.TRANSLATION -> listOf(true to translation)
                ExportContent.BILINGUAL -> listOf(false to source, true to translation)
            }.filter { it.second.isNotEmpty() }
            if (parts.isNotEmpty()) out += Parts(parts)
        }
        return out
    }
}
