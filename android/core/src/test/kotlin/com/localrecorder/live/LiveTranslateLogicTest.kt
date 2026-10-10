package com.localrecorder.live

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Base64

class LiveTranslateLogicTest {
    private fun json(vararg pairs: Pair<String, Any>): JSONObject = JSONObject().apply { pairs.forEach { put(it.first, it.second) } }
    private fun audioEvent(id: String, data: ByteArray, item: String = "a") = json(
        "type" to "response.audio.delta", "event_id" to id, "item_id" to item,
        "delta" to Base64.getEncoder().encodeToString(data),
    )
    private fun sourceFinal(id: String) = json("type" to "conversation.item.input_audio_transcription.completed", "item_id" to id, "transcript" to "source")
    private fun mapping(source: String, output: String) = json(
        "type" to "conversation.item.created", "previous_item_id" to source,
        "item" to json("id" to output, "role" to "assistant"),
    )
    private fun textFinal(output: String) = json("type" to "response.audio_transcript.done", "item_id" to output, "transcript" to "译文")
    private fun doneAudio(output: String) = json("type" to "response.audio.done", "item_id" to output)
    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    private inline fun assertRejected(message: String, block: () -> Unit) {
        try {
            block()
        } catch (_: Exception) {
            return
        }
        fail(message)
    }

    @Test
    fun configurationCompatibilityAndValidation() {
        val legacy = LiveTranslateConfig.fromJson("""{"enabled":true,"endpoint":"wss://example.com/realtime","language":"en"}""")
        assertFalse("existing configuration preserved without enabling sound", legacy.audioOutput)
        assertEquals(0.8f, legacy.volume)
        assertEquals(PlaybackTiming.STREAMING, legacy.playbackTiming)
        val audio = LiveTranslateConfig(audioOutput = true, volume = 0.35f, playbackTiming = PlaybackTiming.AFTER_FINAL)
        assertEquals("audio settings survive reload", audio, LiveTranslateConfig.fromJson(audio.toJson()))

        val config = LiveTranslateConfig(endpoint = "wss://EXAMPLE.com:443/api-ws/v1/realtime?model=old", language = "ja").normalized()
        assertEquals("wss://example.com/api-ws/v1/realtime", config.endpoint)
        assertEquals("livetranslate:" + config.endpoint, config.keyAccount)
        assertTrue(config.url().endsWith("?model=qwen3.8-livetranslate-flash-realtime"))
        for (address in listOf(
            "https://example.com/realtime", "ws://example.com/realtime", "wss://user:secret@example.com/realtime",
            "wss://example.com/realtime?key=secret", "wss://example.com/realtime#secret", "wss://example.com/", "not a url",
        )) {
            assertRejected("unsafe URL rejected: $address") { LiveTranslateConfig(endpoint = address).url() }
        }
        assertRejected("unsupported language rejected") { LiveTranslateConfig(language = "xx").url() }
        assertRejected("localhost only with explicit opt-in") { LiveTranslateConfig(endpoint = "ws://127.0.0.1:1/ok").url() }
        assertEquals("ws://127.0.0.1:1/ok?model=${LiveTranslateConfig.MODEL}", LiveTranslateConfig(endpoint = "ws://127.0.0.1:1/ok").url(allowLocalhost = true))

        val update = LiveTranslateConfig(audioOutput = true, language = "en").sessionUpdate()
        val session = update.getJSONObject("session")
        assertEquals("session.update", update.getString("type"))
        assertEquals(2, session.getJSONArray("output_modalities").length())
        assertEquals(16000, session.getJSONObject("audio").getJSONObject("input").getJSONObject("format").getInt("sample_rate"))
        assertEquals(24000, session.getJSONObject("audio").getJSONObject("output").getJSONObject("format").getInt("sample_rate"))
    }

    @Test
    fun audioDecoder() {
        val decoder = LiveTranslateAudioDecoder()
        assertNull("partial PCM sample buffered", decoder.consume(audioEvent("one", bytes(0))))
        assertArrayEquals(bytes(0, 64, 0, 128, 255, 127), decoder.consume(audioEvent("two", bytes(64, 0, 128, 255, 127))))
        assertNull("duplicate audio never replays", decoder.consume(audioEvent("two", bytes(0, 0))))
        decoder.consume(doneAudio("a"))
        assertNull("late audio ignored after done", decoder.consume(audioEvent("late", bytes(0, 0))))

        val corrupt = LiveTranslateAudioDecoder()
        assertRejected("invalid audio rejected") {
            corrupt.consume(json("type" to "response.audio.delta", "item_id" to "a", "delta" to "bad base64!"))
        }
        corrupt.consume(audioEvent("odd", bytes(0)))
        assertRejected("incomplete final PCM sample rejected") { corrupt.consume(doneAudio("a")) }
    }

