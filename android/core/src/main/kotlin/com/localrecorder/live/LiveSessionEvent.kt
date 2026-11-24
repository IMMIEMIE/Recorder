package com.localrecorder.live

/** Input and output IDs stay separate until the service links them. */
sealed interface LiveSessionEvent {
    val eventID: String?
    data class Link(val source: String, val output: String, override val eventID: String?) : LiveSessionEvent
    data class SpeechStart(val source: String, val milliseconds: Int, override val eventID: String?) : LiveSessionEvent
    data class SpeechEnd(val milliseconds: Int, override val eventID: String?, val source: String? = null) : LiveSessionEvent
    data class Text(val item: String, val value: String, val source: Boolean, val final: Boolean,
                    override val eventID: String?) : LiveSessionEvent
    /** Null samples on a non-final packet indicate a malformed audio payload. Subtitles can continue. */
    data class Audio(val item: String?, val samples: ByteArray?, val final: Boolean,
                     override val eventID: String?) : LiveSessionEvent
}
