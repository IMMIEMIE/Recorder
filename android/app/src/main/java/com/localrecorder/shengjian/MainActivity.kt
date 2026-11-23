package com.localrecorder.shengjian

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
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
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setBackgroundDrawableResource(R.color.background)
        enableEdgeToEdge()
        val controller = (application as ShengjianApp).controller
        setContent {
            ShengjianTheme {
                App(controller)
            }
        }
    }

    override fun onStop() {
        super.onStop()
        // In the background the process may be killed at any time: write finalized rows now.
        (application as ShengjianApp).controller.flush()
    }

    fun keepScreenOn(on: Boolean) {
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}

/** Above this the binder transaction of ACTION_SEND may fail; such exports go to a file instead. */
private const val MAX_SHARE_CHARS = 200_000

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
    when {
        showWelcome -> {
            BackHandler { finishWelcome(false) }
            Welcome(settings = { finishWelcome(true) }, later = { finishWelcome(false) })
        }
        showSettings -> SettingsScreen(controller, ui, onBack = { showSettings = false })
        else -> MainScreen(controller, ui, onSettings = { showSettings = true })
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
            Column(Modifier.width(256.dp).fillMaxHeight().background(MaterialTheme.colorScheme.surfaceContainerLow)
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Vertical + WindowInsetsSides.Start))) {
                SessionList(ui, menu, onSettings, onSelect = controller::select)
            }
            VerticalDivider()
            Box(Modifier.weight(1f)) { TranscriptScreen(controller, ui, menu, onSettings, onOpenList = null) }
        }
    } else {
        val drawer = rememberDrawerState(DrawerValue.Closed)
        val scope = rememberCoroutineScope()
        BackHandler(enabled = drawer.isOpen) { scope.launch { drawer.close() } }
        ModalNavigationDrawer(
            drawerState = drawer,
            drawerContent = {
                ModalDrawerSheet(Modifier.width(320.dp)) {
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
    Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = Design.spaceXs), verticalAlignment = Alignment.CenterVertically) {
        Text(stringResource(R.string.session_history), Modifier.weight(1f), style = Design.title)
        Tool(R.drawable.ic_settings, stringResource(R.string.settings), enabled = ui.session.state == SessionState.IDLE, click = onSettings)
    }
    FilledTonalButton(onClick = { onSelect(null) }, modifier = Modifier.padding(horizontal = Design.spaceMd, vertical = Design.spaceSm)) {
        Glyph(R.drawable.ic_add)
        Spacer(Modifier.width(Design.spaceSm))
        Text(stringResource(R.string.new_session))
    }
    if (!ui.options.saveSessions) {
        Text(
            stringResource(R.string.history_off),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
    }
    if (ui.sessions.isEmpty()) {
        Text(
            stringResource(R.string.empty_history),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(16.dp),
        )
        return
    }
    val zone = remember { ZoneId.systemDefault() }
    val now = remember(ui.sessions) { System.currentTimeMillis() }
    val groups = remember(ui.sessions, now) { ui.sessions.groupBy { SessionGroup.of(it.updatedAtMs, now, zone) } }
    LazyColumn(Modifier.weight(1f).fillMaxWidth()) {
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
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 28.dp, end = 16.dp, top = 12.dp, bottom = 4.dp),
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
private fun SessionItem(session: SessionSummary, time: String, selected: Boolean, recording: Boolean, menu: SessionMenu, onClick: () -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box(Modifier.padding(horizontal = 12.dp, vertical = 2.dp)) {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .clip(MaterialTheme.shapes.medium)
                .background(if (selected) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent)
                .combinedClickable(onLongClick = { expanded = true }, onLongClickLabel = stringResource(R.string.session_actions), onClick = onClick)
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(session.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(time, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (recording) RecordingBadge()
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(text = { Text(stringResource(R.string.rename)) }, onClick = {
                expanded = false
                menu.rename(session.id, session.title)
            })
            DropdownMenuItem(text = { Text(stringResource(R.string.export_session)) }, onClick = {
                expanded = false
                menu.export(session.id)
            })
            DropdownMenuItem(text = { Text(if (recording) stringResource(R.string.cannot_delete_recording) else stringResource(R.string.delete)) }, enabled = !recording, onClick = {
                expanded = false
                menu.delete(session.id, session.title)
            })
        }
    }
}

@Composable
private fun RecordingBadge() {
    Text(
        stringResource(R.string.recording),
        style = MaterialTheme.typography.labelSmall,
        color = LocalStatusColors.current.recording,
        modifier = Modifier
            .padding(start = 8.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerLow)
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
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
    val activity = context as? MainActivity
    val session = ui.session
    val active = session.state != SessionState.IDLE
    val zone = remember { ZoneId.systemDefault() }
    DisposableEffect(active) {
        activity?.keepScreenOn(active)
        onDispose { activity?.keepScreenOn(false) }
    }
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result[Manifest.permission.RECORD_AUDIO] == true || context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) controller.start()
        else Toast.makeText(context, R.string.mic_permission_required, Toast.LENGTH_LONG).show()
    }
    fun requestStart() {
        val needed = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
        }.filter { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (needed.isEmpty()) controller.start() else permissions.launch(needed.toTypedArray())
    }

    val selectedId = ui.selectedId
    val title = ui.selectedTitle ?: stringResource(R.string.new_session_title)
    val rows: List<SubtitleRow> = when {
        ui.viewingRecording -> ui.recordingPrefix + session.rows
        selectedId == null -> emptyList()
        else -> remember(ui.viewed) { ui.viewed?.subtitleRows(zone).orEmpty() }
    }
    val emptyText = when {
        ui.viewingRecording || (selectedId == null && !active) -> stringResource(R.string.start_hint)
        selectedId == null -> stringResource(R.string.other_recording)
        ui.viewError.isNotEmpty() -> ui.viewError
        ui.viewed == null -> stringResource(R.string.loading_session)
        else -> stringResource(R.string.empty_session)
    }

    val messages = remember { SnackbarHostState() }
    val message = session.error.ifBlank { session.notice }
    LaunchedEffect(message) {
        if (message.isNotEmpty()) {
            messages.showSnackbar(message, withDismissAction = true,
                duration = if (session.error.isEmpty()) SnackbarDuration.Long else SnackbarDuration.Indefinite)
            controller.dismissMessages()
        }
    }
    Scaffold(
        snackbarHost = { SnackbarHost(messages) },
        topBar = {
            Column(Modifier.statusBarsPadding().displayCutoutPadding()) {
                SessionHeader(title, onOpenList) {
                    var expanded by remember { mutableStateOf(false) }
                    Box {
                        Tool(R.drawable.ic_more_vert, stringResource(R.string.more_actions)) { expanded = true }
                        DropdownMenu(expanded, { expanded = false }) {
                            if (selectedId != null) {
                                DropdownMenuItem(text = { Text(stringResource(R.string.rename_session)) }, onClick = { expanded = false; menu.rename(selectedId, title) })
                                DropdownMenuItem(text = { Text(stringResource(R.string.export_session)) }, onClick = { expanded = false; menu.export(selectedId) })
                                DropdownMenuItem(text = { Text(stringResource(R.string.delete_session)) }, enabled = selectedId != ui.recordingId,
                                    onClick = { expanded = false; menu.delete(selectedId, title) })
                            }
                            DropdownMenuItem(text = { Text(stringResource(R.string.settings)) }, enabled = !active, onClick = { expanded = false; onSettings() })
                        }
                    }
                }
                SessionStatus(session, ui.config.languageName, selectedId != null)
                if (session.slowService || session.slowNetwork) {
                    Column(Modifier.padding(horizontal = Design.spaceMd)) {
                        if (session.slowService) Text(stringResource(R.string.slow_service, ui.config.profile.name), style = Design.caption)
                        ProfileSwitchButtons(ui.config, controller::switchRecordingProfile)
                    }
                }
                HorizontalDivider()
            }
        },
        bottomBar = {
            Surface(color = MaterialTheme.colorScheme.surfaceContainerLow) {
                Column(Modifier.fillMaxWidth().navigationBarsPadding().displayCutoutPadding()
                    .padding(horizontal = Design.spaceMd, vertical = Design.spaceSm)) {
                    SpeechToggle(ui.config.audioOutput, !active, { enabled ->
                        controller.saveSettings(ui.config.copy(audioOutput = enabled), "", ui.options)
                    }, if (session.playing) controller::stopPlayback else null)
                    if (active && !ui.viewingRecording) {
                        TextButton({ controller.select(ui.recordingId) }) { Text(stringResource(R.string.return_to_recording)) }
                    }
                    val label = when (session.state) {
                        SessionState.CONNECTING -> stringResource(R.string.cancel_connection)
                        SessionState.RECONNECTING -> stringResource(R.string.stop_reconnecting)
                        SessionState.RECORDING -> stringResource(R.string.stop_translation)
                        SessionState.FINISHING -> stringResource(R.string.finishing)
                        SessionState.IDLE -> if (selectedId == null) stringResource(R.string.start_live) else stringResource(R.string.resume_recording)
                    }
                    Button(
                        onClick = { if (active) controller.stop() else if (!ui.hasKey) onSettings() else requestStart() },
                        enabled = session.state != SessionState.FINISHING && (active || selectedId == null || ui.viewed != null),
                        modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp), shape = MaterialTheme.shapes.medium,
                    ) {
                        Glyph(if (active) R.drawable.ic_stop else R.drawable.ic_mic)
                        Spacer(Modifier.width(Design.spaceSm))
                        Text(label)
                    }
                }
            }
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            if (!ui.hasKey && !active && rows.isEmpty()) {
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Design.spaceLg),
                    verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    Glyph(R.drawable.ic_key)
                    Text(stringResource(R.string.setup_hint), Modifier.padding(Design.spaceMd), textAlign = TextAlign.Center)
                    FilledTonalButton(onSettings) { Text(stringResource(R.string.setup_service)) }
                }
            } else {
                Subtitles(rows, trimmed = ui.viewingRecording && session.trimmed, emptyText = emptyText, modifier = Modifier.weight(1f),
                    sessionId = selectedId, stamp = { key -> controller.subtitleStartMs(key)?.let { SessionText.stamp(it, "HH:mm", zone) } })
            }
        }
    }
}

