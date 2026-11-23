package com.localrecorder.shengjian

import android.content.Context
import android.content.pm.ApplicationInfo
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.localrecorder.live.Cancellable
import com.localrecorder.live.EndCause
import com.localrecorder.live.LiveSession
import com.localrecorder.live.LiveTranslateClient
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.LiveTranslateException
import com.localrecorder.live.LiveTransport
import com.localrecorder.live.SessionPlatform
import com.localrecorder.live.SessionSnapshot
import com.localrecorder.live.SessionState
import com.localrecorder.live.SpeechOutput
import com.localrecorder.live.SubtitleRow
import com.localrecorder.sessions.SessionExport
import com.localrecorder.sessions.SessionRecord
import com.localrecorder.sessions.SessionRecorder
import com.localrecorder.sessions.SessionSummary
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONObject
import java.io.File
import java.time.ZoneId
import java.util.UUID
import java.util.concurrent.Executor

data class UiState(
    val session: SessionSnapshot = SessionSnapshot(),
    val config: LiveTranslateConfig = LiveTranslateConfig(),
    val options: AppOptions = AppOptions(),
    val hasKey: Boolean = false,
    val testing: Boolean = false,
    val testSucceeded: Boolean? = null,
    val settingsMessage: String = "",
    /** Saved sessions plus the one being recorded, most recently updated first. */
    val sessions: List<SessionSummary> = emptyList(),
    /** The session on screen; null for a new, not yet started one. */
    val selectedId: String? = null,
    /** The selected session when it is not the one being recorded; null while it loads. */
    val viewed: SessionRecord? = null,
    val viewError: String = "",
    val recordingId: String? = null,
    /** Earlier segments of the session being recorded, shown above the live rows. */
    val recordingPrefix: List<SubtitleRow> = emptyList(),
) {
    val status: String get() = session.status.ifEmpty { "就绪 · 目标语言 ${config.languageName}" }
    val viewingRecording: Boolean get() = recordingId != null && selectedId == recordingId
    val selectedTitle: String? get() = selectedId?.let { id -> sessions.firstOrNull { it.id == id }?.title ?: viewed?.title }
}

/**
 * The Android side of [LiveSession] (microphone, speech player, foreground service, network and
 * audio-routing callbacks) plus settings and saved sessions. Everything runs on the main thread; the
 * session logic itself lives in `:core` and is tested there.
 */
class SessionController(private val context: Context) : SessionPlatform {
    private val settings = SettingsStore(context)
    private val secrets = SecretStore(context)
    private val main = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { main.post(it) }
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val routing = AudioRouting(audioManager)

    /** Debug builds accept ws://127.0.0.1 to run against tests/mock_livetranslate_server.py (adb reverse). */
    private val allowLocalhost = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0

    private val _ui = MutableStateFlow(UiState())
    val ui: StateFlow<UiState> = _ui.asStateFlow()

    private var config = settings.load()
    private var options = settings.loadOptions()
    private val engine = LiveSession(this, ::render)
    private val zone: ZoneId get() = ZoneId.systemDefault()
    private val library = SessionLibrary(File(context.filesDir, "sessions"), main) { message -> engine.notice(message) }
    private val recorder = SessionRecorder({ System.currentTimeMillis() }, ::schedule, ZoneId.systemDefault(), object : SessionRecorder.Sink {
        override fun save(record: SessionRecord) = library.save(record, options.saveSessions)
        override fun ended(id: String, record: SessionRecord?) = recordingEnded(id, record)
    })
    private var recordingSummary: SessionSummary? = null
    private var microphone: MicrophoneSource? = null
    private var player: SpeechPlayer? = null
    private var tester: LiveTranslateClient? = null
    private var monitoringNetwork = false

    // Ongoing notification: the latest translation of this session, at most one update per second.
    private var firstRowKey: String? = null
    private var notified = ""
    private var notifiedAt = 0L
    private var notificationPending = false
    private val notificationUpdate = Runnable {
        notificationPending = false
        pushNotification()
    }

