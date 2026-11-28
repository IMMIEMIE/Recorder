package com.localrecorder.shengjian

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import com.localrecorder.live.AudioSourceMode
import com.localrecorder.live.Cancellable
import com.localrecorder.live.ConversationSession
import com.localrecorder.live.DialogueTurns
import com.localrecorder.live.EndCause
import com.localrecorder.live.LiveMessage
import com.localrecorder.live.LiveServiceProfile
import com.localrecorder.live.LiveSessionEvent
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
import com.localrecorder.sessions.SessionText
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
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
    val systemAudioSupported: Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q,
    val overlayPermissionGranted: Boolean = false,
    val startingProjection: Boolean = false,
) {
    val viewingRecording: Boolean get() = recordingId != null && selectedId == recordingId
    val selectedTitle: String? get() = selectedId?.let { id -> sessions.firstOrNull { it.id == id }?.title ?: viewed?.title }

    /** Dialogue mode always captures microphone only; exiting dialogue restores the selected source mode. */
    val effectiveAudioMode: AudioSourceMode
        get() = when {
            dialogueMode -> AudioSourceMode.MICROPHONE
            !systemAudioSupported -> AudioSourceMode.MICROPHONE
            else -> options.audioSourceMode
        }
}

/**
 * The Android side of [ConversationSession] (microphone, system playback capture, audio mixing,
 * speech player, foreground service, floating subtitle overlay, network and audio-routing callbacks)
 * plus settings and saved sessions. Everything runs on the main thread; the session logic itself
 * lives in `:core` and is tested there.
 */
class SessionController(private val context: Context) : SessionPlatform {
    private val settings = SettingsStore(context)
    private val secrets = SecretStore(context)
    private val main = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { main.post(it) }
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val projectionManager = context.getSystemService(MediaProjectionManager::class.java)
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
    private var playbackSource: PlaybackAudioSource? = null
    private var mixedSource: MixedAudioSource? = null
    private var activeProjection: MediaProjection? = null
    private var releasingProjection = false
    private var recordingCallbackRegistered = false
    private var activeCaptureMode = AudioSourceMode.MICROPHONE
    private var player: SpeechPlayer? = null
    private var tester: LiveTransport? = null
    private var monitoringNetwork = false

    private data class PendingProjection(val resultCode: Int, val data: Intent, val mode: AudioSourceMode)
    private var pendingProjection: PendingProjection? = null
    private var stagedProjection: PendingProjection? = null
    private val pendingProjectionTimeout = Runnable {
        if (pendingProjection != null) onForegroundServiceFailed()
    }

    private var appInForeground = false
    private var pendingEnableOverlayAfterPermission = false

