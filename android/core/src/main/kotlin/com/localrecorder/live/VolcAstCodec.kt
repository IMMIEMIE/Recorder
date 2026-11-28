package com.localrecorder.live

import java.io.ByteArrayOutputStream

/**
 * Minimal, zero-dependency Protobuf wire codec for Volcengine / BytePlus Seed-LiveInterpret 2.0
 * (`wss://openspeech.bytedance.com/api/v4/ast/v2/translate`).
 *
 * Field numbers and enum values are verified against the official ByteDance `.proto` definitions
 * (`common/events.proto`, `common/rpcmeta.proto`, `products/understanding/base/au_base.proto`,
 * `products/understanding/ast/ast_service.proto`).
 */
object VolcAstEventType {
    const val NONE = 0
    const val CONNECTION_STARTED = 50
    const val CONNECTION_FAILED = 51
    const val CONNECTION_FINISHED = 52
    const val START_SESSION = 100
    const val CANCEL_SESSION = 101
    const val FINISH_SESSION = 102
    const val SESSION_STARTED = 150
    const val SESSION_CANCELED = 151
    const val SESSION_FINISHED = 152
    const val SESSION_FAILED = 153
    const val USAGE_RESPONSE = 154
    const val TASK_REQUEST = 200
    const val UPDATE_CONFIG = 201
    const val AUDIO_MUTED = 250
    const val TTS_SENTENCE_START = 350
    const val TTS_SENTENCE_END = 351
    const val TTS_RESPONSE = 352
    const val TTS_ENDED = 359
    const val SOURCE_SUBTITLE_START = 650
    const val SOURCE_SUBTITLE_RESPONSE = 651
    const val SOURCE_SUBTITLE_END = 652
    const val TRANSLATION_SUBTITLE_START = 653
    const val TRANSLATION_SUBTITLE_RESPONSE = 654
    const val TRANSLATION_SUBTITLE_END = 655
}

class VolcAstWireException(message: String) : Exception(message)

internal class VolcAstProtoWriter {
    private val out = ByteArrayOutputStream()

    fun toByteArray(): ByteArray = out.toByteArray()

    fun writeVarint(value: Long) {
        var v = value
        while ((v and 0x7FL.inv()) != 0L) {
            out.write(((v and 0x7FL) or 0x80L).toInt())
            v = v ushr 7
        }
        out.write(v.toInt())
    }

    fun writeTag(field: Int, wireType: Int) {
        writeVarint(((field.toLong() shl 3) or wireType.toLong()))
    }

    fun writeInt32(field: Int, value: Int, omitDefault: Boolean = true) {
        if (omitDefault && value == 0) return
        writeTag(field, 0)
        writeVarint(value.toLong())
    }

    fun writeBool(field: Int, value: Boolean, omitDefault: Boolean = true) {
        if (omitDefault && !value) return
        writeTag(field, 0)
        writeVarint(if (value) 1L else 0L)
    }

    fun writeString(field: Int, value: String, omitDefault: Boolean = true) {
        if (omitDefault && value.isEmpty()) return
        writeBytes(field, value.toByteArray(Charsets.UTF_8), omitDefault = false)
    }

    fun writeBytes(field: Int, value: ByteArray, omitDefault: Boolean = true) {
        if (omitDefault && value.isEmpty()) return
        writeTag(field, 2)
        writeVarint(value.size.toLong())
        out.write(value)
    }

    fun writeMessage(field: Int, encoded: ByteArray, omitEmpty: Boolean = false) {
        if (omitEmpty && encoded.isEmpty()) return
        writeTag(field, 2)
        writeVarint(encoded.size.toLong())
        out.write(encoded)
    }
}