    init {
        _ui.update { it.copy(config = config, options = options, hasKey = secrets.has(config.keyAccount)) }
        library.onChange = ::publishSessions
    }

    /**
     * Starts recording into the selected session (a new segment) or, with nothing selected, into a new
     * session. The caller has already obtained RECORD_AUDIO.
     */
    fun start() {
        if (engine.snapshot.state != SessionState.IDLE) return
        val state = _ui.value
        val base = state.selectedId?.let { id -> state.viewed?.takeIf { it.id == id } ?: return }
        // The live list shows only this recording; earlier rows come from the saved session.
        engine.clear()
        val record = recorder.begin(base, UUID.randomUUID().toString(), config.language)
        val prefix = base?.takeIf { it.rows.isNotEmpty() }?.let {
            it.subtitleRows(zone) + SubtitleRow("seg:live", "", true, "", true, SessionExport.continuedMarker(record.segments.last().startedAtMs, zone))
        }.orEmpty()
        _ui.update { it.copy(selectedId = record.id, viewed = null, viewError = "", recordingId = record.id, recordingPrefix = prefix) }
        publishSessions()
        engine.start(config, secrets.get(config.keyAccount).orEmpty(), options.autoReconnect)
        if (engine.snapshot.state == SessionState.IDLE) recorder.finish()
    }

    fun stop() = engine.stop()

    /** Writes pending rows now (the app goes to the background). */
    fun flush() = recorder.flush()

    /** Shows a session; null shows a new, empty one. Recording continues in its own session. */
    fun select(id: String?) {
        _ui.update { it.copy(selectedId = id, viewed = null, viewError = "") }
        if (id == null || id == _ui.value.recordingId) return
        library.load(id) { record ->
            if (_ui.value.selectedId != id) return@load
            _ui.update { it.copy(viewed = record, viewError = if (record == null) "无法读取该会话：文件可能已删除、损坏或来自更新的版本" else "") }
        }
    }

    /** A blank title restores the automatic one. */
    fun rename(id: String, title: String) {
        if (id == _ui.value.recordingId) {
            recorder.rename(title)
            publishSessions()
            return
        }
        library.rename(id, title, zone, options.saveSessions) { renamed ->
            if (renamed != null && _ui.value.selectedId == id) _ui.update { it.copy(viewed = renamed) }
        }
    }

    /** The session being recorded cannot be deleted. */
    fun delete(id: String) {
        if (id == _ui.value.recordingId) return
        library.delete(id)
        if (_ui.value.selectedId == id) select(null)
    }

    fun deleteAll() {
        if (_ui.value.recordingId != null) return
        library.deleteAll()
        select(null)
    }

    /** The full session for export; [done] gets null when it cannot be read. */
    fun exportRecord(id: String, done: (SessionRecord?) -> Unit) {
        if (id == _ui.value.recordingId) done(recorder.record) else library.load(id, done)
    }

    /** Writes an export to a document the user picked; [done] runs on the main thread. */
    fun writeDocument(uri: android.net.Uri, text: String, done: (Boolean) -> Unit) {
        library.background {
            val ok = try {
                context.contentResolver.openOutputStream(uri)?.use { it.write(text.toByteArray(Charsets.UTF_8)) } != null
            } catch (_: Exception) {
                false
            }
            main.post { done(ok) }
        }
    }

    fun subtitleStartMs(key: String): Long? {
        val state = _ui.value
        return if (state.viewingRecording) recorder.firstSeenAtMs(key) ?: recorder.base?.subtitleStartMs(key)
        else state.viewed?.subtitleStartMs(key)
    }

    fun stopPlayback() = engine.stopPlayback()
    fun dismissMessages() = engine.dismissMessages()