@Composable
private fun Subtitles(rows: List<SubtitleRow>, trimmed: Boolean, emptyText: String, modifier: Modifier,
                      sessionId: String?, stamp: (String) -> String?) {
    if (rows.isEmpty()) {
        Column(modifier.fillMaxWidth().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Text(emptyText, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
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
    Box(modifier.fillMaxWidth()) {
        LazyColumn(Modifier.fillMaxSize(), state = list, reverseLayout = true) {
            items(newestFirst, key = { it.key }, contentType = { if (it.marker.isEmpty()) 0 else 1 }) { row ->
                if (row.marker.isNotEmpty()) {
                    Marker(row.marker)
                    return@items
                }
                SubtitleText(row, remember(sessionId, row.key) { stamp(row.key) })
            }
            if (trimmed) {
                item(key = "trimmed", contentType = 1) { Marker(stringResource(R.string.earlier_captions)) }
            }
        }
        if (!following) {
            FilledTonalButton(
                onClick = { scope.launch { list.animateScrollToItem(0) } },
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 8.dp),
            ) { Text(stringResource(R.string.latest)) }
        }
    }
}

@Composable
private fun Marker(text: String) {
    Column(Modifier.fillMaxWidth()) {
        HorizontalDivider()
        Text(
            text, style = MaterialTheme.typography.labelMedium, textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
        )
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
    fun text() = SessionExport.render(record, format, content, zone)
    fun name() = SessionExport.fileName(record, format, zone)
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MaterialTheme.colorScheme.surfaceContainerLow) {
        ExportChoices(record.title, format, content, { format = it }, { content = it },
            save = { onSave(format, name(), text()) }, share = { onShare(name(), text()) }, copy = { onCopy(text()) })
    }
}

@Composable
internal fun ExportChoices(
    title: String, format: ExportFormat, content: ExportContent, setFormat: (ExportFormat) -> Unit,
    setContent: (ExportContent) -> Unit, save: () -> Unit, share: () -> Unit, copy: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = Design.spaceLg, vertical = Design.spaceSm),
        verticalArrangement = Arrangement.spacedBy(Design.spaceSm)) {
        Text(stringResource(R.string.export_session), style = Design.title)
        Text(stringResource(R.string.export_summary, title), style = Design.source)
        Segments(stringResource(R.string.format), ExportFormat.entries.map { it.label }, format.ordinal) { setFormat(ExportFormat.entries[it]) }
        Segments(stringResource(R.string.content), listOf(stringResource(R.string.bilingual), stringResource(R.string.source_only), stringResource(R.string.translation_only)), content.ordinal) { setContent(ExportContent.entries[it]) }
        Button(save, Modifier.fillMaxWidth()) {
            Glyph(R.drawable.ic_upload_file)
            Spacer(Modifier.width(Design.spaceSm))
            Text(stringResource(R.string.save_to_file))
        }
        Row {
            TextButton(share) { Text(stringResource(R.string.share)) }
            TextButton(copy) { Text(stringResource(R.string.copy_text)) }
        }
    }
}
