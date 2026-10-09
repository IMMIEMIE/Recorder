package com.localrecorder.shengjian

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.localrecorder.live.LiveTranslateClient
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.LiveTranslateEvents
import com.localrecorder.live.LiveTranslateException
import com.localrecorder.live.LiveTranslatePlaybackQueue
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONObject
import java.util.concurrent.Executor

enum class SessionState { IDLE, CONNECTING, RECORDING, FINISHING }

data class SubtitleRow(
    val key: String,
    val source: String,
    val sourceDone: Boolean,
    val translation: String,
    val translationDone: Boolean,
)

data class UiState(
    val state: SessionState = SessionState.IDLE,
    val config: LiveTranslateConfig = LiveTranslateConfig(),
    val hasKey: Boolean = false,
    val rows: List<SubtitleRow> = emptyList(),
    val status: String = "",
    val error: String = "",
    val notice: String = "",
    val playing: Boolean = false,
    val testing: Boolean = false,
    val settingsMessage: String = "",
)

/**
 * Owns the LiveTranslate session, microphone and speech player. All state changes happen on the
 * main thread; transcripts live only in memory (nothing is persisted).
 */
class SessionController(private val context: Context) {
    private val settings = SettingsStore(context)
    private val secrets = SecretStore(context)
    private val main = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { main.post(it) }

    private val _ui = MutableStateFlow(UiState())
    val ui: StateFlow<UiState> = _ui.asStateFlow()

    private var config = settings.load()
    private val history = mutableListOf<SubtitleRow>()
    private var events = LiveTranslateEvents()
    private var session = 0
    private var client: LiveTranslateClient? = null
    private var microphone: MicrophoneSource? = null
    private var player: SpeechPlayer? = null
    private var playback: LiveTranslatePlaybackQueue? = null
    private var tester: LiveTranslateClient? = null

    init {
        _ui.update { it.copy(config = config, hasKey = secrets.has(config.keyAccount), status = readyStatus()) }
    }

    private fun readyStatus() = "就绪 · 目标语言 ${config.languageName}"

    /** Starts a session; the caller has already obtained RECORD_AUDIO. */
    fun start() {
        if (_ui.value.state != SessionState.IDLE) return
        val key = secrets.get(config.keyAccount).orEmpty()
        val token = ++session
        events = LiveTranslateEvents()
        val next = LiveTranslateClient(SessionListener(token), mainExecutor)
        try {
            next.connect(config, key)
        } catch (e: LiveTranslateException) {
            _ui.update { it.copy(error = e.message.orEmpty()) }
            return
        }
        client = next
        stopPlayback()
        if (config.audioOutput) playback = LiveTranslatePlaybackQueue(config.playbackTiming)
        _ui.update { it.copy(state = SessionState.CONNECTING, status = "正在连接 LiveTranslate…", error = "", notice = "") }
        try {
            RecordingService.start(context)
        } catch (e: Exception) {
            next.cancel()
            end("无法启动前台录音服务，请在应用位于前台时开始")
        }
    }

    /** Stops capture; the server still delivers the tail before the session ends. */
    fun stop() {
        when (_ui.value.state) {
            SessionState.CONNECTING -> {
                client?.cancel()
                end(null)
            }
            SessionState.RECORDING -> {
                // Joins the capture thread, so every chunk is queued before session.finish.
                microphone?.stop()
                microphone = null
                client?.finish()
                _ui.update { it.copy(state = SessionState.FINISHING, status = "正在等待尾句结果…") }
            }
            else -> Unit
        }
    }

    fun clear() {
        if (_ui.value.state != SessionState.IDLE) return
        history.clear()
        events = LiveTranslateEvents()
        publishRows()
    }

    fun exportText(): String = _ui.value.rows.joinToString("\n\n") { row ->
        listOf(row.source, row.translation).filter { it.isNotBlank() }.joinToString("\n")
    }

    fun stopPlayback() {
        player?.stop()
        player = null
        _ui.update { it.copy(playing = false) }
    }

    fun dismissMessages() = _ui.update { it.copy(error = "", notice = "") }

    /** Saves settings; a blank key keeps the key already saved for this endpoint. */
    fun saveSettings(draft: LiveTranslateConfig, key: String): Boolean {
        if (_ui.value.state != SessionState.IDLE) {
            _ui.update { it.copy(settingsMessage = "转写进行中，停止后再修改设置") }
            return false
        }
        return try {
            val saved = settings.save(draft)
            if (key.isNotBlank()) secrets.put(saved.keyAccount, key.trim())
            config = saved
            _ui.update {
                it.copy(config = saved, hasKey = secrets.has(saved.keyAccount), settingsMessage = "已保存", status = readyStatus())
            }
            true
        } catch (e: LiveTranslateException) {
            _ui.update { it.copy(settingsMessage = e.message.orEmpty()) }
            false
        } catch (e: Exception) {
            _ui.update { it.copy(settingsMessage = "保存失败：${e.javaClass.simpleName}") }
            false
        }
    }

