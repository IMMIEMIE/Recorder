package com.localrecorder.live

import org.json.JSONObject

// Feed the existing wire fixtures through the same adapter as the WebSocket client.
internal fun LiveTransport.Listener.onEvent(event: JSONObject) { Qwen38Adapter.decode(event)?.let(::onEvent) }
internal fun LiveTranslateEvents.apply(event: JSONObject) { Qwen38Adapter.decode(event)?.let(::apply) }
internal fun LiveTranslateAudioDecoder.consume(event: JSONObject) = Qwen38Adapter.decode(event)?.let(::consume)
internal fun LiveTranslatePlaybackQueue.consume(event: JSONObject, transcripts: LiveTranslateEvents) =
    Qwen38Adapter.decode(event)?.let { consume(it, transcripts) }.orEmpty()