    private val overlay = FloatingSubtitleOverlay(
        appContext = context.applicationContext,
        onToggleBilingual = { setFloatingBilingual(!options.floatingBilingual) },
        onOpenApp = {
            val open = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            context.startActivity(open)
        },
        onStopSession = { stop() },
        onCloseOverlay = { setFloatingSubtitleEnabled(false) },
        onPositionChanged = { x, y -> saveOverlayPosition(x, y) },
    )

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
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && options.audioSourceMode.usesSystemAudio) {
            options = options.copy(audioSourceMode = AudioSourceMode.MICROPHONE)
            settings.saveOptions(options)
        }
        val canOverlay = Settings.canDrawOverlays(context)
        if (!options.floatingSubtitleUserSet) {
            val expected = options.audioSourceMode.usesSystemAudio && canOverlay
            if (options.floatingSubtitle != expected) {
                options = options.copy(floatingSubtitle = expected)
                settings.saveOptions(options)
            }
        }
        _ui.update {
            it.copy(
                config = config,
                options = options,
                hasKey = secrets.has(config.keyAccount),
                dialogueLanguageA = a,
                dialogueLanguageB = b,
                systemAudioSupported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q,
                overlayPermissionGranted = canOverlay,
            )
        }
        configureMode()
        library.onChange = ::publishSessions
    }

    /**
     * Starts microphone recording into the selected session (or a new session). The caller has
     * already obtained RECORD_AUDIO.
     */
    fun start() {
        if (engine.snapshot.state != SessionState.IDLE || pendingProjection != null) return
        activeCaptureMode = AudioSourceMode.MICROPHONE
        stagedProjection = null
        startEngineSession()
    }

    /**
     * Starts a system audio or mixed session using the MediaProjection consent result.
     * On Android 14+ (targetSdk 35), RecordingService MUST enter the foreground with
     * FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION before MediaProjectionManager.getMediaProjection()
     * is invoked, so we wait for RecordingService.onStartCommand() to confirm foreground entry.
     */
    fun startWithProjection(resultCode: Int, data: Intent) {
        if (engine.snapshot.state != SessionState.IDLE || pendingProjection != null) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            engine.notice(LiveMessage.SystemAudioUnsupported)
            return
        }
        val state = _ui.value
        val mode = state.effectiveAudioMode
        if (!mode.usesSystemAudio) {
            start()
            return
        }
        if (state.selectedId != null && state.viewed?.id != state.selectedId) return
        pendingProjection = PendingProjection(resultCode, data, mode)
        _ui.update { it.copy(startingProjection = true) }
        main.removeCallbacks(pendingProjectionTimeout)
        main.postDelayed(pendingProjectionTimeout, PROJECTION_FGS_TIMEOUT_MS)
        try {
            RecordingService.start(context, mode)
        } catch (_: Exception) {
            onForegroundServiceFailed()
        }
    }

    internal fun onForegroundServiceStarted(mode: AudioSourceMode) {
        val pending = pendingProjection ?: return
        main.removeCallbacks(pendingProjectionTimeout)
        pendingProjection = null
        _ui.update { it.copy(startingProjection = false) }
        activeCaptureMode = pending.mode
        stagedProjection = pending
        startEngineSession()
        if (engine.snapshot.state == SessionState.IDLE) {
            stagedProjection = null
            releaseProjection()
            RecordingService.stop(context)
        }
    }

    internal fun onForegroundServiceFailed() {
        main.removeCallbacks(pendingProjectionTimeout)
        val hadPending = pendingProjection != null
        pendingProjection = null
        stagedProjection = null
        _ui.update { it.copy(startingProjection = false) }
        if (hadPending) {
            RecordingService.stop(context)
            engine.notice(LiveMessage.ForegroundServiceFailed)
        }
    }

    internal fun onRecordingServiceDestroyed() {
        overlay.hide()
        if (pendingProjection != null) {
            main.removeCallbacks(pendingProjectionTimeout)
            pendingProjection = null
            stagedProjection = null
            _ui.update { it.copy(startingProjection = false) }
        }
    }

    private fun startEngineSession() {
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

    fun stop() {
        if (pendingProjection != null) {
            main.removeCallbacks(pendingProjectionTimeout)
            pendingProjection = null
            stagedProjection = null
            _ui.update { it.copy(startingProjection = false) }
            RecordingService.stop(context)
            return
        }
        engine.stop()
    }

    /** Writes pending rows now (the app goes to the background). */
    fun flush() = recorder.flush()

    fun setAppForeground(foreground: Boolean) {
        appInForeground = foreground
        syncOverlay()
    }

    fun setAudioSourceMode(mode: AudioSourceMode) {
        if (engine.snapshot.state != SessionState.IDLE || _ui.value.startingProjection) return
        if (mode.usesSystemAudio && Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            engine.notice(LiveMessage.SystemAudioUnsupported)
            return
        }
        val canOverlay = Settings.canDrawOverlays(context)
        val nextFloating = if (options.floatingSubtitleUserSet) options.floatingSubtitle else (mode.usesSystemAudio && canOverlay)
        val next = options.copy(
            audioSourceMode = mode,
            floatingSubtitle = nextFloating,
        )
        options = next
        settings.saveOptions(next)
        _ui.update { it.copy(options = next, overlayPermissionGranted = canOverlay) }
        syncOverlay()
    }

    fun setFloatingSubtitleEnabled(enabled: Boolean) {
        val next = options.copy(floatingSubtitle = enabled, floatingSubtitleUserSet = true)
        options = next
        settings.saveOptions(next)
        _ui.update { it.copy(options = next, overlayPermissionGranted = Settings.canDrawOverlays(context)) }
        syncOverlay()
    }

    fun setFloatingBilingual(bilingual: Boolean) {
        val next = options.copy(floatingBilingual = bilingual)
        options = next
        settings.saveOptions(next)
        _ui.update { it.copy(options = next) }
        syncOverlay()
    }

    fun markPendingOverlayPermission() {
        pendingEnableOverlayAfterPermission = true
    }

    fun refreshOverlayPermission() {
        val granted = Settings.canDrawOverlays(context)
        if (granted && pendingEnableOverlayAfterPermission) {
            pendingEnableOverlayAfterPermission = false
            setFloatingSubtitleEnabled(true)
            return
        }
        if (!granted) pendingEnableOverlayAfterPermission = false
        if (!options.floatingSubtitleUserSet) {
            val expected = options.audioSourceMode.usesSystemAudio && granted
            if (options.floatingSubtitle != expected) {
                val next = options.copy(floatingSubtitle = expected)
                options = next
                settings.saveOptions(next)
            }
        }
        _ui.update { it.copy(options = options, overlayPermissionGranted = granted) }
        syncOverlay()
    }

    fun notifySystemAudioDenied() {
        engine.notice(LiveMessage.SystemAudioPermissionDenied)
    }

    private fun saveOverlayPosition(x: Int, y: Int) {
        val next = options.copy(floatingOffsetX = x, floatingOffsetY = y)
        options = next
        settings.saveOptions(next)
        _ui.update { it.copy(options = next) }
    }

    private fun syncOverlay() {
        val snapshot = engine.snapshot
        val active = snapshot.state != SessionState.IDLE
        val showForMode = if (options.floatingSubtitleUserSet) options.floatingSubtitle else (activeCaptureMode.usesSystemAudio && options.floatingSubtitle)
        if (active && !appInForeground && showForMode && Settings.canDrawOverlays(context)) {
            overlay.showOrUpdate(
                snapshot = snapshot,
                bilingual = options.floatingBilingual,
                savedX = options.floatingOffsetX,
                savedY = options.floatingOffsetY,
            )
        } else {
            overlay.hide()
        }
    }

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
        if (_ui.value.dialogueMode == enabled || engine.snapshot.state == SessionState.FINISHING || _ui.value.startingProjection) return
        // Dialogue mode always uses microphone only; never switch mid-session from system/mixed capture.
        if (enabled && engine.snapshot.state != SessionState.IDLE && activeCaptureMode.usesSystemAudio) return
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
        if (active && (key.isNotBlank() || draft.profile.id != config.profile.id || draft.endpoint != config.endpoint || draft.profile.protocolID != config.profile.protocolID)) {
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
                it.copy(
                    config = saved,
                    options = draftOptions,
                    hasKey = secrets.has(saved.keyAccount),
                    settingsMessage = localized.getString(R.string.saved),
                    testSucceeded = null,
                    overlayPermissionGranted = Settings.canDrawOverlays(context),
                )
            }
            if (active) engine.updatePreferences(saved, draftOptions.autoReconnect)
            if (targetChanged) configureMode()
            syncOverlay()
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

    /** Refreshes localized foreground notifications, overlay and clears stale transient messages after a locale/theme change. */
    fun onInterfaceLanguageChanged() {
        _ui.update { it.copy(settingsMessage = "", testSucceeded = null) }
        RecordingService.refreshChannel(context)
        if (engine.snapshot.state != SessionState.IDLE) {
            notified = ""
            pushNotification()
        }
        syncOverlay()
    }

    /** Keys are stored under the normalized address. */
    fun hasKey(endpoint: String): Boolean = hasKey(LiveServiceProfile(endpoint = endpoint))

    fun hasKey(profile: LiveServiceProfile): Boolean {
        val draft = LiveTranslateConfig(catalog = com.localrecorder.live.LiveServiceCatalog(profile))
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
        syncOverlay()
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
        val text = latest?.translation ?: localized.getString(RecordingService.notificationTextRes(activeCaptureMode))
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
        when (activeCaptureMode) {
            AudioSourceMode.MICROPHONE -> startMicrophoneCapture(onChunk, onError)
            AudioSourceMode.SYSTEM_AUDIO -> startSystemAudioCapture(onChunk, onError, mixed = false)
            AudioSourceMode.SYSTEM_AND_MIC -> startSystemAudioCapture(onChunk, onError, mixed = true)
        }
    }

    private fun startMicrophoneCapture(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit) {
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
        recordingCallbackRegistered = true
        emitNotices(notices)
    }

    private fun startSystemAudioCapture(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit, mixed: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw LiveTranslateException(LiveMessage.SystemAudioUnsupported)
        }
        val staged = stagedProjection ?: throw LiveTranslateException(LiveMessage.SystemAudioOpenFailed)
        stagedProjection = null
        val projection = try {
            projectionManager?.getMediaProjection(staged.resultCode, staged.data)
        } catch (_: Exception) {
            null
        } ?: throw LiveTranslateException(LiveMessage.SystemAudioOpenFailed)

        // Android 14+ requires registering a MediaProjection.Callback before starting capture.
        projection.registerCallback(projectionCallback, main)
        activeProjection = projection

        val notices = mutableListOf<LiveMessage>()
        if (!mixed) {
            val source = PlaybackAudioSource(
                mediaProjection = projection,
                onChunk = onChunk,
                onError = { msg -> onError(localizedContext().formatLiveMessage(msg)) },
                onSilent = { main.post { if (playbackSource != null) engine.notice(LiveMessage.SystemAudioSilentNotice) } },
            )
            try {
                source.start()
            } catch (e: Exception) {
                releaseProjection()
                throw e
            }
            playbackSource = source
        } else {
            var headset: AudioDeviceInfo? = null
            if (options.bluetoothMicrophone) {
                headset = routing.startBluetoothMicrophone()
                if (headset == null) notices += LiveMessage.BluetoothFallback
            }
            val hasHeadphones = headset != null || routing.hasHeadphones()
            val loudspeaker = config.audioOutput && !hasHeadphones
            val source = MixedAudioSource(
                mediaProjection = projection,
                onChunk = onChunk,
                onError = { msg -> onError(localizedContext().formatLiveMessage(msg)) },
                onSystemSilent = { main.post { if (mixedSource != null) engine.notice(LiveMessage.SystemAudioSilentNotice) } },
                communication = loudspeaker || headset != null,
                preferredDevice = headset,
            )
            try {
                source.start()
            } catch (e: Exception) {
                releaseProjection()
                routing.stopBluetoothMicrophone()
                throw e
            }
            mixedSource = source
            if (!hasHeadphones) {
                notices += LiveMessage.MixedModeHeadphonesNotice
            }
            audioManager.registerAudioRecordingCallback(recordingCallback, main)
            recordingCallbackRegistered = true
        }
        emitNotices(notices)
    }

    private fun emitNotices(notices: List<LiveMessage>) {
        if (notices.size == 1) engine.notice(notices.single())
        else if (notices.size > 1) engine.notice(LiveMessage.Composite(notices, "\n"))
    }

    override fun stopCapture() {
        main.removeCallbacks(silenceCheck)
        if (recordingCallbackRegistered) {
            recordingCallbackRegistered = false
            audioManager.unregisterAudioRecordingCallback(recordingCallback)
        }
        microphone?.stop()
        microphone = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            playbackSource?.stop()
            playbackSource = null
            mixedSource?.stop()
            mixedSource = null
        }
        stagedProjection = null
        releaseProjection()
        releaseRouting()
    }

    private fun releaseProjection() {
        val projection = activeProjection ?: return
        activeProjection = null
        releasingProjection = true
        try {
            projection.unregisterCallback(projectionCallback)
        } catch (_: Exception) {
        }
        try {
            projection.stop()
        } catch (_: Exception) {
        }
        releasingProjection = false
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
            if (!RecordingService.isRunningFor(activeCaptureMode)) {
                RecordingService.start(context, activeCaptureMode)
            }
            if (!monitoringNetwork) {
                connectivity.registerDefaultNetworkCallback(networkCallback, main)
                monitoringNetwork = true
            }
            syncOverlay()
        } else {
            if (monitoringNetwork) {
                monitoringNetwork = false
                connectivity.unregisterNetworkCallback(networkCallback)
            }
            main.removeCallbacks(notificationUpdate)
            notificationPending = false
            RecordingService.stop(context)
            syncOverlay()
        }
    }

    /** The Bluetooth headset stays selected until both capture and the tail of the speech are done. */
    private fun releaseRouting() {
        if (microphone == null && mixedSource == null && player == null) routing.stopBluetoothMicrophone()
    }

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            if (releasingProjection) return
            activeProjection = null
            engine.captureInterrupted(LiveMessage.SystemAudioProjectionStopped)
        }
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
            val session = microphone?.sessionId
                ?: (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) mixedSource?.micSessionId else null)
                ?: return
            val silenced = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                configs.any { it.clientAudioSessionId == session && it.isClientSilenced }
            main.removeCallbacks(silenceCheck)
            // Brief silencing (e.g. a voice assistant hotword) is tolerated.
            if (silenced) main.postDelayed(silenceCheck, 2_000)
        }
    }

    private companion object {
        const val PROJECTION_FGS_TIMEOUT_MS = 5_000L
    }
}
