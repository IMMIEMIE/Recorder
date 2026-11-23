package com.localrecorder.sessions

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.time.ZoneId

class SessionStoreTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val zone = ZoneId.of("Asia/Shanghai")

    private fun record(id: String, updated: Long, title: String = "标题", edited: Boolean = true) = SessionRecord(
        id = id,
        title = title,
        titleEdited = edited,
        createdAtMs = 1_795_413_900_000,
        updatedAtMs = updated,
        segments = listOf(SessionSegment(1_795_413_900_000, null, "zh")),
        rows = listOf(
            SessionRow(0, SessionRow.KIND_TEXT, 1200, "Hello\nthere \"quoted\" \\ /", "你好"),
            SessionRow(0, SessionRow.KIND_BREAK, 1500),
        ),
    )

    private val a = "aaaaaaaa-0000-4000-8000-000000000001"
    private val b = "bbbbbbbb-0000-4000-8000-000000000002"

    @Test
    fun roundTripListRenameDelete() {
        val dir = File(folder.root, "sessions")
        val store = SessionStore(dir)
        assertTrue("a missing directory lists as empty", store.list().isEmpty())
        store.save(record(a, 10))
        store.save(record(b, 20))
        assertEquals(record(a, 10), store.load(a))
        assertEquals(listOf(b, a), store.list().map { it.id })
        assertEquals("files are named by ID", setOf("$a.json", "$b.json"), dir.list()!!.toSet())

        val renamed = store.rename(a, "  新标题\n", zone)!!
        assertEquals("新标题", renamed.title)
        assertTrue(renamed.titleEdited)
        assertEquals("renaming does not move a session in the list", 10L, renamed.updatedAtMs)
        val automatic = store.rename(a, "   ", zone)!!
        assertFalse(automatic.titleEdited)
        assertEquals("11-23 14:05 Hello there \"quoted\"", automatic.title)
        assertEquals(automatic, store.load(a))

        assertTrue(store.delete(a))
        assertNull(store.load(a))
        assertFalse(store.delete(a))
        assertNull("IDs never become paths", store.load("../$b"))
        assertFalse(store.delete("../$b"))
        store.deleteAll()
        assertTrue(store.list().isEmpty())
        assertEquals(0, dir.list()!!.size)
    }

    @Test
    fun skipsCorruptAndNewerFilesWithoutDeletingThem() {
        val dir = folder.newFolder("sessions")
        val store = SessionStore(dir)
        store.save(record(a, 10))
        val c = "cccccccc-0000-4000-8000-000000000003"
        val d = "dddddddd-0000-4000-8000-000000000004"
        val e = "eeeeeeee-0000-4000-8000-000000000005"
        File(dir, "$b.json").writeText("{\"schema_version\": 1, \"id\": \"$b\", \"title\": ")
        File(dir, "$c.json").writeText(record(c, 30).toJson().replace("\"schema_version\":1", "\"schema_version\":2"))
        File(dir, "$d.json").writeText(record(a, 40).toJson()) // the ID does not match the file name
        File(dir, "$e.json").writeText(record(e, 50).toJson().replace("\"segment\":0", "\"segment\":3"))
        File(dir, "notes.txt").writeText("x")
        assertEquals(listOf(a), store.list().map { it.id })
        assertNull(store.load(b))
        assertNull(store.load(c))
        assertNull(store.load(e))
        assertTrue(File(dir, "$b.json").exists() && File(dir, "$c.json").exists())
        try {
            SessionRecord.fromJson(record(c, 30).toJson().replace("\"schema_version\":1", "\"schema_version\":2"))
            fail()
        } catch (expected: UnsupportedSessionVersion) {
            assertEquals(2, expected.version)
        }
    }

    @Test
    fun writesAreAtomic() {
        val dir = folder.newFolder("sessions")
        val store = SessionStore(dir)
        val original = record(a, 10)
        store.save(original)
        store.beforeCommit = { temporary ->
            assertTrue(temporary.parentFile == dir && temporary.name.endsWith(".tmp"))
            assertEquals("the target is untouched until the rename", original, store.load(a))
            throw IOException("disk full")
        }
        try {
            store.save(record(a, 20, title = "新"))
            fail()
        } catch (_: IOException) {
        }
        assertEquals(original, store.load(a))
        assertEquals("no temporary file is left behind", listOf("$a.json"), dir.list()!!.toList())
        store.beforeCommit = null
        store.save(record(a, 20, title = "新"))
        assertEquals("新", store.load(a)!!.title)
        assertEquals(listOf("$a.json"), dir.list()!!.toList())
    }
}
