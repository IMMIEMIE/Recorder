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
                Toast.makeText(context, if (ok) "已保存" else "保存失败，请重试或换一个位置", Toast.LENGTH_SHORT).show()
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
                    Toast.makeText(context, "无法读取该会话", Toast.LENGTH_SHORT).show()
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
            title = "删除会话？",
            text = "「${current.title}」的原文和译文将从本机永久删除，无法恢复。",
            confirm = "删除",
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
                    Toast.makeText(context, "内容较长，无法通过分享发送，请使用「保存到文件」", Toast.LENGTH_LONG).show()
                } else {
                    val send = Intent(Intent.ACTION_SEND)
                        .setType("text/plain")
                        .putExtra(Intent.EXTRA_TEXT, text)
                        .putExtra(Intent.EXTRA_SUBJECT, name.substringBeforeLast('.'))
                        .putExtra(Intent.EXTRA_TITLE, name)
                    context.startActivity(Intent.createChooser(send, "分享会话"))
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
                    Toast.makeText(context, "本机没有可用的文件选择器", Toast.LENGTH_LONG).show()
                }
            },
            onCopy = { text ->
                context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("声笺", text))
                Toast.makeText(context, "已复制", Toast.LENGTH_SHORT).show()
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
    ) { Text("新建会话") }
    if (!ui.options.saveSessions) {
        Text(
            "「保存会话记录」已关闭：新内容只保留到应用退出。",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
    }
    if (ui.sessions.isEmpty()) {
        Text(
            "还没有会话记录",
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
                    group.label,
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
                .combinedClickable(onLongClick = { expanded = true }, onLongClickLabel = "会话操作", onClick = onClick)
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
            DropdownMenuItem(text = { Text("重命名") }, onClick = {
                expanded = false
                menu.rename(session.id, session.title)
            })
            DropdownMenuItem(text = { Text("导出") }, onClick = {
                expanded = false
                menu.export(session.id)
            })
            DropdownMenuItem(text = { Text(if (recording) "删除（录制中不可删除）" else "删除") }, enabled = !recording, onClick = {
                expanded = false
                menu.delete(session.id, session.title)
            })
        }
    }
}

