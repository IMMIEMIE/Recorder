package com.localrecorder.shengjian

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.PlaybackTiming
import com.localrecorder.shengjian.ui.theme.Design

@Composable
internal fun SettingsScreen(controller: SessionController, ui: UiState, onBack: () -> Unit) {
    var endpoint by rememberSaveable { mutableStateOf(ui.config.endpoint) }
    // The replacement key stays out of saved instance state. Editing an address drops its draft key.
    var key by remember { mutableStateOf("") }
    var discard by rememberSaveable { mutableStateOf(false) }
    var invalid by remember { mutableStateOf(false) }
    var confirmClear by rememberSaveable { mutableStateOf(false) }

    fun commitService(): Boolean {
        val current = controller.ui.value
        if (endpoint == current.config.endpoint && key.isBlank()) return true
        val saved = controller.saveSettings(current.config.copy(endpoint = endpoint), key, current.options)
        invalid = !saved
        if (saved) {
            endpoint = controller.ui.value.config.endpoint
            key = ""
        }
        return saved
    }
    fun leave() { if (commitService()) onBack() else discard = true }
    BackHandler { leave() }
    val owner = LocalLifecycleOwner.current
    val commitOnStop by rememberUpdatedState { commitService() }
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) commitOnStop() }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }

    SettingsLayout(back = ::leave, service = {
        ServiceFields(
            endpoint, key, ui.hasKey && endpoint == ui.config.endpoint, ui.testing, invalid,
            onEndpoint = { endpoint = it; key = ""; invalid = false }, onKey = { key = it; invalid = false },
            commit = { commitService() }, test = {
                if (commitService()) controller.testConnection(controller.ui.value.config, "")
            },
        )
        if (ui.settingsMessage.isNotEmpty()) {
            val text = when {
                ui.testing -> "正在测试连接…"
                ui.testSucceeded == false -> "测试失败 · ${ui.settingsMessage}"
                else -> ui.settingsMessage
            }
            Text(text, style = Design.caption, color = if (invalid || ui.testSucceeded == false) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }) {
        PreferenceGroups(ui.config, ui.options, enabled = !ui.testing,
            onConfig = { change -> if (commitService()) controller.saveSettings(change(controller.ui.value.config), "", controller.ui.value.options) },
            onOptions = { change -> if (commitService()) controller.saveSettings(controller.ui.value.config, "", change(controller.ui.value.options)) },
            canClear = ui.sessions.isNotEmpty() && ui.recordingId == null,
            clear = { confirmClear = true })
    }
    if (discard) ConfirmDialog("地址或密钥尚未保存", "可以返回检查输入，也可以放弃本次修改。", "放弃修改",
        onDismiss = { discard = false }, onConfirm = onBack)
    if (confirmClear) ConfirmDialog("清空全部会话？", "本机保存的所有会话记录都将被永久删除，无法恢复。", "全部删除",
        onDismiss = { confirmClear = false }, onConfirm = { controller.deleteAll(); confirmClear = false })
}

/** The service editor is a slot so profile/protocol changes can supply their own fields. */
@Composable
internal fun SettingsLayout(back: () -> Unit, service: @Composable ColumnScope.() -> Unit, preferences: @Composable ColumnScope.() -> Unit) {
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Tool(R.drawable.ic_arrow_back, "返回", click = back)
                Text("设置", style = Design.title)
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).fillMaxWidth()
                .padding(horizontal = Design.spaceLg, vertical = Design.spaceSm),
                verticalArrangement = Arrangement.spacedBy(Design.spaceSm)) {
                GroupTitle("服务")
                service()
                preferences()
            }
        }
    }
}

