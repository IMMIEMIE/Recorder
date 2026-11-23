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
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.PermanentDrawerSheet
import androidx.compose.material3.PermanentNavigationDrawer
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.PlaybackTiming
import com.localrecorder.live.SessionState
import com.localrecorder.live.SubtitleRow
import com.localrecorder.sessions.ExportContent
import com.localrecorder.sessions.ExportFormat
import com.localrecorder.sessions.SessionExport
import com.localrecorder.sessions.SessionGroup
import com.localrecorder.sessions.SessionRecord
import com.localrecorder.sessions.SessionSummary
import com.localrecorder.sessions.SessionText
import kotlinx.coroutines.launch
import java.time.ZoneId

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val controller = (application as ShengjianApp).controller
        setContent {
            val dark = isSystemInDarkTheme()
            MaterialTheme(colorScheme = if (dark) darkColorScheme() else lightColorScheme(primary = Color(0xFF1F4E79))) {
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
    if (showSettings) {
        BackHandler { showSettings = false }
        SettingsScreen(controller, ui, onBack = { showSettings = false })
    } else {
        MainScreen(controller, ui, onSettings = { showSettings = true })
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

    if (LocalConfiguration.current.screenWidthDp >= 840) {
        PermanentNavigationDrawer(
            drawerContent = {
                PermanentDrawerSheet(Modifier.width(320.dp)) {
                    SessionList(ui, menu, onSelect = controller::select)
                }
            },
        ) {
            TranscriptScreen(controller, ui, menu, onSettings, onOpenList = null)
        }
    } else {
        val drawer = rememberDrawerState(DrawerValue.Closed)
        val scope = rememberCoroutineScope()
        BackHandler(enabled = drawer.isOpen) { scope.launch { drawer.close() } }
        ModalNavigationDrawer(
            drawerState = drawer,
            drawerContent = {
                ModalDrawerSheet(Modifier.width(320.dp)) {
                    SessionList(ui, menu, onSelect = { id ->
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
private fun ColumnScope.SessionList(ui: UiState, menu: SessionMenu, onSelect: (String?) -> Unit) {
    Button(
        onClick = { onSelect(null) },
        modifier = Modifier.fillMaxWidth().padding(16.dp),
    ) { Text(stringResource(R.string.new_session)) }
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
                .clip(RoundedCornerShape(24.dp))
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
            DropdownMenuItem(text = { Text(stringResource(R.string.export)) }, onClick = {
                expanded = false
                menu.export(session.id)
            })
            DropdownMenuItem(text = { Text(stringResource(if (recording) R.string.cannot_delete_recording else R.string.delete)) }, enabled = !recording, onClick = {
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
        color = MaterialTheme.colorScheme.onError,
        modifier = Modifier
            .padding(start = 8.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.error)
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
        onDispose { }
    }
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result[Manifest.permission.RECORD_AUDIO] == true) controller.start()
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

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    if (onOpenList != null) TextButton(onClick = onOpenList) { Text(stringResource(R.string.sessions)) }
                },
                actions = {
                    if (selectedId != null) {
                        TextButton(onClick = { menu.export(selectedId) }) { Text(stringResource(R.string.export)) }
                        var expanded by remember { mutableStateOf(false) }
                        Box {
                            TextButton(onClick = { expanded = true }) { Text(stringResource(R.string.more)) }
                            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                                DropdownMenuItem(text = { Text(stringResource(R.string.rename)) }, onClick = {
                                    expanded = false
                                    menu.rename(selectedId, title)
                                })
                                DropdownMenuItem(text = { Text(stringResource(R.string.delete)) }, enabled = selectedId != ui.recordingId, onClick = {
                                    expanded = false
                                    menu.delete(selectedId, title)
                                })
                            }
                        }
                    }
                    TextButton(onClick = onSettings, enabled = !active) { Text(stringResource(R.string.settings)) }
                },
            )
        },
        bottomBar = {
            Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(16.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    val wide = Modifier.weight(1f).height(56.dp)
                    when {
                        active && !ui.viewingRecording -> {
                            OutlinedButton(onClick = { controller.select(ui.recordingId) }, modifier = wide) {
                                Text(stringResource(R.string.return_to_recording), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            Button(
                                onClick = controller::stop,
                                enabled = session.state != SessionState.FINISHING,
                                modifier = Modifier.height(56.dp),
                                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                            ) { Text(stringResource(R.string.stop)) }
                        }
                        active -> RecordingControls(session.state, controller, wide)
                        selectedId == null -> Button(onClick = { requestStart() }, modifier = wide) { Text(stringResource(R.string.start_live)) }
                        else -> Button(onClick = { requestStart() }, enabled = ui.viewed != null, modifier = wide) { Text(stringResource(R.string.resume_recording)) }
                    }
                    if (session.playing) OutlinedButton(onClick = controller::stopPlayback) { Text(stringResource(R.string.stop_playback)) }
                }
            }
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            Text(
                session.status.ifEmpty { stringResource(R.string.ready_target, ui.config.languageName) }, style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
            if (!ui.hasKey && !active) {
                Message(stringResource(R.string.configure_key), MaterialTheme.colorScheme.secondaryContainer, onSettings)
            }
            if (session.error.isNotEmpty()) Message(session.error, MaterialTheme.colorScheme.errorContainer, controller::dismissMessages)
            if (session.notice.isNotEmpty()) Message(session.notice, MaterialTheme.colorScheme.tertiaryContainer, controller::dismissMessages)
            if (session.slowNetwork) Message(stringResource(R.string.slow_network), MaterialTheme.colorScheme.tertiaryContainer) {}
            Subtitles(rows, trimmed = ui.viewingRecording && session.trimmed, emptyText = emptyText, modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun RecordingControls(state: SessionState, controller: SessionController, modifier: Modifier) {
    when (state) {
        SessionState.IDLE -> Unit
        SessionState.CONNECTING -> OutlinedButton(onClick = controller::stop, modifier = modifier) {
            CircularProgressIndicator(Modifier.width(20.dp).height(20.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.connecting_cancel))
        }
        SessionState.RECONNECTING -> OutlinedButton(onClick = controller::stop, modifier = modifier) {
            CircularProgressIndicator(Modifier.width(20.dp).height(20.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.reconnecting_stop))
        }
        SessionState.RECORDING -> Button(
            onClick = controller::stop,
            modifier = modifier,
            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
        ) { Text(stringResource(R.string.stop)) }
        SessionState.FINISHING -> OutlinedButton(onClick = {}, enabled = false, modifier = modifier) {
            Text(stringResource(R.string.finishing))
        }
    }
}

@Composable
private fun Message(text: String, color: Color, onClick: () -> Unit) {
    Card(
        onClick = onClick,
        colors = CardDefaults.cardColors(containerColor = color),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    ) { Text(text, Modifier.padding(12.dp), style = MaterialTheme.typography.bodyMedium) }
}

@Composable
private fun Subtitles(rows: List<SubtitleRow>, trimmed: Boolean, emptyText: String, modifier: Modifier) {
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
                Column(Modifier.fillMaxWidth()) {
                    HorizontalDivider()
                    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
                        if (row.source.isNotEmpty()) {
                            Text(
                                row.source, style = MaterialTheme.typography.bodyLarge,
                                color = if (row.sourceDone) MaterialTheme.colorScheme.onSurfaceVariant
                                else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                            )
                        }
                        if (row.translation.isNotEmpty()) {
                            Spacer(Modifier.height(4.dp))
                            Text(
                                row.translation, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold,
                                color = if (row.translationDone) MaterialTheme.colorScheme.onSurface
                                else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                            )
                        }
                    }
                }
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
private fun ConfirmDialog(title: String, text: String, confirm: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
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
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.export_session)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stringResource(R.string.format), style = MaterialTheme.typography.titleSmall)
                ExportFormat.entries.forEach { option -> Choice(option.label, selected = format == option) { format = option } }
                Text(stringResource(R.string.content), style = MaterialTheme.typography.titleSmall)
                ExportContent.entries.forEach { option ->
                    val label = when (option) {
                        ExportContent.BILINGUAL -> R.string.bilingual
                        ExportContent.SOURCE -> R.string.source_only
                        ExportContent.TRANSLATION -> R.string.translation_only
                    }
                    Choice(stringResource(label), selected = content == option) { content = option }
                }
                Text(stringResource(R.string.export_hint), style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                    Button(onClick = { onShare(name(), text()) }) { Text(stringResource(R.string.share)) }
                    OutlinedButton(onClick = { onSave(format, name(), text()) }) { Text(stringResource(R.string.save_to_file)) }
                }
                TextButton(onClick = { onCopy(text()) }) { Text(stringResource(R.string.copy)) }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsScreen(controller: SessionController, ui: UiState, onBack: () -> Unit) {
    var endpoint by rememberSaveable { mutableStateOf(ui.config.endpoint) }
    var key by remember { mutableStateOf("") }
    var language by rememberSaveable { mutableStateOf(ui.config.language) }
    var audioOutput by rememberSaveable { mutableStateOf(ui.config.audioOutput) }
    var timing by rememberSaveable { mutableStateOf(ui.config.playbackTiming) }
    var volume by rememberSaveable { mutableFloatStateOf(ui.config.volume) }
    var autoReconnect by rememberSaveable { mutableStateOf(ui.options.autoReconnect) }
    var bluetoothMicrophone by rememberSaveable { mutableStateOf(ui.options.bluetoothMicrophone) }
    var saveSessions by rememberSaveable { mutableStateOf(ui.options.saveSessions) }
    var confirmClear by rememberSaveable { mutableStateOf(false) }
    val draft = LiveTranslateConfig(endpoint, language, audioOutput, volume, timing)
    val draftOptions = AppOptions(autoReconnect, bluetoothMicrophone, saveSessions)
    val keySaved = remember(endpoint, ui.hasKey) { controller.hasKey(endpoint.trim()) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.live_settings)) },
                navigationIcon = { TextButton(onClick = onBack) { Text(stringResource(R.string.back)) } },
            )
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).imePadding().fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(stringResource(R.string.live_intro), style = MaterialTheme.typography.bodyMedium)
            Text(stringResource(R.string.model, LiveTranslateConfig.MODEL), style = MaterialTheme.typography.bodySmall)
            OutlinedTextField(
                value = endpoint,
                onValueChange = { endpoint = it; key = "" },
                label = { Text(stringResource(R.string.endpoint)) },
                placeholder = { Text("wss://…/api-ws/v1/realtime") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = key,
                onValueChange = { key = it },
                label = { Text(stringResource(R.string.api_key)) },
                placeholder = { Text(stringResource(if (keySaved) R.string.key_saved else R.string.key_missing)) },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                modifier = Modifier.fillMaxWidth(),
            )
            Text(stringResource(R.string.target_language), style = MaterialTheme.typography.titleSmall)
            LiveTranslateConfig.LANGUAGES.forEach { (code, name) ->
                Choice(name, selected = language == code) { language = code }
            }
            HorizontalDivider()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.play_translation), Modifier.weight(1f))
                Switch(checked = audioOutput, onCheckedChange = { audioOutput = it })
            }
            if (audioOutput) {
                PlaybackTiming.entries.forEach { option ->
                    val label = if (option == PlaybackTiming.STREAMING) R.string.streaming_playback else R.string.final_playback
                    Choice(stringResource(label), selected = timing == option) { timing = option }
                }
                Text(
                    if (timing == PlaybackTiming.STREAMING) stringResource(R.string.streaming_hint)
                    else stringResource(R.string.final_hint),
                    style = MaterialTheme.typography.bodySmall,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.volume))
                    Slider(value = volume, onValueChange = { volume = it }, modifier = Modifier.weight(1f).padding(horizontal = 8.dp))
                    Text("${(volume * 100).toInt()}%")
                }
                Text(stringResource(R.string.headphones_hint), style = MaterialTheme.typography.bodySmall)
            }
            HorizontalDivider()
            Toggle(stringResource(R.string.auto_reconnect), stringResource(R.string.auto_reconnect_hint), autoReconnect) { autoReconnect = it }
            Toggle(stringResource(R.string.bluetooth_microphone), stringResource(R.string.bluetooth_hint), bluetoothMicrophone) { bluetoothMicrophone = it }
            Toggle(
                stringResource(R.string.save_history),
                stringResource(R.string.save_history_hint),
                saveSessions,
            ) { saveSessions = it }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Button(onClick = { if (controller.saveSettings(draft, key, draftOptions)) key = "" }) { Text(stringResource(R.string.save)) }
                OutlinedButton(onClick = { controller.testConnection(draft, key) }, enabled = !ui.testing) { Text(stringResource(R.string.test_connection)) }
                if (ui.testing) CircularProgressIndicator(Modifier.width(20.dp).height(20.dp), strokeWidth = 2.dp)
            }
            if (ui.settingsMessage.isNotEmpty()) Text(ui.settingsMessage, style = MaterialTheme.typography.bodyMedium)
            HorizontalDivider()
            OutlinedButton(
                onClick = { confirmClear = true },
                enabled = ui.sessions.isNotEmpty() && ui.recordingId == null,
                colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
            ) { Text(stringResource(R.string.delete_sessions)) }
            HorizontalDivider()
            Text(
                stringResource(R.string.privacy),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
    if (confirmClear) {
        ConfirmDialog(
            title = stringResource(R.string.delete_all_question),
            text = stringResource(R.string.delete_all_detail),
            confirm = stringResource(R.string.delete_all),
            onDismiss = { confirmClear = false },
        ) {
            controller.deleteAll()
            confirmClear = false
        }
    }
}

@Composable
private fun Toggle(title: String, description: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { onChange(!checked) }, verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 12.dp)) {
            Text(title)
            Text(description, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun Choice(label: String, selected: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().selectable(selected = selected, onClick = onSelect, role = Role.RadioButton).padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null)
        Spacer(Modifier.width(8.dp))
        Text(label)
    }
}