    /** Saves settings; a blank key keeps the key already saved for this endpoint. */
    fun saveSettings(draft: LiveTranslateConfig, key: String, draftOptions: AppOptions): Boolean {
        if (engine.snapshot.state != SessionState.IDLE) {
            _ui.update { it.copy(settingsMessage = "转写进行中，停止后再修改设置") }
            return false
        }
        return try {
            if (key.isNotBlank()) secrets.put(draft.normalized(allowLocalhost).keyAccount, key.trim())
            val saved = settings.save(draft, allowLocalhost)
            settings.saveOptions(draftOptions)
            config = saved
            options = draftOptions
            _ui.update {
                it.copy(config = saved, options = draftOptions, hasKey = secrets.has(saved.keyAccount), settingsMessage = "已保存", testSucceeded = null)
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

    /** Keys are stored under the normalized address. */
    fun hasKey(endpoint: String): Boolean {
        val draft = LiveTranslateConfig(endpoint = endpoint)
        val account = try {
            draft.normalized(allowLocalhost).keyAccount
        } catch (_: LiveTranslateException) {
            draft.keyAccount
        }
        return secrets.has(account)
    }

    /** Establishes a session without capturing or sending audio. */
    fun testConnection(draft: LiveTranslateConfig, key: String) {
        if (_ui.value.testing || engine.snapshot.state != SessionState.IDLE) return
        val draftConfig = try {
            draft.normalized(allowLocalhost)
        } catch (e: LiveTranslateException) {
            _ui.update { it.copy(testSucceeded = false, settingsMessage = e.message.orEmpty()) }
            return
        }
        val secret = key.trim().ifEmpty { secrets.get(draftConfig.keyAccount).orEmpty() }
        lateinit var probe: LiveTranslateClient
        probe = LiveTranslateClient(object : LiveTranslateClient.Listener {
            override fun onReady() = probe.finish()
            override fun onEvent(event: JSONObject) = Unit
            override fun onEnd(error: String?, recoverable: Boolean, cause: EndCause) {
                if (tester !== probe) return
                tester = null
                _ui.update { it.copy(testing = false, testSucceeded = error == null, settingsMessage = error ?: "连接成功：会话已建立并确认配置，未发送音频") }
            }
        }, mainExecutor, finishTimeoutMs = 10_000, allowLocalhost = allowLocalhost)
        try {
            probe.connect(draftConfig, secret)
        } catch (e: LiveTranslateException) {
            _ui.update { it.copy(testSucceeded = false, settingsMessage = e.message.orEmpty()) }
            return
        }
        tester = probe
        _ui.update { it.copy(testing = true, testSucceeded = null, settingsMessage = "正在测试连接…") }
    }

    private fun recordingEnded(id: String, record: SessionRecord?) {
        if (record == null) library.delete(id)
        recordingSummary = null
        _ui.update {
            val selected = it.selectedId == id
            it.copy(
                recordingId = null,
                recordingPrefix = emptyList(),
                selectedId = if (selected && record == null) null else it.selectedId,
                viewed = if (selected) record else it.viewed,
            )
        }
        publishSessions()
    }

    private fun publishSessions() {
        val saved = library.summaries()
        val current = recorder.record?.summary
        recordingSummary = current
        val sessions = if (current == null) saved else listOf(current) + saved.filter { it.id != current.id }
        _ui.update { it.copy(sessions = sessions) }
    }

    private fun render(snapshot: SessionSnapshot) {
        recorder.observe(snapshot)
        _ui.update { it.copy(session = snapshot) }
        if (recorder.record?.summary != recordingSummary) publishSessions()
        if (snapshot.state == SessionState.IDLE || notificationPending) return
        val wait = notifiedAt + 1_000 - SystemClock.elapsedRealtime()
        if (wait <= 0) {
            pushNotification()
        } else {
            notificationPending = true
            main.postDelayed(notificationUpdate, wait)
        }
    }

    private fun pushNotification() {
        val snapshot = engine.snapshot
        if (snapshot.state == SessionState.IDLE) return
        val title = if (snapshot.state == SessionState.RECONNECTING) "声笺正在重新连接…" else RecordingService.DEFAULT_TITLE
        val latest = snapshot.rows.asReversed().asSequence()
            .takeWhile { it.key != firstRowKey }
            .firstOrNull { it.translation.isNotEmpty() }
        val text = latest?.translation ?: RecordingService.DEFAULT_TEXT
        val content = "$title\n$text"
        if (content == notified) return
        if (RecordingService.update(context, title, text)) {
            notified = content
            notifiedAt = SystemClock.elapsedRealtime()
        }
    }

    // SessionPlatform

    override fun post(block: () -> Unit) {
        main.post(block)
    }

    override fun schedule(delayMs: Long, block: () -> Unit): Cancellable {
        val task = Runnable(block)
        main.postDelayed(task, delayMs)
        return Cancellable { main.removeCallbacks(task) }
    }

    override fun transport(listener: LiveTranslateClient.Listener): LiveTransport =
        LiveTranslateClient(listener, mainExecutor, allowLocalhost = allowLocalhost)

    override fun startCapture(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit) {
        val notices = mutableListOf<String>()
        var headset: AudioDeviceInfo? = null
        if (options.bluetoothMicrophone) {
            headset = routing.startBluetoothMicrophone()
            if (headset == null) notices += "未找到可用的蓝牙耳机麦克风，已改用手机麦克风"
        }
        // Translated speech from the loudspeaker would be captured and translated again.
        val loudspeaker = config.audioOutput && headset == null && !routing.hasHeadphones()
        val source = MicrophoneSource(onChunk, onError, communication = loudspeaker || headset != null, preferredDevice = headset)
        try {
            source.start()
        } catch (e: Exception) {
            routing.stopBluetoothMicrophone()
            throw e
        }
        microphone = source
        if (loudspeaker) {
            notices += if (source.echoCancelled) "未检测到耳机：已启用回声消除，外放的译音仍可能被再次收录，建议佩戴耳机"
            else "未检测到耳机，本机也不支持回声消除：外放的译音可能被再次收录，建议佩戴耳机"
        }
        audioManager.registerAudioRecordingCallback(recordingCallback, main)
        if (notices.isNotEmpty()) engine.notice(notices.joinToString("\n"))
    }

    override fun stopCapture() {
        main.removeCallbacks(silenceCheck)
        audioManager.unregisterAudioRecordingCallback(recordingCallback)
        microphone?.stop()
        microphone = null
        releaseRouting()
    }

    override fun speech(): SpeechOutput {
        lateinit var created: SpeechPlayer
        created = SpeechPlayer(
            audioManager, main, voiceRoute = routing.bluetoothActive,
            onFocusLost = {
                if (player === created) engine.interruptPlayback("通话或其他应用占用了音频输出，已停止译音；字幕继续更新")
            },
            onStopped = {
                if (player === created) {
                    player = null
                    releaseRouting()
                }
            },
        )
        player = created
        return created
    }

    override fun sessionActive(active: Boolean) {
        if (active) {
            firstRowKey = engine.snapshot.rows.lastOrNull()?.key
            notified = ""
            RecordingService.start(context)
            if (!monitoringNetwork) {
                connectivity.registerDefaultNetworkCallback(networkCallback, main)
                monitoringNetwork = true
            }
        } else {
            if (monitoringNetwork) {
                monitoringNetwork = false
                connectivity.unregisterNetworkCallback(networkCallback)
            }
            main.removeCallbacks(notificationUpdate)
            notificationPending = false
            RecordingService.stop(context)
        }
    }

    /** The Bluetooth headset stays selected until both capture and the tail of the speech are done. */
    private fun releaseRouting() {
        if (microphone == null && player == null) routing.stopBluetoothMicrophone()
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = engine.networkAvailable(network.networkHandle)
        override fun onLost(network: Network) = engine.networkLost()
    }

    // A call or another recorder with priority silences this capture (reported on Android 10+).
    private val silenceCheck = Runnable {
        engine.captureInterrupted("麦克风被通话或其他应用占用，已停止录音；已有文字已保留")
    }

    private val recordingCallback = object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs: List<AudioRecordingConfiguration>) {
            val session = microphone?.sessionId ?: return
            val silenced = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                configs.any { it.clientAudioSessionId == session && it.isClientSilenced }
            main.removeCallbacks(silenceCheck)
            // Brief silencing (e.g. a voice assistant hotword) is tolerated.
            if (silenced) main.postDelayed(silenceCheck, 2_000)
        }
    }
}
