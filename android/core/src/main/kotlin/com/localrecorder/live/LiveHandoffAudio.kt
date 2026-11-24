package com.localrecorder.live

/**
 * A single lane's captured PCM16/16kHz while it has no ready destination. All calls share the capture lock.
 * Recovery keeps #25's last second. A deliberate handoff may hold five seconds and drain at 1.25x
 * while capture continues. A scheduler stall never earns credit for a burst.
 */
class LiveHandoffAudio(reason: Reason) {
    enum class Reason { RECOVERY, LANGUAGE_SWITCH }
    private val planned = reason == Reason.LANGUAGE_SWITCH
    private val capacity = if (planned) 5 * 16_000 * 2 else LiveSession.CATCH_UP_AUDIO_BYTES
    private val chunks = ArrayDeque<ByteArray>()
    var size = 0
        private set
    private var nextSendMs = 0L

    fun append(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        require(pcm.size % 2 == 0)
        if (pcm.size >= capacity) {
            chunks.clear()
            chunks.addLast(pcm.copyOfRange(pcm.size - capacity, pcm.size))
            size = capacity
            return
        }
        chunks.addLast(pcm)
        size += pcm.size
        while (size > capacity) take(minOf(size - capacity, chunks.first().size))
    }

    private fun take(count: Int): ByteArray {
        val first = chunks.removeFirst()
        size -= count
        if (count == first.size) return first
        chunks.addFirst(first.copyOfRange(count, first.size))
        return first.copyOf(count)
    }

    /** Call only when the transport can accept data. For planned changes, poll on a monotonic clock. */
    fun poll(nowMs: Long): ByteArray? {
        if (chunks.isEmpty() || (planned && nowMs < nextSendMs)) return null
        val next = take(if (planned) minOf(3200, chunks.first().size) else chunks.first().size)
        if (planned) nextSendMs = nowMs + (next.size + 39) / 40 // 40 bytes/ms = 1.25x
        return next
    }

    /** The transport stopped accepting audio after poll; keep the unsent prefix for the next attempt. */
    fun restoreFront(pcm: ByteArray) {
        chunks.addFirst(pcm)
        size += pcm.size
    }

    fun clear() {
        chunks.clear()
        size = 0
        nextSendMs = 0
    }
}
