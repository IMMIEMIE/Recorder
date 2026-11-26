package com.localrecorder.shengjian

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.localrecorder.live.AudioSourceMode
import com.localrecorder.live.SessionState
import com.localrecorder.live.SubtitleRow
import com.localrecorder.sessions.ExportContent
import com.localrecorder.sessions.ExportFormat
import com.localrecorder.sessions.SessionExport
import com.localrecorder.sessions.SessionGroup
import com.localrecorder.sessions.SessionRecord
import com.localrecorder.sessions.SessionSummary
import com.localrecorder.sessions.SessionText
import com.localrecorder.shengjian.ui.theme.Design
import com.localrecorder.shengjian.ui.theme.LocalStatusColors
import com.localrecorder.shengjian.ui.theme.ShengjianTheme
import java.time.ZoneId
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppLocale.wrapContext(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(R.style.Base_Theme_Shengjian)
        super.onCreate(savedInstanceState)
        window.setBackgroundDrawableResource(R.color.background)
        enableEdgeToEdge()
        AppLocale.syncFromSystem(this)
        val controller = (application as ShengjianApp).controller
        setContent {
            LocalizedApp(activity = this) {
                ShengjianTheme {
                    App(controller)
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        (application as ShengjianApp).controller.setAppForeground(true)
    }

    override fun onResume() {
        super.onResume()
        val controller = (application as ShengjianApp).controller
        if (AppLocale.syncFromSystem(this)) {
            controller.onInterfaceLanguageChanged()
        }
        controller.refreshOverlayPermission()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        AppLocale.syncFromSystem(this)
        (application as ShengjianApp).controller.onInterfaceLanguageChanged()
    }

    override fun onStop() {
        super.onStop()
        val controller = (application as ShengjianApp).controller
        controller.setAppForeground(false)
        // In the background the process may be killed at any time: write finalized rows now.
        controller.flush()
    }

    fun keepScreenOn(on: Boolean) {
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}

@Composable
private fun LocalizedApp(activity: ComponentActivity, content: @Composable () -> Unit) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        content()
        return
    }
    val language by AppLocale.language.collectAsStateWithLifecycle()
    val baseConfig = LocalConfiguration.current
    val (localizedConfig, localizedContext) = remember(baseConfig, language) {
        AppLocale.localizedOverlay(activity, baseConfig, language)
    }
    CompositionLocalProvider(
        LocalConfiguration provides localizedConfig,
        LocalContext provides localizedContext,
    ) {
        content()
    }
}

/** Above this the binder transaction of ACTION_SEND may fail; such exports go to a file instead. */
private const val MAX_SHARE_CHARS = 200_000

private enum class AppRoute { WELCOME, MAIN, SETTINGS }

@Composable
private fun App(controller: SessionController) {
    val ui by controller.ui.collectAsStateWithLifecycle()
    var showSettings by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    val welcomePrefs = remember { context.getSharedPreferences("appearance", android.content.Context.MODE_PRIVATE) }
    var showWelcome by rememberSaveable { mutableStateOf(!welcomePrefs.getBoolean("welcomeSeen", false) && !ui.hasKey && ui.session.state == SessionState.IDLE) }
    fun finishWelcome(configure: Boolean) {
        welcomePrefs.edit().putBoolean("welcomeSeen", true).apply()
        showWelcome = false
        showSettings = configure
    }

    val route = when {
        showWelcome -> AppRoute.WELCOME
        showSettings -> AppRoute.SETTINGS
        else -> AppRoute.MAIN
    }
    AnimatedContent(
        targetState = route,
        transitionSpec = {
            val forward = targetState.ordinal > initialState.ordinal
            val enter = fadeIn(tween(240, easing = FastOutSlowInEasing)) +
                slideInHorizontally(tween(240, easing = FastOutSlowInEasing)) { width -> if (forward) width / 14 else -width / 14 }
            val exit = fadeOut(tween(180, easing = FastOutSlowInEasing)) +
                slideOutHorizontally(tween(180, easing = FastOutSlowInEasing)) { width -> if (forward) -width / 18 else width / 18 }
            enter togetherWith exit
        },
        label = "appRoute",
    ) { target ->
        when (target) {
            AppRoute.WELCOME -> {
                BackHandler { finishWelcome(false) }
                Welcome(settings = { finishWelcome(true) }, later = { finishWelcome(false) })
            }
            AppRoute.SETTINGS -> SettingsScreen(controller, ui, onBack = { showSettings = false })
            AppRoute.MAIN -> MainScreen(controller, ui, onSettings = { showSettings = true })
        }
    }
}

/** What a session menu (sidebar long press or the top bar) asks for. */
private sealed interface SessionAction {
    data class Rename(val id: String, val title: String) : SessionAction
    data class Delete(val id: String, val title: String) : SessionAction
    data class Export(val record: SessionRecord) : SessionAction
}

@Composable
private fun MainScreen(controller: SessionController, ui: UiState, onSettings: () -> Unit) {
    val context = LocalContext.current
    var action by remember { mutableStateOf<SessionAction?>(null) }
    // Text waiting for the "save to file" picker; lost if the activity is recreated meanwhile.
    var pendingDocument by remember { mutableStateOf<String?>(null) }
    val onDocument: (android.net.Uri?) -> Unit = { uri ->
        val text = pendingDocument
        pendingDocument = null
        if (uri != null && text != null) {
            controller.writeDocument(uri, text) { ok ->
                Toast.makeText(context, if (ok) R.string.saved else R.string.save_failed, Toast.LENGTH_SHORT).show()
            }
        }
    }
    val saveTxt = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(ExportFormat.TXT.mimeType), onDocument)
    val saveMarkdown = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(ExportFormat.MARKDOWN.mimeType), onDocument)

    val menu = SessionMenu(
        rename = { id, title -> action = SessionAction.Rename(id, title) },
        delete = { id, title -> action = SessionAction.Delete(id, title) },
        export = { id ->
            controller.exportRecord(id) { record ->
                if (record == null) {
                    Toast.makeText(context, R.string.read_failed, Toast.LENGTH_SHORT).show()
                } else {
                    action = SessionAction.Export(record)
                }
            }
        },
    )

    if (LocalConfiguration.current.screenWidthDp.dp >= Design.wide) {
        Row(Modifier.fillMaxSize()) {
            Column(
                Modifier
                    .width(280.dp)
                    .fillMaxHeight()
                    .background(MaterialTheme.colorScheme.surfaceContainerLow)
                    .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Vertical + WindowInsetsSides.Start)),
            ) {
                SessionList(ui, menu, onSettings, onSelect = controller::select)
            }
            VerticalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Box(Modifier.weight(1f)) { TranscriptScreen(controller, ui, menu, onSettings, onOpenList = null) }
        }
    } else {
        val drawer = rememberDrawerState(DrawerValue.Closed)
        val scope = rememberCoroutineScope()
        BackHandler(enabled = drawer.isOpen) { scope.launch { drawer.close() } }
        ModalNavigationDrawer(
            drawerState = drawer,
            gesturesEnabled = !ui.dialogueMode || drawer.isOpen,
            drawerContent = {
                ModalDrawerSheet(
                    modifier = Modifier.width(320.dp),
                    drawerContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                ) {
                    SessionList(ui, menu, onSettings, onSelect = { id ->
                        controller.select(id)
                        scope.launch { drawer.close() }
                    })
                }
            },
        ) {
            TranscriptScreen(controller, ui, menu, onSettings, onOpenList = { scope.launch { drawer.open() } })
        }
    }

    when (val current = action) {
        null -> Unit
        is SessionAction.Rename -> RenameDialog(current.title, onDismiss = { action = null }) { title ->
            controller.rename(current.id, title)
            action = null
        }
        is SessionAction.Delete -> ConfirmDialog(
            title = stringResource(R.string.delete_session_question),
            text = stringResource(R.string.delete_session_detail, current.title),
            confirm = stringResource(R.string.delete),
            onDismiss = { action = null },
        ) {
            controller.delete(current.id)
            action = null
        }
        is SessionAction.Export -> ExportDialog(
            current.record,
            onDismiss = { action = null },
            onShare = { name, text ->
                if (text.length > MAX_SHARE_CHARS) {
                    Toast.makeText(context, R.string.share_too_long, Toast.LENGTH_LONG).show()
                } else {
                    val send = Intent(Intent.ACTION_SEND)
                        .setType("text/plain")
                        .putExtra(Intent.EXTRA_TEXT, text)
                        .putExtra(Intent.EXTRA_SUBJECT, name.substringBeforeLast('.'))
                        .putExtra(Intent.EXTRA_TITLE, name)
                    context.startActivity(Intent.createChooser(send, context.getString(R.string.share_session)))
                    action = null
                }
            },
            onSave = { format, name, text ->
                pendingDocument = text
                try {
                    if (format == ExportFormat.TXT) saveTxt.launch(name) else saveMarkdown.launch(name)
                    action = null
                } catch (_: Exception) {
                    pendingDocument = null
                    Toast.makeText(context, R.string.no_file_picker, Toast.LENGTH_LONG).show()
                }
            },
            onCopy = { text ->
                context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText(context.getString(R.string.app_name), text))
                Toast.makeText(context, R.string.copied, Toast.LENGTH_SHORT).show()
                action = null
            },
        )
    }
}