@Composable
internal fun ServiceFields(
    endpoint: String, key: String, keySaved: Boolean, testing: Boolean, invalid: Boolean,
    onEndpoint: (String) -> Unit, onKey: (String) -> Unit, commit: () -> Unit, test: () -> Unit,
) {
    var visible by remember { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current
    var addressFocused by remember { mutableStateOf(false) }
    var keyFocused by remember { mutableStateOf(false) }
    Text("Qwen LiveTranslate · ${LiveTranslateConfig.MODEL}", style = Design.caption)
    OutlinedTextField(value = endpoint, onValueChange = onEndpoint, label = { Text("服务地址") },
        singleLine = true, enabled = !testing, isError = invalid,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { commit(); keyboard?.hide() }),
        modifier = Modifier.fillMaxWidth().onFocusChanged {
            if (addressFocused && !it.isFocused) commit()
            addressFocused = it.isFocused
        })
    OutlinedTextField(value = key, onValueChange = onKey, label = { Text("API Key") },
        placeholder = { Text(if (keySaved) "已保存，留空保留原密钥" else "填写此地址的密钥") },
        singleLine = true, enabled = !testing,
        visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
        trailingIcon = { TextButton({ visible = !visible }) { Text(if (visible) "隐藏" else "显示") } },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { commit(); keyboard?.hide() }),
        modifier = Modifier.fillMaxWidth().onFocusChanged {
            if (keyFocused && !it.isFocused) commit()
            keyFocused = it.isFocused
        })
    OutlinedButton(test, enabled = !testing) {
        if (testing) { CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp); Spacer(Modifier.width(Design.spaceSm)) }
        Text(if (testing) "正在测试…" else "测试连接")
    }
}

@Composable
internal fun PreferenceGroups(
    config: LiveTranslateConfig, options: AppOptions, enabled: Boolean,
    onConfig: ((LiveTranslateConfig) -> LiveTranslateConfig) -> Unit,
    onOptions: ((AppOptions) -> AppOptions) -> Unit, canClear: Boolean, clear: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    GroupTitle("翻译")
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton({ expanded = true }, Modifier.fillMaxWidth(), enabled = enabled) { Text("目标语言 · ${config.languageName} ▾") }
        DropdownMenu(expanded, { expanded = false }) {
            LiveTranslateConfig.LANGUAGES.forEach { (code, name) ->
                DropdownMenuItem(text = { Text(name) }, onClick = { expanded = false; onConfig { it.copy(language = code) } })
            }
        }
    }
    GroupTitle("译音")
    SettingSwitch("播放译音", config.audioOutput, enabled) { value -> onConfig { it.copy(audioOutput = value) } }
    if (config.audioOutput) {
        Segments("播放时机", PlaybackTiming.entries.map { it.title }, config.playbackTiming.ordinal) { i ->
            if (enabled) onConfig { it.copy(playbackTiming = PlaybackTiming.entries[i]) }
        }
        var volume by remember(config.volume) { mutableFloatStateOf(config.volume) }
        Text("音量 · ${(volume * 100).toInt()}%")
        Slider(volume, { volume = it }, enabled = enabled, onValueChangeFinished = { onConfig { it.copy(volume = volume) } })
        Text("建议佩戴耳机，以免麦克风再次收录译音。音频输出可能增加服务费用。", style = Design.caption)
    }
    GroupTitle("网络")
    SettingSwitch("断线自动重连", options.autoReconnect, enabled) { value -> onOptions { it.copy(autoReconnect = value) } }
    SettingSwitch("使用蓝牙耳机麦克风", options.bluetoothMicrophone, enabled) { value -> onOptions { it.copy(bluetoothMicrophone = value) } }
    GroupTitle("会话记录")
    SettingSwitch("保存会话记录", options.saveSessions, enabled) { value -> onOptions { it.copy(saveSessions = value) } }
    Text("只保存已定稿的原文和译文。关闭后新内容只保留到退出，已有会话仍可查看和导出。", style = Design.caption)
    OutlinedButton(clear, enabled = canClear && enabled, colors = ButtonDefaults.outlinedButtonColors(contentColor = colors.error)) { Text("清空全部会话") }
    GroupTitle("关于")
    Text("声笺", style = Design.source)
    Text("开始实时翻译后，麦克风语音会发往所选服务。测试连接不会采集音频。密钥按服务地址加密保存；录音、译音及识别中的内容不会保存。", style = Design.caption)
    Spacer(Modifier.height(Design.spaceMd))
}

@Composable
private fun SettingSwitch(label: String, value: Boolean, enabled: Boolean, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(value, enabled, Role.Switch, change),
        verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f).padding(end = Design.spaceSm))
        Switch(value, onCheckedChange = null, enabled = enabled)
    }
}
