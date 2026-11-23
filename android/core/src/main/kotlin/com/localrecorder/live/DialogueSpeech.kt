package com.localrecorder.live

import java.io.ByteArrayOutputStream

/** Cloud audio can arrive before the source/output link or the language decision. Quarantine it
 * per socket and per output item until the intended receiver is known. */
internal class DialogueSpeechInbox {
    private class Item {
        var sourceKey: String? = null
        var audio = ByteArrayOutputStream()
        var done = false
    }
    private val decoder = LiveTranslateAudioDecoder()
    private val items = LinkedHashMap<String, Item>()
    private val released = RecentIds()
    private var size = 0

    fun link(id: String, sourceKey: String) {
        if (id !in items && items.size >= LiveSession.MAX_ACTIVE_ROWS) evictFirst()
        items.getOrPut(id, ::Item).sourceKey = sourceKey
    }

    fun audio(event: LiveSessionEvent.Audio) {
        val pcm = decoder.consume(event)
        val id = event.item ?: return
        if (id !in items && items.size >= LiveSession.MAX_ACTIVE_ROWS) evictFirst()
        val item = items.getOrPut(id, ::Item)
        if (pcm != null) {
            if (size + pcm.size > MAX_PENDING_SPEECH_BYTES) throw LiveTranslateException("等待语言识别的译音超过 30 秒，已停止播放")
            item.audio.write(pcm)
            size += pcm.size
        }
        if (event.final) item.done = true
    }

    private fun evictFirst() {
        val oldest = items.entries.first()
        size -= oldest.value.audio.size()
        items.remove(oldest.key)
    }

    fun release(decision: (String) -> Boolean?, play: (ByteArray) -> Unit) {
        val iterator = items.iterator()
        val ready = mutableListOf<ByteArray>()
        while (iterator.hasNext()) {
            val (id, item) = iterator.next()
            if (!item.done) continue
            val key = item.sourceKey ?: continue
            val wanted = decision(key) ?: continue
            iterator.remove()
            size -= item.audio.size()
            if (released.add(id) && wanted && item.audio.size() > 0) ready.add(item.audio.toByteArray())
        }
        ready.forEach(play)
    }
}

/** Only one hardware player owns the output at once. finish() acknowledges the final *played*
 * sample before capture is unmuted on loudspeaker; headphones can continue full duplex. */
internal class DialogueSpeaker(
    private val platform: SessionPlatform,
    private val shouldGate: () -> Boolean,
    private val report: (String) -> Unit,
    private val changed: () -> Unit,
) {
    private val queue = ArrayDeque<ByteArray>()
    private var queued = 0
    @Volatile private var current: SpeechOutput? = null
    private var volume = 0.8f
    @Volatile private var gateFallback = false
    val gate: Boolean get() = current?.let { it.microphoneMayHearPlayback ?: gateFallback } ?: false
    val playing get() = current != null

    fun setVolume(value: Float) {
        volume = value
        current?.setVolume(value)
    }

    fun enqueue(audio: ByteArray, volume: Float) {
        this.volume = volume
        if (queued + audio.size > MAX_PENDING_SPEECH_BYTES) {
            report("译音播放积压超过 30 秒，已停止播放")
            return
        }
        queue.add(audio)
        queued += audio.size
        if (current == null) playNext()
    }

    private fun playNext() {
        val pcm = queue.removeFirstOrNull() ?: return
        queued -= pcm.size
        try {
            val player = platform.speech()
            gateFallback = shouldGate()
            current = player
            player.start(volume)
            if (!player.append(pcm)) throw LiveTranslateException("无法播放译音")
            player.finish {
                platform.post {
                    if (current === player) {
                        player.stop()
                        current = null
                        playNext()
                        changed()
                    }
                }
            }
            changed()
        } catch (_: Exception) {
            report("无法播放译音，字幕将继续更新")
        }
    }

    fun stop() {
        current?.stop()
        current = null
        queue.clear()
        queued = 0
    }
}
