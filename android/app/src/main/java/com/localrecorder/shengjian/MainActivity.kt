package com.localrecorder.shengjian

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
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
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.PlaybackTiming

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

    fun keepScreenOn(on: Boolean) {
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}

@Composable
private fun App(controller: SessionController) {
    val ui by controller.ui.collectAsStateWithLifecycle()
    var showSettings by rememberSaveable { mutableStateOf(false) }
    if (showSettings) {
        BackHandler { showSettings = false }
        SettingsScreen(controller, ui, onBack = { showSettings = false })
    } else {
        TranscriptScreen(controller, ui, onSettings = { showSettings = true })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TranscriptScreen(controller: SessionController, ui: UiState, onSettings: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val activity = context as? MainActivity
    val active = ui.state != SessionState.IDLE
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

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("声笺") },
                actions = { TextButton(onClick = onSettings, enabled = !active) { Text("设置") } },
            )
        },
        bottomBar = {
            Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(16.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    when (ui.state) {
                        SessionState.IDLE -> Button(onClick = { requestStart() }, modifier = Modifier.weight(1f).height(56.dp)) {
                            Text("开始实时翻译")
                        }
                        SessionState.CONNECTING -> OutlinedButton(onClick = controller::stop, modifier = Modifier.weight(1f).height(56.dp)) {
                            CircularProgressIndicator(Modifier.width(20.dp).height(20.dp), strokeWidth = 2.dp)
                            Spacer(Modifier.width(8.dp))
                            Text("连接中，点击取消")
                        }
                        SessionState.RECORDING -> Button(
                            onClick = controller::stop,
                            modifier = Modifier.weight(1f).height(56.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                        ) { Text("停止") }
                        SessionState.FINISHING -> OutlinedButton(onClick = {}, enabled = false, modifier = Modifier.weight(1f).height(56.dp)) {
                            Text("正在收尾…")
                        }
                    }
                    if (ui.playing) OutlinedButton(onClick = controller::stopPlayback) { Text("停播") }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = {
                        val clipboard = context.getSystemService(ClipboardManager::class.java)
                        clipboard?.setPrimaryClip(ClipData.newPlainText("声笺", controller.exportText()))
                        Toast.makeText(context, "已复制原文和译文", Toast.LENGTH_SHORT).show()
                    }, enabled = ui.rows.isNotEmpty()) { Text("复制全部") }
                    TextButton(onClick = controller::clear, enabled = !active && ui.rows.isNotEmpty()) { Text("清空") }
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
            if (ui.error.isNotEmpty()) Message(ui.error, MaterialTheme.colorScheme.errorContainer, controller::dismissMessages)
            if (ui.notice.isNotEmpty()) Message(ui.notice, MaterialTheme.colorScheme.tertiaryContainer, controller::dismissMessages)
            Subtitles(ui.rows, Modifier.weight(1f))
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
private fun Subtitles(rows: List<SubtitleRow>, modifier: Modifier) {
    val list = rememberLazyListState()
    LaunchedEffect(rows.size, rows.lastOrNull()) {
        if (rows.isNotEmpty()) list.animateScrollToItem(rows.size - 1)
    }
    if (rows.isEmpty()) {
        Column(modifier.fillMaxWidth().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Text("点击下方按钮开始说话，原文和译文会实时显示在这里。", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    LazyColumn(modifier.fillMaxWidth(), state = list) {
        items(rows, key = { it.key }) { row ->
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
            HorizontalDivider()
        }
    }
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
    val draft = LiveTranslateConfig(endpoint, language, audioOutput, volume, timing)
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
                Text("建议佩戴耳机，避免扬声器播放的译音被麦克风再次收录。音频输出可能增加服务费用。", style = MaterialTheme.typography.bodySmall)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Button(onClick = { if (controller.saveSettings(draft, key)) key = "" }) { Text("保存") }
                OutlinedButton(onClick = { controller.testConnection(draft, key) }, enabled = !ui.testing) { Text("测试连接") }
                if (ui.testing) CircularProgressIndicator(Modifier.width(20.dp).height(20.dp), strokeWidth = 2.dp)
            }
            if (ui.settingsMessage.isNotEmpty()) Text(ui.settingsMessage, style = MaterialTheme.typography.bodyMedium)
            HorizontalDivider()
            Text(
                "地址、目标语言和译音设置保存在本机；API Key 使用 Android Keystore 加密保存，按服务地址区分。" +
                    "开始翻译后，麦克风音频会发送到该云端服务，可能产生费用；应用不保存录音，字幕仅保留在内存中。" +
                    "测试连接只建立会话，不采集或发送音频。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
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