    fun hasKey(endpoint: String): Boolean = secrets.has(LiveTranslateConfig(endpoint = endpoint).keyAccount)

    /** Establishes a session without capturing or sending audio. */
    fun testConnection(draft: LiveTranslateConfig, key: String) {
        if (_ui.value.testing || _ui.value.state != SessionState.IDLE) return
        val draftConfig = try {
            draft.normalized()
        } catch (e: LiveTranslateException) {
            _ui.update { it.copy(settingsMessage = e.message.orEmpty()) }
            return
        }
        val secret = key.trim().ifEmpty { secrets.get(draftConfig.keyAccount).orEmpty() }
        lateinit var probe: LiveTranslateClient
        probe = LiveTranslateClient(object : LiveTranslateClient.Listener {
            override fun onReady() = probe.finish()
            override fun onEvent(event: JSONObject) = Unit
            override fun onEnd(error: String?) {
                if (tester !== probe) return
                tester = null
                _ui.update { it.copy(testing = false, settingsMessage = error ?: "连接成功：会话已建立并确认配置，未发送音频") }
            }
        }, mainExecutor, finishTimeoutMs = 10_000)
        try {
            probe.connect(draftConfig, secret)
        } catch (e: LiveTranslateException) {
            _ui.update { it.copy(settingsMessage = e.message.orEmpty()) }
            return
        }
        tester = probe
        _ui.update { it.copy(testing = true, settingsMessage = "正在测试连接…") }
    }

    private inner class SessionListener(private val token: Int) : LiveTranslateClient.Listener {
        override fun onReady() {
            if (token != session || _ui.value.state != SessionState.CONNECTING) return
            if (config.audioOutput) {
                try {
                    player = SpeechPlayer().also { it.start(config.volume) }
                    _ui.update { it.copy(playing = true) }
                } catch (e: Exception) {
                    player = null
                    _ui.update { it.copy(notice = "无法启动译音播放，仅显示字幕") }
                }
            }
            val transport = client ?: return
            val mic = MicrophoneSource(
                onChunk = { pcm -> if (!transport.append(pcm)) main.post { backlog(token) } },
                onError = { message -> main.post { failCapture(token, message) } },
            )
            try {
                mic.start()
            } catch (e: Exception) {
                client?.cancel()
                end(e.message ?: "无法打开麦克风")
                return
            }
            microphone = mic
            _ui.update { it.copy(state = SessionState.RECORDING, status = "正在转写 → ${config.languageName}") }
        }

        override fun onEvent(event: JSONObject) {
            if (token != session) return
            events.apply(event)
            playback?.let { queue ->
                try {
                    for (pcm in queue.consume(event, events)) {
                        if (player?.append(pcm) == false) {
                            stopSpeech("译音播放积压超过 30 秒，已停止播放；字幕继续更新")
                            break
                        }
                    }
                } catch (e: LiveTranslateException) {
                    stopSpeech(e.message.orEmpty())
                }
            }
            publishRows()
        }

        override fun onEnd(error: String?) {
            if (token != session) return
            end(error)
        }
    }

    private fun backlog(token: Int) {
        if (token != session || _ui.value.state != SessionState.RECORDING) return
        failCapture(token, "网络发送积压过多，已停止录音；已有文字已保留")
    }

    private fun failCapture(token: Int, message: String) {
        if (token != session || _ui.value.state != SessionState.RECORDING) return
        microphone?.stop()
        microphone = null
        client?.cancel()
        end(message)
    }

    private fun stopSpeech(message: String) {
        playback = null
        stopPlayback()
        _ui.update { it.copy(notice = message) }
    }

    private fun end(error: String?) {
        microphone?.stop()
        microphone = null
        client = null
        playback = null
        // Freeze this session's rows; later sessions append below them.
        history.addAll(currentRows())
        events = LiveTranslateEvents()
        session++
        player?.let { speech ->
            speech.finish { main.post { if (player === speech) stopPlayback() } }
        }
        _ui.update {
            it.copy(state = SessionState.IDLE, status = readyStatus(), error = error.orEmpty())
        }
        publishRows()
        RecordingService.stop(context)
    }

    private fun currentRows(): List<SubtitleRow> {
        val prefix = "$session:"
        val rows = events.order.mapNotNull { id ->
            val row = events.rows[id] ?: return@mapNotNull null
            val translation = events.translation(row)
            if (row.source.text.isEmpty() && translation.text.isEmpty()) return@mapNotNull null
            SubtitleRow(prefix + id, row.source.text, row.source.done, translation.text, translation.done)
        }
        // Translations whose source association has not arrived yet.
        val pending = events.unmatchedOutputs.map { (id, part) ->
            SubtitleRow(prefix + "out:" + id, "", false, part.text, part.done)
        }
        return rows + pending
    }

    private fun publishRows() {
        val rows = history + currentRows()
        _ui.update { it.copy(rows = rows) }
    }
}
