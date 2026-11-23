package com.localrecorder.sessions

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.ZoneId

/**
 * One JSON file per session (`<id>.json`) in [directory]. Writes are atomic (temporary file, fsync,
 * rename). Unreadable, corrupt or newer-schema files are skipped, never deleted by reads. Not thread-safe:
 * the app calls it from one I/O thread.
 */
class SessionStore(val directory: File) {
    /** Test hook: runs after the temporary file is written, before it replaces the session file. */
    internal var beforeCommit: ((File) -> Unit)? = null

    /** Valid sessions, most recently updated first. */
    fun list(): List<SessionRecord> =
        sessionFiles().mapNotNull { read(it) }.sortedWith(compareByDescending<SessionRecord> { it.updatedAtMs }.thenBy { it.id })

    fun load(id: String): SessionRecord? = if (SessionRecord.isValidId(id)) read(fileFor(id)) else null

    fun save(record: SessionRecord) {
        require(SessionRecord.isValidId(record.id)) { "invalid session id" }
        if (!directory.isDirectory && !directory.mkdirs() && !directory.isDirectory) throw IOException("无法创建会话目录")
        val bytes = record.toJson().toByteArray(Charsets.UTF_8)
        val temporary = File.createTempFile(".${record.id}.", ".tmp", directory)
        try {
            FileOutputStream(temporary).use { out ->
                out.write(bytes)
                out.fd.sync()
            }
            beforeCommit?.invoke(temporary)
            val target = fileFor(record.id).toPath()
            try {
                Files.move(temporary.toPath(), target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(temporary.toPath(), target, StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            temporary.delete()
        }
    }

    /** A blank title restores the automatic one. Returns the saved record, or null when it cannot be read. */
    fun rename(id: String, title: String, zone: ZoneId): SessionRecord? {
        val record = load(id) ?: return null
        return renamed(record, title, zone).also(::save)
    }

    fun delete(id: String): Boolean = SessionRecord.isValidId(id) && fileFor(id).delete()

    /** Removes every file in the directory, including ones this version cannot read. */
    fun deleteAll() {
        directory.listFiles()?.forEach { if (it.isFile) it.delete() }
    }

    private fun fileFor(id: String) = File(directory, "$id.json")

    private fun sessionFiles(): List<File> = directory.listFiles()
        ?.filter { it.isFile && it.name.endsWith(".json") && SessionRecord.isValidId(it.name.removeSuffix(".json")) }
        .orEmpty()

    private fun read(file: File): SessionRecord? {
        val record = try {
            SessionRecord.fromJson(file.readText(Charsets.UTF_8))
        } catch (_: Exception) {
            return null
        }
        // The ID is also the file name; a mismatch would make delete and save target another file.
        return record.takeIf { file.name == "${it.id}.json" }
    }

    companion object {
        fun renamed(record: SessionRecord, title: String, zone: ZoneId): SessionRecord {
            val trimmed = SessionText.clean(title)
            return if (trimmed.isEmpty()) record.copy(titleEdited = false).retitled(zone)
            else record.copy(title = trimmed, titleEdited = true)
        }
    }
}