@Composable
private fun RecordingBadge() {
    Text(
        "录制中",
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
        else Toast.makeText(context, "需要麦克风权限才能实时翻译", Toast.LENGTH_LONG).show()
    }
    fun requestStart() {
        val needed = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
        }.filter { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (needed.isEmpty()) controller.start() else permissions.launch(needed.toTypedArray())
    }

    val selectedId = ui.selectedId
    val title = ui.selectedTitle ?: "新会话"
    val rows: List<SubtitleRow> = when {
        ui.viewingRecording -> ui.recordingPrefix + session.rows
        selectedId == null -> emptyList()
        else -> remember(ui.viewed) { ui.viewed?.subtitleRows(zone).orEmpty() }
    }
    val emptyText = when {
        ui.viewingRecording || (selectedId == null && !active) -> "点击下方按钮开始说话，原文和译文会实时显示在这里。"
        selectedId == null -> "正在录制另一个会话；新内容会写入那个会话。"
        ui.viewError.isNotEmpty() -> ui.viewError
        ui.viewed == null -> "正在读取…"
        else -> "这个会话没有已定稿的文字。"
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    if (onOpenList != null) TextButton(onClick = onOpenList) { Text("会话") }
                },
                actions = {
                    if (selectedId != null) {
                        TextButton(onClick = { menu.export(selectedId) }) { Text("导出") }
                        var expanded by remember { mutableStateOf(false) }
                        Box {
                            TextButton(onClick = { expanded = true }) { Text("更多") }
                            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                                DropdownMenuItem(text = { Text("重命名") }, onClick = {
                                    expanded = false
                                    menu.rename(selectedId, title)
                                })
                                DropdownMenuItem(text = { Text("删除") }, enabled = selectedId != ui.recordingId, onClick = {
                                    expanded = false
                                    menu.delete(selectedId, title)
                                })
                            }
                        }
                    }
                    TextButton(onClick = onSettings, enabled = !active) { Text("设置") }
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
                                Text("返回录制中的会话", maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            Button(
                                onClick = controller::stop,
                                enabled = session.state != SessionState.FINISHING,
                                modifier = Modifier.height(56.dp),
                                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                            ) { Text("停止") }
                        }
                        active -> RecordingControls(session.state, controller, wide)
                        selectedId == null -> Button(onClick = { requestStart() }, modifier = wide) { Text("开始实时翻译") }
                        else -> Button(onClick = { requestStart() }, enabled = ui.viewed != null, modifier = wide) { Text("继续录制") }
                    }
                    if (session.playing) OutlinedButton(onClick = controller::stopPlayback) { Text("停播") }
                }
            }
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            Text(
                ui.status, style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
            if (!ui.hasKey && !active) {
                Message("尚未保存 LiveTranslate API Key，请先在“设置”中配置。", MaterialTheme.colorScheme.secondaryContainer, onSettings)
            }
            if (session.error.isNotEmpty()) Message(session.error, MaterialTheme.colorScheme.errorContainer, controller::dismissMessages)
            if (session.notice.isNotEmpty()) Message(session.notice, MaterialTheme.colorScheme.tertiaryContainer, controller::dismissMessages)
            if (session.slowNetwork) Message("网络较慢，音频发送有积压，字幕可能延迟。", MaterialTheme.colorScheme.tertiaryContainer) {}
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
            Text("连接中，点击取消")
        }
        SessionState.RECONNECTING -> OutlinedButton(onClick = controller::stop, modifier = modifier) {
            CircularProgressIndicator(Modifier.width(20.dp).height(20.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(8.dp))
            Text("重新连接中，点击停止")
        }
        SessionState.RECORDING -> Button(
            onClick = controller::stop,
            modifier = modifier,
            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
        ) { Text("停止") }
        SessionState.FINISHING -> OutlinedButton(onClick = {}, enabled = false, modifier = modifier) {
            Text("正在收尾…")
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
                item(key = "trimmed", contentType = 1) { Marker("较早的字幕已不在屏幕上（最多显示约 1000 条），已定稿的内容仍保存在会话中") }
            }
        }
        if (!following) {
            FilledTonalButton(
                onClick = { scope.launch { list.animateScrollToItem(0) } },
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 8.dp),
            ) { Text("回到最新") }
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
        title = { Text("重命名会话") },
        text = {
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                singleLine = true,
                supportingText = { Text("留空则恢复自动标题") },
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = { TextButton(onClick = { onRename(title) }) { Text("确定") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
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
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
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
        title = { Text("导出会话") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("格式", style = MaterialTheme.typography.titleSmall)
                ExportFormat.entries.forEach { option -> Choice(option.label, selected = format == option) { format = option } }
                Text("内容", style = MaterialTheme.typography.titleSmall)
                ExportContent.entries.forEach { option -> Choice(option.label, selected = content == option) { content = option } }
                Text("只包含已定稿的文字，不含服务地址和 API Key。", style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                    Button(onClick = { onShare(name(), text()) }) { Text("分享") }
                    OutlinedButton(onClick = { onSave(format, name(), text()) }) { Text("保存到文件") }
                }
                TextButton(onClick = { onCopy(text()) }) { Text("复制到剪贴板") }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
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
                title = { Text("LiveTranslate 设置") },
                navigationIcon = { TextButton(onClick = onBack) { Text("返回") } },
            )
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).imePadding().fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("由 Qwen3.8 LiveTranslate 同时生成原文和译文，所有识别与翻译都通过云端 API 完成。", style = MaterialTheme.typography.bodyMedium)
            Text("模型：${LiveTranslateConfig.MODEL}", style = MaterialTheme.typography.bodySmall)
            OutlinedTextField(
                value = endpoint,
                onValueChange = { endpoint = it; key = "" },
                label = { Text("服务地址") },
                placeholder = { Text("wss://…/api-ws/v1/realtime") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = key,
                onValueChange = { key = it },
                label = { Text("专用 API Key") },
                placeholder = { Text(if (keySaved) "已保存；留空则保留" else "尚未保存") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                modifier = Modifier.fillMaxWidth(),
            )
            Text("目标语言", style = MaterialTheme.typography.titleSmall)
            LiveTranslateConfig.LANGUAGES.forEach { (code, name) ->
                Choice(name, selected = language == code) { language = code }
            }
            HorizontalDivider()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("播放译音", Modifier.weight(1f))
                Switch(checked = audioOutput, onCheckedChange = { audioOutput = it })
            }
            if (audioOutput) {
                PlaybackTiming.entries.forEach { option ->
                    Choice(option.title, selected = timing == option) { timing = option }
                }
                Text(
                    if (timing == PlaybackTiming.STREAMING) "译音生成后立即播放，可一边说话一边听翻译。"
                    else "按句等待原文和译文定稿、该句译音生成完整后再播放。",
                    style = MaterialTheme.typography.bodySmall,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("音量")
                    Slider(value = volume, onValueChange = { volume = it }, modifier = Modifier.weight(1f).padding(horizontal = 8.dp))
                    Text("${(volume * 100).toInt()}%")
                }
                Text("建议佩戴耳机；未检测到耳机时会启用回声消除，但外放的译音仍可能被麦克风再次收录。音频输出可能增加服务费用。", style = MaterialTheme.typography.bodySmall)
            }
            HorizontalDivider()
            Toggle("断线自动重连", "连接中断或切换网络后自动建立新会话，保留已有字幕并标出断点。", autoReconnect) { autoReconnect = it }
            Toggle("使用蓝牙耳机麦克风", "连接了蓝牙耳机时用它收音，音质通常不如手机麦克风；未连接时使用手机麦克风。", bluetoothMicrophone) { bluetoothMicrophone = it }
            Toggle(
                "保存会话记录",
                "把已定稿的原文和译文保存在本机，可在会话列表中查看和导出；不保存录音和未定稿内容。关闭后新内容只保留到应用退出，已有会话仍可查看、导出和删除。",
                saveSessions,
            ) { saveSessions = it }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Button(onClick = { if (controller.saveSettings(draft, key, draftOptions)) key = "" }) { Text("保存") }
                OutlinedButton(onClick = { controller.testConnection(draft, key) }, enabled = !ui.testing) { Text("测试连接") }
                if (ui.testing) CircularProgressIndicator(Modifier.width(20.dp).height(20.dp), strokeWidth = 2.dp)
            }
            if (ui.settingsMessage.isNotEmpty()) Text(ui.settingsMessage, style = MaterialTheme.typography.bodyMedium)
            HorizontalDivider()
            OutlinedButton(
                onClick = { confirmClear = true },
                enabled = ui.sessions.isNotEmpty() && ui.recordingId == null,
                colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
            ) { Text("清空全部会话") }
            HorizontalDivider()
            Text(
                "地址、目标语言和译音设置保存在本机；API Key 使用 Android Keystore 加密保存，按服务地址区分。" +
                    "开始翻译后，麦克风音频会发送到该云端服务，可能产生费用；应用不保存录音。" +
                    "开启「保存会话记录」时，已定稿的原文和译文保存在本机，不上传、不参与系统备份和设备迁移。" +
                    "测试连接只建立会话，不采集或发送音频。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
    if (confirmClear) {
        ConfirmDialog(
            title = "清空全部会话？",
            text = "本机保存的所有会话记录都将被永久删除，无法恢复。",
            confirm = "全部删除",
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
