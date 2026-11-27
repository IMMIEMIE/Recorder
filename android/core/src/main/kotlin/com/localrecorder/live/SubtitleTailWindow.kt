package com.localrecorder.live

/**
 * Keeps the newest [maxLines] visual lines of a live subtitle string, mirroring macOS
 * `SubtitleLayout.tail` so long streaming utterances roll forward instead of truncating the end
 * with `…`.
 */
object SubtitleTailWindow {
    fun tailLines(raw: String, maxLines: Int, wrap: (String) -> List<String>): List<String> {
        val text = raw.trim()
        if (text.isEmpty() || maxLines <= 0) return emptyList()
        val lines = wrap(text).map { it.trim() }.filter { it.isNotEmpty() }
        if (lines.isEmpty()) return listOf(text)
        return lines.takeLast(maxLines)
    }

    fun tail(raw: String, maxLines: Int, wrap: (String) -> List<String>): String =
        tailLines(raw, maxLines, wrap).joinToString("\n")
}