private class SessionMenu(
    val rename: (id: String, title: String) -> Unit,
    val delete: (id: String, title: String) -> Unit,
    val export: (id: String) -> Unit,
)

@Composable
private fun ColumnScope.SessionList(ui: UiState, menu: SessionMenu, onSettings: () -> Unit, onSelect: (String?) -> Unit) {
    val colors = MaterialTheme.colorScheme
    var query by rememberSaveable { mutableStateOf("") }

    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = Design.spaceSm, top = Design.spaceSm, bottom = Design.spaceXs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.session_history), style = Design.title)
            if (ui.sessions.isNotEmpty()) {
                Surface(color = colors.surfaceContainer, shape = CircleShape) {
                    Text(
                        stringResource(R.string.session_count, ui.sessions.size),
                        style = Design.caption,
                        color = colors.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                    )
                }
            }
        }
        Tool(R.drawable.ic_settings, stringResource(R.string.settings), click = onSettings)
    }

    FilledTonalButton(
        onClick = { onSelect(null) },
        shape = RoundedCornerShape(Design.radiusCard),
        colors = ButtonDefaults.filledTonalButtonColors(
            containerColor = colors.primaryContainer,
            contentColor = colors.onPrimaryContainer,
        ),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Design.spaceMd, vertical = Design.spaceSm)
            .heightIn(min = 48.dp),
    ) {
        Glyph(R.drawable.ic_add, Modifier.size(18.dp))
        Spacer(Modifier.width(Design.spaceSm))
        Text(stringResource(R.string.new_session), fontWeight = FontWeight.SemiBold)
    }

    if (ui.sessions.size > 1) {
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            placeholder = { Text(stringResource(R.string.search_sessions), style = MaterialTheme.typography.bodyMedium) },
            leadingIcon = { Glyph(R.drawable.ic_search, Modifier.size(18.dp), tint = colors.onSurfaceVariant) },
            singleLine = true,
            shape = RoundedCornerShape(Design.radiusButton),
            colors = OutlinedTextFieldDefaults.colors(
                unfocusedContainerColor = colors.surfaceContainerLowest,
                focusedContainerColor = colors.surfaceContainerLowest,
                unfocusedBorderColor = colors.outlineVariant,
            ),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Design.spaceMd, vertical = Design.spaceXs),
        )
    }

    if (!ui.options.saveSessions) {
        Text(
            stringResource(R.string.history_off),
            style = MaterialTheme.typography.bodySmall,
            color = colors.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = Design.spaceMd, vertical = Design.spaceXs),
        )
    }
    if (ui.sessions.isEmpty()) {
        Text(
            stringResource(R.string.empty_history),
            style = MaterialTheme.typography.bodyMedium,
            color = colors.onSurfaceVariant,
            modifier = Modifier.padding(Design.spaceMd),
        )
        return
    }
    val filtered = remember(ui.sessions, query) {
        val needle = query.trim()
        if (needle.isEmpty()) ui.sessions else ui.sessions.filter { it.title.contains(needle, ignoreCase = true) }
    }
    if (filtered.isEmpty()) {
        Text(
            stringResource(R.string.no_matching_sessions),
            style = MaterialTheme.typography.bodyMedium,
            color = colors.onSurfaceVariant,
            modifier = Modifier.padding(Design.spaceMd),
        )
        return
    }

    val zone = remember { ZoneId.systemDefault() }
    val now = remember(filtered) { System.currentTimeMillis() }
    val groups = remember(filtered, now) { filtered.groupBy { SessionGroup.of(it.updatedAtMs, now, zone) } }
    LazyColumn(
        Modifier.weight(1f).fillMaxWidth(),
        contentPadding = PaddingValues(bottom = Design.spaceMd),
    ) {
        for ((group, sessions) in groups) {
            item(key = "group:${group.name}", contentType = 0) {
                Text(
                    stringResource(when (group) {
                        SessionGroup.TODAY -> R.string.today
                        SessionGroup.YESTERDAY -> R.string.yesterday
                        SessionGroup.WEEK -> R.string.last_week
                        SessionGroup.EARLIER -> R.string.earlier
                    }),
                    style = MaterialTheme.typography.labelMedium,
                    color = colors.onSurfaceVariant,
                    modifier = Modifier.padding(start = 24.dp, end = 16.dp, top = 12.dp, bottom = 4.dp),
                )
            }
            items(sessions, key = { it.id }, contentType = { 1 }) { session ->
                SessionItem(
                    session,
                    time = SessionText.stamp(session.updatedAtMs, if (group == SessionGroup.TODAY) "HH:mm" else "MM-dd HH:mm", zone),
                    selected = session.id == ui.selectedId,
                    recording = session.id == ui.recordingId,
                    menu = menu,
                    onClick = { onSelect(session.id) },
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionItem(
    session: SessionSummary,
    time: String,
    selected: Boolean,
    recording: Boolean,
    menu: SessionMenu,
    onClick: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    var expanded by remember { mutableStateOf(false) }
    val barColor = colors.primary
    Box(Modifier.padding(horizontal = 12.dp, vertical = 2.dp)) {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 52.dp)
                .clip(RoundedCornerShape(Design.radiusCard))
                .background(if (selected) colors.secondaryContainer else Color.Transparent)
                .drawBehind {
                    if (selected) {
                        val barWidth = 3.dp.toPx()
                        val insetY = 10.dp.toPx()
                        if (size.height > insetY * 2) {
                            drawRoundRect(
                                color = barColor,
                                topLeft = Offset(4.dp.toPx(), insetY),
                                size = Size(barWidth, size.height - insetY * 2),
                                cornerRadius = CornerRadius(barWidth, barWidth),
                            )
                        }
                    }
                }
                .combinedClickable(
                    onLongClick = { expanded = true },
                    onLongClickLabel = stringResource(R.string.session_actions),
                    onClick = onClick,
                )
                .padding(start = 16.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        session.title,
                        style = MaterialTheme.typography.bodyLarge.copy(fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal),
                        color = if (selected) colors.onSecondaryContainer else colors.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (recording) RecordingBadge()
                }
                Text(time, style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
            }
            Box {
                Tool(
                    id = R.drawable.ic_more_vert,
                    label = stringResource(R.string.session_actions),
                    tint = colors.onSurfaceVariant,
                    click = { expanded = true },
                )
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.rename)) }, onClick = {
                        expanded = false
                        menu.rename(session.id, session.title)
                    })
                    DropdownMenuItem(text = { Text(stringResource(R.string.export_session)) }, onClick = {
                        expanded = false
                        menu.export(session.id)
                    })
                    DropdownMenuItem(
                        text = { Text(if (recording) stringResource(R.string.cannot_delete_recording) else stringResource(R.string.delete)) },
                        enabled = !recording,
                        onClick = {
                            expanded = false
                            menu.delete(session.id, session.title)
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun RecordingBadge() {
    val rec = LocalStatusColors.current.recording
    Surface(
        color = rec.copy(alpha = 0.13f),
        shape = CircleShape,
    ) {
        Row(
            Modifier.padding(horizontal = 7.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            PulsingDot(rec, Modifier.size(6.dp))
            Text(stringResource(R.string.recording), style = MaterialTheme.typography.labelSmall, color = rec)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TranscriptScreen(
    controller: SessionController,
    ui: UiState,
    menu: SessionMenu,
    onSettings: () -> Unit,
    onOpenList: (() -> Unit)?,
) {
    val context = LocalContext.current
    val activity = context.findMainActivity()
    val session = ui.session
    val active = session.state != SessionState.IDLE || ui.startingProjection
    val zone = remember { ZoneId.systemDefault() }
    DisposableEffect(active) {
        activity?.keepScreenOn(active)
        onDispose { activity?.keepScreenOn(false) }
    }
    val projectionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val data = result.data
        if (result.resultCode == Activity.RESULT_OK && data != null) {
            controller.startWithProjection(result.resultCode, data)
        } else {
            controller.notifySystemAudioDenied()
        }
    }
    fun launchSystemAudioConsent() {
        val mgr = context.getSystemService(MediaProjectionManager::class.java)
        if (mgr == null) {
            controller.notifySystemAudioDenied()
        } else {
            projectionLauncher.launch(mgr.createScreenCaptureIntent())
        }
    }
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        val mode = controller.ui.value.effectiveAudioMode
        val granted = result[Manifest.permission.RECORD_AUDIO] == true ||
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            val deniedMsg = if (mode == AudioSourceMode.SYSTEM_AUDIO) R.string.err_system_audio_permission_denied else R.string.mic_permission_required
            Toast.makeText(context, deniedMsg, Toast.LENGTH_LONG).show()
        } else if (mode.usesSystemAudio) {
            launchSystemAudioConsent()
        } else {
            controller.start()
        }
    }
    fun requestStart() {
        val mode = controller.ui.value.effectiveAudioMode
        val needed = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
        }.filter { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        when {
            needed.isNotEmpty() -> permissions.launch(needed.toTypedArray())
            mode.usesSystemAudio -> launchSystemAudioConsent()
            else -> controller.start()
        }
    }

    val selectedId = ui.selectedId
    val title = ui.selectedTitle ?: stringResource(R.string.new_session_title)
    val rows: List<SubtitleRow> = when {
        ui.viewingRecording -> ui.recordingPrefix + session.rows
        selectedId == null -> emptyList()
        else -> remember(ui.viewed) { ui.viewed?.subtitleRows(zone).orEmpty() }
    }
    val emptyText = when {
        ui.viewingRecording || (selectedId == null && !active) -> when (ui.effectiveAudioMode) {
            AudioSourceMode.MICROPHONE -> stringResource(R.string.start_hint)
            AudioSourceMode.SYSTEM_AUDIO -> stringResource(R.string.start_hint_system_audio)
            AudioSourceMode.SYSTEM_AND_MIC -> stringResource(R.string.start_hint_mixed)
        }
        selectedId == null -> stringResource(R.string.other_recording)
        ui.viewError.isNotEmpty() -> ui.viewError
        ui.viewed == null -> stringResource(R.string.loading_session)
        else -> stringResource(R.string.empty_session)
    }

    val config = LocalConfiguration.current
    val messages = remember { SnackbarHostState() }
    val errorText = remember(session.error, session.errorMessage, context, config) { context.formatError(session) }
    val noticeText = remember(session.notice, session.noticeMessage, context, config) { context.formatNotice(session) }
    val statusText = remember(session.status, session.statusMessage, context, config) { context.formatStatus(session) }
    val message = errorText.ifBlank { noticeText }
    LaunchedEffect(message) {
        if (message.isNotEmpty()) {
            messages.showSnackbar(
                message,
                withDismissAction = true,
                duration = if (errorText.isEmpty()) SnackbarDuration.Long else SnackbarDuration.Indefinite,
            )
            controller.dismissMessages()
        }
    }
    val startEnabled = session.state != SessionState.FINISHING && (active || selectedId == null || ui.viewed != null)
    val toggleRecording = { if (active) controller.stop() else if (!ui.hasKey) onSettings() else requestStart() }
    fun enterDialogue() {
        if (active && !ui.viewingRecording) controller.select(ui.recordingId)
        controller.setDialogueMode(true)
    }
    var showDialogueCost by rememberSaveable { mutableStateOf(false) }
    var showLanguageSheet by rememberSaveable { mutableStateOf(false) }
    var showOverlayDialog by rememberSaveable { mutableStateOf(false) }
    val appearance = remember(context) { context.getSharedPreferences("appearance", android.content.Context.MODE_PRIVATE) }
    if (showOverlayDialog) {
        OverlayPermissionDialog(
            onDismiss = { showOverlayDialog = false },
            onConfirm = {
                showOverlayDialog = false
                controller.markPendingOverlayPermission()
                openOverlayPermissionSettings(context)
            },
        )
    }
    if (showDialogueCost) {
        AlertDialog(
            onDismissRequest = { showDialogueCost = false },
            title = { Text(stringResource(R.string.dialogue_mode)) },
            text = { Text(stringResource(R.string.dialogue_cost)) },
            confirmButton = {
                TextButton({
                    appearance.edit().putBoolean("dialogueCostSeen", true).apply()
                    showDialogueCost = false
                    enterDialogue()
                }) { Text(stringResource(R.string.dialogue_enter)) }
            },
            dismissButton = { TextButton({ showDialogueCost = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }

    val inDialogue = ui.dialogueMode && (!active || ui.viewingRecording)
    AnimatedContent(
        targetState = inDialogue,
        transitionSpec = {
            (fadeIn(tween(240, easing = FastOutSlowInEasing)) + slideInVertically(tween(240)) { if (targetState) it / 18 else -it / 18 })
                .togetherWith(fadeOut(tween(180)))
        },
        label = "dialogueMode",
    ) { dialogueActive ->
        if (dialogueActive) {
            var facing by remember { mutableStateOf(appearance.getBoolean("dialogueFacing", true)) }
            val exit = { controller.setDialogueMode(false) }
            BackHandler(enabled = session.state != SessionState.FINISHING, onBack = exit)
            DialogueScreen(
                rows, ui.dialogueLanguageA, ui.dialogueLanguageB, session.state, startEnabled,
                ui.config.audioOutput, session.playing,
                when {
                    session.slowNetwork || session.slowService || session.state == SessionState.RECONNECTING -> statusText
                    session.state == SessionState.CONNECTING -> stringResource(R.string.connecting)
                    session.state == SessionState.RECORDING -> stringResource(R.string.recording)
                    else -> ""
                },
                messages, facing,
                toggleFacing = {
                    facing = !facing
                    appearance.edit().putBoolean("dialogueFacing", facing).apply()
                },
                setLanguages = controller::setDialogueLanguages,
                record = toggleRecording,
                exit = exit,
                onSpeech = { controller.saveSettings(ui.config.copy(audioOutput = !ui.config.audioOutput), "", ui.options) },
                stopPlayback = controller::stopPlayback,
                settings = onSettings,
            )
        } else {
            val colors = MaterialTheme.colorScheme
            val statusColors = LocalStatusColors.current
            Scaffold(
                containerColor = colors.surface,
                snackbarHost = { SnackbarHost(messages) },
                topBar = {
                    Column(Modifier.background(colors.surface).statusBarsPadding().displayCutoutPadding()) {
                        SessionHeader(
                            title = title,
                            openList = onOpenList,
                            statusContent = { StatusPill(session, selectedId != null) },
                        ) {
                            FilledTonalButton(
                                onClick = {
                                    if (appearance.getBoolean("dialogueCostSeen", false)) enterDialogue() else showDialogueCost = true
                                },
                                enabled = session.state != SessionState.FINISHING && !ui.startingProjection && !(active && ui.options.audioSourceMode.usesSystemAudio),
                                shape = CircleShape,
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                                modifier = Modifier.heightIn(min = 40.dp),
                            ) {
                                Glyph(R.drawable.ic_dialogue, Modifier.size(16.dp))
                                Spacer(Modifier.width(5.dp))
                                Text(
                                    stringResource(R.string.dialogue_chip),
                                    style = Design.caption.copy(fontWeight = FontWeight.SemiBold),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            var expanded by remember { mutableStateOf(false) }
                            Box {
                                Tool(R.drawable.ic_more_vert, stringResource(R.string.more_actions), tint = colors.onSurfaceVariant) { expanded = true }
                                DropdownMenu(expanded, { expanded = false }) {
                                    if (selectedId != null) {
                                        DropdownMenuItem(text = { Text(stringResource(R.string.rename_session)) }, onClick = { expanded = false; menu.rename(selectedId, title) })
                                        DropdownMenuItem(text = { Text(stringResource(R.string.export_session)) }, onClick = { expanded = false; menu.export(selectedId) })
                                        DropdownMenuItem(
                                            text = { Text(stringResource(R.string.delete_session)) },
                                            enabled = selectedId != ui.recordingId,
                                            onClick = { expanded = false; menu.delete(selectedId, title) },
                                        )
                                    }
                                    DropdownMenuItem(text = { Text(stringResource(R.string.settings)) }, onClick = { expanded = false; onSettings() })
                                }
                            }
                        }
                        AnimatedVisibility(
                            visible = session.slowService || session.slowNetwork,
                            enter = expandVertically() + fadeIn(),
                            exit = shrinkVertically() + fadeOut(),
                        ) {
                            Surface(
                                color = statusColors.slow.copy(alpha = 0.12f),
                                shape = RoundedCornerShape(Design.radiusButton),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = Design.spaceMd, vertical = Design.spaceXs),
                            ) {
                                Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    if (session.slowService) {
                                        Text(stringResource(R.string.slow_service, ui.config.profile.name), style = Design.caption, color = statusColors.slow)
                                    } else if (session.slowNetwork && statusText.isNotBlank()) {
                                        Text(statusText, style = Design.caption, color = statusColors.slow)
                                    }
                                    ProfileSwitchButtons(ui.config, controller::switchRecordingProfile)
                                }
                            }
                        }
                    }
                },
                bottomBar = {
                    val primaryLabel = when {
                        ui.startingProjection -> stringResource(R.string.cancel_connection)
                        session.state == SessionState.CONNECTING -> stringResource(R.string.cancel_connection)
                        session.state == SessionState.RECONNECTING -> stringResource(R.string.stop_reconnecting)
                        session.state == SessionState.RECORDING -> stringResource(R.string.stop_translation)
                        session.state == SessionState.FINISHING -> stringResource(R.string.finishing)
                        else -> if (selectedId == null) stringResource(R.string.start_live) else stringResource(R.string.resume_recording)
                    }
                    val idleIcon = when (ui.effectiveAudioMode) {
                        AudioSourceMode.MICROPHONE -> R.drawable.ic_mic
                        AudioSourceMode.SYSTEM_AUDIO -> R.drawable.ic_volume_up
                        AudioSourceMode.SYSTEM_AND_MIC -> R.drawable.ic_graphic_eq
                    }
                    Column(Modifier.fillMaxWidth()) {
                        AudioSourceBar(
                            selected = ui.effectiveAudioMode,
                            canSwitch = !active,
                            systemAudioSupported = ui.systemAudioSupported,
                            floatingSubtitleEnabled = ui.options.floatingSubtitle,
                            overlayPermissionGranted = ui.overlayPermissionGranted,
                            onSelect = controller::setAudioSourceMode,
                            onToggleFloatingSubtitle = controller::setFloatingSubtitleEnabled,
                            onRequestOverlayPermission = { showOverlayDialog = true },
                        )
                        BottomActionDock(
                            languageLabel = stringResource(R.string.target_pill, ui.config.languageName),
                            languageEnabled = session.state != SessionState.FINISHING,
                            onOpenLanguage = { showLanguageSheet = true },
                            audioOutput = ui.config.audioOutput,
                            audioEnabled = session.state != SessionState.FINISHING,
                            onToggleAudio = { enabled ->
                                controller.saveSettings(ui.config.copy(audioOutput = enabled), "", ui.options)
                            },
                            playing = session.playing,
                            onStopPlayback = if (session.playing) controller::stopPlayback else null,
                            active = active,
                            primaryLabel = primaryLabel,
                            primaryEnabled = startEnabled,
                            onPrimaryClick = toggleRecording,
                            returnToRecording = if (active && !ui.viewingRecording) ({ controller.select(ui.recordingId) }) else null,
                            idlePrimaryIcon = idleIcon,
                        )
                    }
                },
            ) { padding ->
                Column(Modifier.padding(padding).fillMaxSize()) {
                    if (!ui.hasKey && !active && rows.isEmpty()) {
                        Column(
                            Modifier
                                .fillMaxSize()
                                .verticalScroll(rememberScrollState())
                                .padding(Design.spaceLg),
                            verticalArrangement = Arrangement.Center,
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Box(
                                Modifier
                                    .size(56.dp)
                                    .clip(RoundedCornerShape(Design.radiusCard))
                                    .background(colors.primaryContainer),
                                contentAlignment = Alignment.Center,
                            ) {
                                Glyph(R.drawable.ic_key, Modifier.size(26.dp), tint = colors.onPrimaryContainer)
                            }
                            Text(
                                stringResource(R.string.setup_hint),
                                Modifier.padding(Design.spaceMd),
                                textAlign = TextAlign.Center,
                                color = colors.onSurfaceVariant,
                            )
                            FilledTonalButton(onSettings, shape = RoundedCornerShape(Design.radiusButton)) {
                                Text(stringResource(R.string.setup_service))
                            }
                        }
                    } else {
                        Subtitles(
                            rows = rows,
                            trimmed = ui.viewingRecording && session.trimmed,
                            emptyText = emptyText,
                            modifier = Modifier.weight(1f),
                            sessionId = selectedId,
                            stamp = { key -> controller.subtitleStartMs(key)?.let { SessionText.stamp(it, "HH:mm", zone) } },
                            onCopyRow = { row ->
                                val combined = listOf(row.translation, row.source).filter { it.isNotBlank() }.joinToString("\n")
                                if (combined.isNotBlank()) {
                                    context.getSystemService(ClipboardManager::class.java)
                                        ?.setPrimaryClip(ClipData.newPlainText(context.getString(R.string.app_name), combined))
                                    Toast.makeText(context, R.string.copy_row_copied, Toast.LENGTH_SHORT).show()
                                }
                            },
                        )
                    }
                }
            }
            if (showLanguageSheet) {
                LanguagePickerSheet(
                    title = stringResource(R.string.choose_language),
                    subtitle = stringResource(R.string.language_live_hint),
                    selected = ui.config.language,
                    onSelect = controller::setTargetLanguage,
                    onDismiss = { showLanguageSheet = false },
                )
            }
        }
    }
}

@Composable
private fun Subtitles(
    rows: List<SubtitleRow>,
    trimmed: Boolean,
    emptyText: String,
    modifier: Modifier,
    sessionId: String?,
    stamp: (String) -> String?,
    onCopyRow: ((SubtitleRow) -> Unit)? = null,
) {
    val colors = MaterialTheme.colorScheme
    if (rows.isEmpty()) {
        Column(
            modifier.fillMaxWidth().padding(32.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(emptyText, color = colors.onSurfaceVariant, textAlign = TextAlign.Center)
        }
        return
    }
    val list = rememberLazyListState()
    val scope = rememberCoroutineScope()
    // Newest first in a bottom-anchored list (like a chat): text streaming into the newest row grows upward
    // in place, so following live text needs no scroll calls and the end of a long sentence stays visible.
    val newestFirst = remember(rows) { rows.asReversed() }
    val following by remember { derivedStateOf { list.firstVisibleItemIndex == 0 } }
    // Read during composition, i.e. before the new row is laid out: the list keeps its position by key, so
    // after layout the reader appears one row "behind" even if they were following.
    val wasFollowing = following
    LaunchedEffect(rows.lastOrNull()?.key) {
        if (wasFollowing) list.scrollToItem(0)
    }
    val inspect = LocalInspectionMode.current
    val context = LocalContext.current
    Box(modifier.fillMaxWidth()) {
        LazyColumn(
            Modifier.fillMaxSize(),
            state = list,
            reverseLayout = true,
            contentPadding = PaddingValues(top = 18.dp, bottom = 12.dp),
        ) {
            items(newestFirst, key = { it.key }, contentType = { if (it.marker.isEmpty()) 0 else 1 }) { row ->
                Box(if (inspect) Modifier else Modifier.animateItem()) {
                    if (row.marker.isNotEmpty() || row.markerMessage != null) {
                        Marker(context.formatMarker(row))
                    } else {
                        SubtitleText(
                            row = row,
                            stamp = remember(sessionId, row.key) { stamp(row.key) },
                            onCopy = onCopyRow?.let { cb -> ({ cb(row) }) },
                        )
                    }
                }
            }
            if (trimmed) {
                item(key = "trimmed", contentType = 1) { Marker(stringResource(R.string.earlier_captions)) }
            }
        }

        // Soft top fade edge prevents harsh horizontal slicing of scrolled captions.
        Box(
            Modifier
                .fillMaxWidth()
                .height(24.dp)
                .align(Alignment.TopCenter)
                .background(Brush.verticalGradient(listOf(colors.surface, colors.surface.copy(alpha = 0f)))),
        )

        AnimatedVisibility(
            visible = !following,
            enter = fadeIn(tween(200)) + slideInVertically(tween(240, easing = FastOutSlowInEasing)) { it / 2 },
            exit = fadeOut(tween(160)) + slideOutVertically(tween(180)) { it / 2 },
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 12.dp),
        ) {
            Surface(
                onClick = { scope.launch { list.animateScrollToItem(0) } },
                shape = CircleShape,
                color = colors.surfaceContainerLowest,
                border = BorderStroke(1.dp, colors.outlineVariant),
                shadowElevation = 4.dp,
            ) {
                Row(
                    Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Glyph(R.drawable.ic_arrow_downward, Modifier.size(16.dp), tint = colors.primary)
                    Text(
                        stringResource(R.string.latest),
                        style = Design.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.primary,
                    )
                }
            }
        }
    }
}

@Composable
private fun Marker(text: String) {
    val colors = MaterialTheme.colorScheme
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Design.spaceMd, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        HorizontalDivider(Modifier.weight(1f), color = colors.outlineVariant.copy(alpha = 0.65f))
        Surface(color = colors.surfaceContainer, shape = CircleShape) {
            Text(
                text,
                style = Design.caption,
                color = colors.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
            )
        }
        HorizontalDivider(Modifier.weight(1f), color = colors.outlineVariant.copy(alpha = 0.65f))
    }
}

@Composable
private fun RenameDialog(current: String, onDismiss: () -> Unit, onRename: (String) -> Unit) {
    var title by rememberSaveable { mutableStateOf(current) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.rename_session)) },
        text = {
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                singleLine = true,
                supportingText = { Text(stringResource(R.string.automatic_title)) },
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = { TextButton(onClick = { onRename(title) }) { Text(stringResource(R.string.ok)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
internal fun ConfirmDialog(title: String, text: String, confirm: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(text) },
        confirmButton = {
            TextButton(onClick = onConfirm, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text(confirm) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ExportDialog(
    record: SessionRecord,
    onDismiss: () -> Unit,
    onShare: (name: String, text: String) -> Unit,
    onSave: (format: ExportFormat, name: String, text: String) -> Unit,
    onCopy: (text: String) -> Unit,
) {
    var format by rememberSaveable { mutableStateOf(ExportFormat.TXT) }
    var content by rememberSaveable { mutableStateOf(ExportContent.BILINGUAL) }
    val zone = remember { ZoneId.systemDefault() }
    val rendered = remember(record, format, content) { SessionExport.render(record, format, content, zone) }
    val preview = remember(rendered) { rendered.lines().take(5).joinToString("\n") }
    fun name() = SessionExport.fileName(record, format, zone)
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MaterialTheme.colorScheme.surfaceContainerLow) {
        ExportChoices(
            title = record.title,
            format = format,
            content = content,
            setFormat = { format = it },
            setContent = { content = it },
            preview = preview,
            save = { onSave(format, name(), rendered) },
            share = { onShare(name(), rendered) },
            copy = { onCopy(rendered) },
        )
    }
}

@Composable
internal fun ExportChoices(
    title: String,
    format: ExportFormat,
    content: ExportContent,
    setFormat: (ExportFormat) -> Unit,
    setContent: (ExportContent) -> Unit,
    save: () -> Unit,
    share: () -> Unit,
    copy: () -> Unit,
    preview: String? = null,
) {
    val colors = MaterialTheme.colorScheme
    Column(
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = Design.spaceLg, vertical = Design.spaceSm),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(stringResource(R.string.export_session), style = Design.title)
            Text(stringResource(R.string.export_summary, title), style = Design.caption, color = colors.onSurfaceVariant)
        }
        Segments(stringResource(R.string.format), ExportFormat.entries.map { it.label }, format.ordinal) { setFormat(ExportFormat.entries[it]) }
        Segments(
            stringResource(R.string.content),
            listOf(stringResource(R.string.bilingual), stringResource(R.string.source_only), stringResource(R.string.translation_only)),
            content.ordinal,
        ) { setContent(ExportContent.entries[it]) }

        if (!preview.isNullOrBlank()) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(stringResource(R.string.export_preview), style = Design.caption, color = colors.onSurfaceVariant)
                Surface(
                    color = colors.surfaceContainerLowest,
                    shape = RoundedCornerShape(Design.radiusButton),
                    border = BorderStroke(1.dp, colors.outlineVariant),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        preview,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace, lineHeight = 18.sp),
                        color = colors.onSurfaceVariant,
                        maxLines = 5,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(12.dp),
                    )
                }
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 4.dp, bottom = Design.spaceMd)) {
            Button(
                onClick = save,
                shape = RoundedCornerShape(Design.radiusCard),
                modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
            ) {
                Glyph(R.drawable.ic_upload_file, Modifier.size(18.dp))
                Spacer(Modifier.width(Design.spaceSm))
                Text(stringResource(R.string.save_to_file), fontWeight = FontWeight.SemiBold)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilledTonalButton(
                    onClick = share,
                    shape = RoundedCornerShape(Design.radiusButton),
                    modifier = Modifier.weight(1f).heightIn(min = 48.dp),
                ) {
                    Glyph(R.drawable.ic_share, Modifier.size(17.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.share), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                FilledTonalButton(
                    onClick = copy,
                    shape = RoundedCornerShape(Design.radiusButton),
                    modifier = Modifier.weight(1f).heightIn(min = 48.dp),
                ) {
                    Glyph(R.drawable.ic_content_copy, Modifier.size(17.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.copy_all_text), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}