internal class VolcAstProtoReader private constructor(
    private val bytes: ByteArray,
    private var offset: Int,
    private val end: Int,
    private val depth: Int,
) {
    constructor(data: ByteArray) : this(data, 0, data.size, 0)

    companion object {
        private const val MAX_DEPTH = 16
    }

    val hasMore: Boolean get() = offset < end

    fun readVarint(): Long {
        var result = 0L
        var shift = 0
        while (offset < end) {
            val b = bytes[offset++].toInt() and 0xFF
            if (shift == 63 && b > 1) throw VolcAstWireException("invalid varint")
            result = result or ((b and 0x7F).toLong() shl shift)
            if ((b and 0x80) == 0) return result
            shift += 7
            if (shift >= 64) throw VolcAstWireException("varint overflow")
        }
        throw VolcAstWireException("truncated varint")
    }

    fun readTag(): Pair<Int, Int> {
        val raw = readVarint()
        val field = (raw ushr 3).toInt()
        if (field <= 0) throw VolcAstWireException("invalid field number")
        val wire = (raw and 0x07L).toInt()
        return field to wire
    }

    fun readInt32(): Int = readVarint().toInt()

    fun readBool(): Boolean = readVarint() != 0L

    fun readBytes(): ByteArray {
        val len = readVarint()
        if (len < 0 || len > (end - offset).toLong()) throw VolcAstWireException("invalid length")
        val count = len.toInt()
        val copy = bytes.copyOfRange(offset, offset + count)
        offset += count
        return copy
    }

    fun readString(): String = String(readBytes(), Charsets.UTF_8)

    fun readSubmessage(): VolcAstProtoReader {
        if (depth >= MAX_DEPTH) throw VolcAstWireException("nesting depth exceeded")
        val len = readVarint()
        if (len < 0 || len > (end - offset).toLong()) throw VolcAstWireException("invalid submessage length")
        val start = offset
        offset += len.toInt()
        return VolcAstProtoReader(bytes, start, offset, depth + 1)
    }

    fun skip(wireType: Int) {
        when (wireType) {
            0 -> readVarint()
            1 -> {
                if (end - offset < 8) throw VolcAstWireException("truncated fixed64")
                offset += 8
            }
            2 -> {
                val len = readVarint()
                if (len < 0 || len > (end - offset).toLong()) throw VolcAstWireException("invalid skip length")
                offset += len.toInt()
            }
            5 -> {
                if (end - offset < 4) throw VolcAstWireException("truncated fixed32")
                offset += 4
            }
            else -> throw VolcAstWireException("unsupported wire type $wireType")
        }
    }
}

data class VolcAstRequestMeta(
    val endpoint: String = "",
    val appKey: String = "",
    val appID: String = "",
    val resourceID: String = "",
    val connectionID: String = "",
    val sessionID: String = "",
    val sequence: Int = 0,
) {
    fun encode(): ByteArray = VolcAstProtoWriter().apply {
        writeString(1, endpoint)
        writeString(2, appKey)
        writeString(3, appID)
        writeString(4, resourceID)
        writeString(5, connectionID)
        writeString(6, sessionID)
        writeInt32(7, sequence)
    }.toByteArray()
}

data class VolcAstResponseMeta(
    val sessionID: String = "",
    val sequence: Int = 0,
    val statusCode: Int = 0,
    val message: String = "",
) {
    companion object {
        internal fun decode(reader: VolcAstProtoReader): VolcAstResponseMeta {
            var sessionID = ""
            var sequence = 0
            var statusCode = 0
            var message = ""
            while (reader.hasMore) {
                val (field, wire) = reader.readTag()
                when {
                    field == 1 && wire == 2 -> sessionID = reader.readString()
                    field == 2 && wire == 0 -> sequence = reader.readInt32()
                    field == 3 && wire == 0 -> statusCode = reader.readInt32()
                    field == 4 && wire == 2 -> message = reader.readString()
                    else -> reader.skip(wire)
                }
            }
            return VolcAstResponseMeta(sessionID, sequence, statusCode, message)
        }
    }
}

data class VolcAstUser(
    val uid: String = "",
    val did: String = "",
) {
    fun encode(): ByteArray = VolcAstProtoWriter().apply {
        writeString(1, uid)
        writeString(2, did)
    }.toByteArray()
}

data class VolcAstAudio(
    val format: String = "",
    val codec: String = "",
    val rate: Int = 0,
    val bits: Int = 0,
    val channel: Int = 0,
    val binaryData: ByteArray = ByteArray(0),
) {
    fun encode(): ByteArray = VolcAstProtoWriter().apply {
        writeString(4, format)
        writeString(5, codec)
        writeInt32(7, rate)
        writeInt32(8, bits)
        writeInt32(9, channel)
        writeBytes(14, binaryData)
    }.toByteArray()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is VolcAstAudio) return false
        return format == other.format && codec == other.codec && rate == other.rate &&
            bits == other.bits && channel == other.channel && binaryData.contentEquals(other.binaryData)
    }

    override fun hashCode(): Int {
        var result = format.hashCode()
        result = 31 * result + codec.hashCode()
        result = 31 * result + rate
        result = 31 * result + bits
        result = 31 * result + channel
        result = 31 * result + binaryData.contentHashCode()
        return result
    }
}

data class VolcAstReqParams(
    val mode: String = "",
    val sourceLanguage: String = "",
    val targetLanguage: String = "",
    val speakerID: String = "",
) {
    fun encode(): ByteArray = VolcAstProtoWriter().apply {
        writeString(1, mode)
        writeString(2, sourceLanguage)
        writeString(3, targetLanguage)
        writeString(4, speakerID)
    }.toByteArray()
}

