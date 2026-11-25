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
import com.localrecorder.live.ConversationSession
import com.localrecorder.live.DialogueTurns
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
import com.localrecorder.live.LiveSessionEvent
import com.localrecorder.live.LiveServiceProfile
import com.localrecorder.live.LiveMessage
import com.localrecorder.sessions.SessionText
import java.io.File
import java.time.ZoneId
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.Executors

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
    val dialogueMode: Boolean = false,
    val dialogueLanguageA: String = "zh",
    val dialogueLanguageB: String = "en",
) {
    val viewingRecording: Boolean get() = recordingId != null && selectedId == recordingId
    val selectedTitle: String? get() = selectedId?.let { id -> sessions.firstOrNull { it.id == id }?.title ?: viewed?.title }
}

/**
 * The Android side of [ConversationSession] (microphone, speech player, foreground service, network and
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

    private fun localizedContext(): Context = AppLocale.localizedContext(context)

    private var config = settings.load()
    private var options = settings.loadOptions()
    private val languageWorker = Executors.newSingleThreadExecutor { Thread(it, "dialogue-language") }
    private val engine = ConversationSession(
        this,
        identifyLanguage = { text, a, b, done ->
            languageWorker.execute {
                val result = try {
                    dialogueLanguage(context, text, a, b)
                } catch (_: RuntimeException) {
                    DialogueTurns.scriptLanguage(text, a, b)
                }
                main.post { done(result) }
            }
        },
        onChange = ::render,
    )
    private val zone: ZoneId get() = ZoneId.systemDefault()
    private val library = SessionLibrary(File(context.filesDir, "sessions"), main) { message -> engine.notice(message) }
    private val recorder = SessionRecorder({ System.currentTimeMillis() }, ::schedule, ZoneId.systemDefault(), object : SessionRecorder.Sink {
        override fun save(record: SessionRecord) = library.save(record, options.saveSessions)
        override fun ended(id: String, record: SessionRecord?) = recordingEnded(id, record)
    })
    private var recordingSummary: SessionSummary? = null
    private var microphone: MicrophoneSource? = null
    private var player: SpeechPlayer? = null
    private var tester: LiveTransport? = null
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
        val (a, b) = settings.loadDialogueLanguages()
        _ui.update { it.copy(config = config, options = options, hasKey = secrets.has(config.keyAccount),
            dialogueLanguageA = a, dialogueLanguageB = b) }
        configureMode()
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
            val startedAt = record.segments.last().startedAtMs
            val stamp = SessionText.stamp(startedAt, "yyyy-MM-dd HH:mm", zone)
            it.subtitleRows(zone) + SubtitleRow(
                "seg:live", "", true, "", true,
                SessionExport.continuedMarker(startedAt, zone),
                markerMessage = LiveMessage.ContinuedMarker(stamp),
            )
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
            _ui.update { it.copy(viewed = record, viewError = if (record == null) localizedContext().getString(R.string.session_read_detail_error) else "") }
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

    fun setDialogueMode(enabled: Boolean) {
        if (_ui.value.dialogueMode == enabled || engine.snapshot.state == SessionState.FINISHING) return
        _ui.update { it.copy(dialogueMode = enabled) }
        configureMode()
    }

    fun setDialogueLanguages(a: String, b: String) {
        if (engine.snapshot.state == SessionState.FINISHING || a == b ||
            listOf(a, b).any { code -> LiveTranslateConfig.LANGUAGES.none { it.first == code } }) return
        settings.saveDialogueLanguages(a, b)
        _ui.update { it.copy(dialogueLanguageA = a, dialogueLanguageB = b) }
        configureMode()
    }

    fun setTargetLanguage(language: String) {
        if (config.language != language) saveSettings(config.copy(language = language), "", options)
    }

    private fun configureMode() {
        val state = _ui.value
        engine.configure(state.dialogueMode, state.dialogueLanguageA, state.dialogueLanguageB, config.language)
    }

    /** Saves settings; a blank key keeps the key already saved for this endpoint. */
    fun saveSettings(draft: LiveTranslateConfig, key: String, draftOptions: AppOptions): Boolean {
        val localized = localizedContext()
        val active = engine.snapshot.state != SessionState.IDLE
        if (active && (key.isNotBlank() || draft.profile.id != config.profile.id || draft.endpoint != config.endpoint)) {
            _ui.update { it.copy(settingsMessage = localized.getString(R.string.dialogue_service_locked)) }
            return false
        }
        return try {
            val saved = draft.normalized(allowLocalhost)
            if (key.isNotBlank()) secrets.put(saved.keyAccount, key.trim())
            settings.save(saved, allowLocalhost)
            settings.saveOptions(draftOptions)
            val targetChanged = config.language != saved.language
            config = saved
            options = draftOptions
            _ui.update {
                it.copy(config = saved, options = draftOptions, hasKey = secrets.has(saved.keyAccount), settingsMessage = localized.getString(R.string.saved), testSucceeded = null)
            }
            if (active) engine.updatePreferences(saved, draftOptions.autoReconnect)
            if (targetChanged) configureMode()
            true
        } catch (e: LiveTranslateException) {
            _ui.update { it.copy(settingsMessage = localized.formatLiveMessage(e.liveMessage)) }
            false
        } catch (e: Exception) {
            _ui.update { it.copy(settingsMessage = localized.getString(R.string.err_save_failed_detail, e.javaClass.simpleName)) }
            false
        }
    }

    fun selectProfile(profile: LiveServiceProfile): Boolean {
        return saveSettings(config.copy(catalog = config.catalog.using(profile)), "", options)
    }

    fun switchRecordingProfile(profile: LiveServiceProfile) {
        if (engine.snapshot.state != SessionState.RECORDING || profile.id == config.profile.id) return
        try {
            val next = config.copy(catalog = config.catalog.using(profile)).normalized(allowLocalhost)
            val key = secrets.get(next.keyAccount)
            if (key.isNullOrBlank()) { engine.notice(LiveMessage.ProfileKeyMissing(profile.name)); return }
            config = settings.save(next, allowLocalhost)
            engine.switchProfile(config, key)
            _ui.update { it.copy(config = config, hasKey = true) }
        } catch (e: LiveTranslateException) { engine.notice(e.liveMessage) }
    }

    /** Refreshes localized foreground notifications and clears stale transient messages after an interface language switch. */
    fun onInterfaceLanguageChanged() {
        _ui.update { it.copy(settingsMessage = "", testSucceeded = null) }
        RecordingService.refreshChannel(context)
        if (engine.snapshot.state != SessionState.IDLE) {
            notified = ""
            pushNotification()
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

    fun clearSettingsFeedback() {
        _ui.update { it.copy(settingsMessage = "", testSucceeded = null) }
    }

    /** Establishes a session without capturing or sending audio. */
    fun testConnection(draft: LiveTranslateConfig, key: String) {
        if (_ui.value.testing || engine.snapshot.state != SessionState.IDLE) return
        val localized = localizedContext()
        val draftConfig = try {
            draft.normalized(allowLocalhost)
        } catch (e: LiveTranslateException) {
            _ui.update { it.copy(testSucceeded = false, settingsMessage = localized.formatLiveMessage(e.liveMessage)) }
            return
        }
        val secret = key.trim().ifEmpty { secrets.get(draftConfig.keyAccount).orEmpty() }
        lateinit var probe: LiveTransport
        probe = transport(draftConfig, object : LiveTransport.Listener {
            override fun onReady() = probe.finish()
            override fun onEvent(event: LiveSessionEvent) = Unit
            override fun onEnd(error: String?, recoverable: Boolean, cause: EndCause) {
                if (tester !== probe) return
                tester = null
                val msg = localizedContext()
                val formatted = cause.errorMessage?.let { msg.formatLiveMessage(it) } ?: error ?: msg.getString(R.string.test_succeeded)
                _ui.update { it.copy(testing = false, testSucceeded = error == null, settingsMessage = formatted) }
            }
        })
        try {
            probe.connect(draftConfig, secret)
        } catch (e: LiveTranslateException) {
            _ui.update { it.copy(testSucceeded = false, settingsMessage = localized.formatLiveMessage(e.liveMessage)) }
            return
        }
        tester = probe
        _ui.update { it.copy(testing = true, testSucceeded = null, settingsMessage = localized.getString(R.string.test_in_progress)) }
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
        val localized = localizedContext()
        val title = localized.getString(if (snapshot.state == SessionState.RECONNECTING) R.string.live_notification_reconnecting else R.string.live_notification_recording)
        val latest = snapshot.rows.asReversed().asSequence()
            .takeWhile { it.key != firstRowKey }
            .firstOrNull { it.translation.isNotEmpty() }
        val text = latest?.translation ?: localized.getString(R.string.live_notification_audio)
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

    override fun transport(configuration: LiveTranslateConfig, listener: LiveTransport.Listener): LiveTransport =
        configuration.profile.transport(listener, mainExecutor, allowLocalhost)

    override fun startCapture(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit) {
        val notices = mutableListOf<LiveMessage>()
        var headset: AudioDeviceInfo? = null
        if (options.bluetoothMicrophone) {
            headset = routing.startBluetoothMicrophone()
            if (headset == null) notices += LiveMessage.BluetoothFallback
        }
        // Translated speech from the loudspeaker would be captured and translated again.
        val loudspeaker = config.audioOutput && headset == null && !routing.hasHeadphones()
        val source = MicrophoneSource(
            onChunk,
            onError = { msg -> onError(localizedContext().formatLiveMessage(msg)) },
            communication = loudspeaker || headset != null,
            preferredDevice = headset,
        )
        try {
            source.start()
        } catch (e: Exception) {
            routing.stopBluetoothMicrophone()
            throw e
        }
        microphone = source
        if (loudspeaker) {
            notices += if (source.echoCancelled) LiveMessage.LoudspeakerEchoCancelled
            else LiveMessage.LoudspeakerNoEchoCancel
        }
        audioManager.registerAudioRecordingCallback(recordingCallback, main)
        if (notices.size == 1) engine.notice(notices.single())
        else if (notices.size > 1) engine.notice(LiveMessage.Composite(notices, "\n"))
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
                if (player === created) engine.interruptPlayback(LiveMessage.AudioFocusLost)
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
        engine.captureInterrupted(LiveMessage.MicOccupied)
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