    @Test
    fun delayedPlaybackOrdering() {
        var text = LiveTranslateEvents()
        var delayed = LiveTranslatePlaybackQueue(PlaybackTiming.AFTER_FINAL)
        fun feed(event: JSONObject): List<ByteArray> {
            text.apply(event)
            return delayed.consume(event, text)
        }
        val chunk = audioEvent("buffered", bytes(0, 64))
        assertTrue(feed(chunk).isEmpty() && delayed.hasPendingAudio)
        assertTrue("association alone cannot start playback", feed(mapping("s", "a")).isEmpty())
        assertTrue("complete audio waits for source and translation", feed(doneAudio("a")).isEmpty())
        assertTrue("final translation waits for final source", feed(textFinal("a")).isEmpty())
        val released = feed(sourceFinal("s"))
        assertEquals(1, released.size)
        assertArrayEquals(bytes(0, 64), released[0])
        assertTrue("duplicate final does not replay", feed(sourceFinal("s")).isEmpty() && !delayed.hasPendingAudio)

        delayed = LiveTranslatePlaybackQueue(PlaybackTiming.AFTER_FINAL); text = LiveTranslateEvents()
        feed(mapping("first", "a")); feed(mapping("second", "b"))
        feed(sourceFinal("second")); feed(textFinal("b"))
        feed(audioEvent("second", bytes(1, 64), item = "b"))
        assertTrue("later utterance cannot overtake pending first sentence", feed(doneAudio("b")).isEmpty())
        feed(chunk); feed(sourceFinal("first")); feed(textFinal("a"))
        val ordered = feed(doneAudio("a"))
        assertEquals(2, ordered.size)
        assertArrayEquals(bytes(0, 64), ordered[0])
        assertArrayEquals(bytes(1, 64), ordered[1])

        val immediate = LiveTranslatePlaybackQueue(PlaybackTiming.STREAMING)
        assertArrayEquals(bytes(0, 64), immediate.consume(chunk, LiveTranslateEvents()).single())

        delayed = LiveTranslatePlaybackQueue(PlaybackTiming.AFTER_FINAL); text = LiveTranslateEvents()
        assertRejected("waiting audio memory is bounded") { feed(audioEvent("large", ByteArray(1_440_002))) }
    }

    @Test
    fun eventJoining() {
        val events = LiveTranslateEvents()
        val delta = json("event_id" to "same", "type" to "response.text.delta", "item_id" to "t", "delta" to "译文")
        events.apply(delta); events.apply(JSONObject(delta.toString()))
        events.apply(json("type" to "response.text.done", "item_id" to "t", "text" to "完整译文"))
        events.apply(json("type" to "response.text.delta", "item_id" to "t", "delta" to "忽略迟到内容"))
        assertTrue("unmatched translation buffered", events.hasUnmatchedOutput)
        events.apply(mapping("s", "t")); events.apply(mapping("s", "t"))
        events.apply(json("type" to "conversation.item.input_audio_transcription.completed", "item_id" to "s", "transcript" to "完整原文"))
        events.apply(json("type" to "conversation.item.input_audio_transcription.delta", "item_id" to "s", "delta" to "忽略迟到内容"))
        assertEquals(1, events.rows.size)
        assertEquals("完整原文", events.rows["s"]!!.source.text)
        assertEquals("完整译文", events.translation(events.rows["s"]!!).text)
        assertFalse("pending association resolved", events.hasUnmatchedOutput)
        events.apply(json("type" to "conversation.item.input_audio_transcription.completed", "item_id" to "s2", "transcript" to "完整原文"))
        assertEquals("repeated speech is never deduplicated by text", 2, events.rows.size)
    }

    @Test
    fun longSessionBookkeepingIsBounded() {
        val events = LiveTranslateEvents()
        events.apply(mapping("s", "t")); events.apply(sourceFinal("s"))
        events.apply(json("type" to "response.text.done", "item_id" to "t", "text" to "译文"))
        events.apply(sourceFinal("keep"))
        events.retire("s")
        assertEquals(listOf("keep"), events.order)
        assertTrue(events.outputs.isEmpty())
        // Late events for a retired row or its translation never bring it back.
        events.apply(sourceFinal("s")); events.apply(mapping("s", "t2"))
        events.apply(json("type" to "response.text.delta", "item_id" to "t", "delta" to "迟到"))
        assertEquals(listOf("keep"), events.order)
        assertFalse(events.hasUnmatchedOutput)

        val recent = RecentIds(limit = 3)
        assertTrue(recent.add("a")); assertFalse("duplicate", recent.add("a"))
        assertTrue(recent.add("b")); assertTrue(recent.add("c")); assertTrue(recent.add("d"))
        assertFalse(recent.add("d"))
        assertTrue("only the most recent IDs are remembered", recent.add("a"))
    }
}