data class VolcAstTranslateRequest(
    val requestMeta: VolcAstRequestMeta? = null,
    val event: Int = VolcAstEventType.NONE,
    val user: VolcAstUser? = null,
    val sourceAudio: VolcAstAudio? = null,
    val targetAudio: VolcAstAudio? = null,
    val request: VolcAstReqParams? = null,
    val denoise: Boolean? = null,
) {
    fun encode(): ByteArray = VolcAstProtoWriter().apply {
        if (requestMeta != null) writeMessage(1, requestMeta.encode())
        writeInt32(2, event)
        if (user != null) writeMessage(3, user.encode())
        if (sourceAudio != null) writeMessage(4, sourceAudio.encode())
        if (targetAudio != null) writeMessage(5, targetAudio.encode())
        if (request != null) writeMessage(6, request.encode())
        if (denoise != null) writeBool(7, denoise, omitDefault = false)
    }.toByteArray()
}

data class VolcAstTranslateResponse(
    val responseMeta: VolcAstResponseMeta? = null,
    val event: Int = VolcAstEventType.NONE,
    val data: ByteArray = ByteArray(0),
    val text: String = "",
    val startTime: Int = 0,
    val endTime: Int = 0,
    val spkChg: Boolean = false,
    val mutedDurationMs: Int = 0,
) {
    val hasErrorStatus: Boolean
        get() {
            val code = responseMeta?.statusCode ?: 0
            return code != 0 && code != STATUS_SUCCESS && code != STATUS_OK_ALT
        }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is VolcAstTranslateResponse) return false
        return responseMeta == other.responseMeta && event == other.event &&
            data.contentEquals(other.data) && text == other.text &&
            startTime == other.startTime && endTime == other.endTime &&
            spkChg == other.spkChg && mutedDurationMs == other.mutedDurationMs
    }

    override fun hashCode(): Int {
        var result = responseMeta?.hashCode() ?: 0
        result = 31 * result + event
        result = 31 * result + data.contentHashCode()
        result = 31 * result + text.hashCode()
        result = 31 * result + startTime
        result = 31 * result + endTime
        result = 31 * result + spkChg.hashCode()
        result = 31 * result + mutedDurationMs
        return result
    }

    companion object {
        const val STATUS_SUCCESS = 20_000_000
        const val STATUS_OK_ALT = 21_000

        fun decode(bytes: ByteArray): VolcAstTranslateResponse {
            val reader = VolcAstProtoReader(bytes)
            var meta: VolcAstResponseMeta? = null
            var event = VolcAstEventType.NONE
            var data = ByteArray(0)
            var text = ""
            var startTime = 0
            var endTime = 0
            var spkChg = false
            var mutedDurationMs = 0
            while (reader.hasMore) {
                val (field, wire) = reader.readTag()
                when {
                    field == 1 && wire == 2 -> meta = VolcAstResponseMeta.decode(reader.readSubmessage())
                    field == 2 && wire == 0 -> event = reader.readInt32()
                    field == 3 && wire == 2 -> data = reader.readBytes()
                    field == 4 && wire == 2 -> text = reader.readString()
                    field == 5 && wire == 0 -> startTime = reader.readInt32()
                    field == 6 && wire == 0 -> endTime = reader.readInt32()
                    field == 7 && wire == 0 -> spkChg = reader.readBool()
                    field == 8 && wire == 0 -> mutedDurationMs = reader.readInt32()
                    else -> reader.skip(wire)
                }
            }
            return VolcAstTranslateResponse(meta, event, data, text, startTime, endTime, spkChg, mutedDurationMs)
        }
    }
}

/** Merges streaming AST subtitle updates whether a cluster emits incremental deltas or cumulative prefixes. */
object VolcAstSubtitleMerger {
    private const val RIGHT_NO_SPACE = ",.;:!?)]}，。、；：！？）】》"
    private const val LEFT_NO_SPACE = "([{（【《"

    fun merge(existing: String, incoming: String): String {
        if (incoming.isEmpty()) return existing
        if (existing.isEmpty()) return incoming
        if (incoming.startsWith(existing)) return incoming
        if (existing.startsWith(incoming)) return existing
        return if (shouldInsertSpace(existing.last(), incoming.first())) "$existing $incoming" else existing + incoming
    }

    private fun shouldInsertSpace(left: Char, right: Char): Boolean {
        if (left.isWhitespace() || right.isWhitespace()) return false
        if (right in RIGHT_NO_SPACE || left in LEFT_NO_SPACE) return false
        val leftAscii = left in '0'..'9' || left in 'A'..'Z' || left in 'a'..'z' || left in ",.;:!?"
        val rightAscii = right in '0'..'9' || right in 'A'..'Z' || right in 'a'..'z'
        return leftAscii && rightAscii
    }
}
