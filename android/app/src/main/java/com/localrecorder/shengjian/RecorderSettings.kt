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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.Modifier
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
import com.localrecorder.live.LiveServiceProfile
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.PlaybackTiming
import com.localrecorder.live.SessionState
import com.localrecorder.shengjian.ui.theme.Design

@Composable
internal fun SettingsScreen(controller: SessionController, ui: UiState, onBack: () -> Unit) {
    var profile by rememberSaveable(stateSaver = profileSaver) { mutableStateOf(ui.config.profile) }
    // The replacement key stays out of saved instance state. Editing an address drops its draft key.
    var key by remember { mutableStateOf("") }
    var discard by rememberSaveable { mutableStateOf(false) }
    var invalid by remember { mutableStateOf(false) }
    var testedDraft by rememberSaveable { mutableStateOf(false) }
    var confirmClear by rememberSaveable { mutableStateOf(false) }

    fun commitService(): Boolean {
        val current = controller.ui.value
        if (profile == current.config.profile && key.isBlank()) return true
        // A pending or rejected probe must never replace the working service or its key.
        if (testedDraft && current.testSucceeded != true) return false
        val draft = current.config.copy(catalog = current.config.catalog.using(profile))
        val saved = controller.saveSettings(draft, key, current.options)
        invalid = !saved
        if (saved) {
            profile = controller.ui.value.config.profile
            key = ""
        }
        return saved
    }
    fun edited() {
        testedDraft = false
        invalid = false
        controller.clearSettingsFeedback()
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

    val recording = ui.session.state != SessionState.IDLE
    SettingsLayout(back = ::leave, service = {
        if (recording) Text(stringResource(R.string.dialogue_service_locked), style = Design.caption)
        ServiceFields(
            profile, ui.config, key, remember(profile.endpoint, ui.hasKey) { controller.hasKey(profile.endpoint) }, ui.testing,
            onEdit = { updated ->
                if (updated.id == profile.id || commitService()) {
                    if (updated.id != profile.id || updated.endpoint != profile.endpoint) key = ""
                    profile = updated
                    edited()
                }
            },
            onSelect = { selected ->
                if (commitService()) {
                    val latest = controller.ui.value.config.catalog.profiles.first { it.id == selected.id }
                    if (controller.selectProfile(latest)) {
                        profile = controller.ui.value.config.profile
                        key = ""
                    }
                }
            },
            onKey = { key = it; edited() },
            recording = recording,
            test = {
                testedDraft = true
                val current = controller.ui.value.config
                controller.testConnection(current.copy(catalog = current.catalog.using(profile)), key)
            },
        )
        if (ui.settingsMessage.isNotEmpty()) {
            val text = when {
                ui.testing -> stringResource(R.string.test_in_progress)
                ui.testSucceeded == false -> stringResource(R.string.test_failure, ui.settingsMessage)
                else -> ui.settingsMessage
            }
            Text(text, style = Design.caption, color = if (invalid || ui.testSucceeded == false) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }) {
        PreferenceGroups(ui.config, ui.options, enabled = !ui.testing && ui.session.state != SessionState.FINISHING,
            onConfig = { change -> if (commitService()) controller.saveSettings(change(controller.ui.value.config), "", controller.ui.value.options) },
            onOptions = { change -> if (commitService()) controller.saveSettings(controller.ui.value.config, "", change(controller.ui.value.options)) },
            canClear = ui.sessions.isNotEmpty() && ui.recordingId == null,
            clear = { confirmClear = true }, recording = recording,
            dialogueTargets = if (ui.dialogueMode) ({
                listOf("A" to ui.dialogueLanguageA, "B" to ui.dialogueLanguageB).forEach { (side, code) ->
                    val name = LiveTranslateConfig.LANGUAGES.first { it.first == code }.second
                    val other = if (side == "A") ui.dialogueLanguageB else ui.dialogueLanguageA
                    LanguageChoice(stringResource(R.string.dialogue_seat, side, name), code,
                        { if (side == "A") controller.setDialogueLanguages(it, other) else controller.setDialogueLanguages(other, it) },
                        enabled = ui.session.state != SessionState.FINISHING, other = other)
                }
            }) else null)

    }
    if (discard) ConfirmDialog(stringResource(R.string.settings_unsaved), stringResource(R.string.discard_hint), stringResource(R.string.discard_changes),
        onDismiss = { discard = false }, onConfirm = onBack)
    if (confirmClear) ConfirmDialog(stringResource(R.string.delete_all_question), stringResource(R.string.delete_all_detail), stringResource(R.string.delete_all),
        onDismiss = { confirmClear = false }, onConfirm = { controller.deleteAll(); confirmClear = false })
}

/** The service editor is a slot so profile/protocol changes can supply their own fields. */
@Composable
internal fun SettingsLayout(back: () -> Unit, service: @Composable ColumnScope.() -> Unit, preferences: @Composable ColumnScope.() -> Unit) {
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Tool(R.drawable.ic_arrow_back, stringResource(R.string.back), click = back)
                Text(stringResource(R.string.settings), style = Design.title)
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).fillMaxWidth()
                .padding(horizontal = Design.spaceLg, vertical = Design.spaceSm),
                verticalArrangement = Arrangement.spacedBy(Design.spaceSm)) {
                GroupTitle(stringResource(R.string.service))
                service()
                preferences()
            }
        }
    }
}

@Composable
internal fun ServiceFields(
    profile: LiveServiceProfile, config: LiveTranslateConfig, key: String, keySaved: Boolean, testing: Boolean,
    onEdit: (LiveServiceProfile) -> Unit, onSelect: (LiveServiceProfile) -> Unit,
    onKey: (String) -> Unit, test: () -> Unit, recording: Boolean = false,
) {
    var visible by remember(profile.id) { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current
    LiveServiceProfileEditor(profile, config, testing, onEdit, onSelect, recording)
    OutlinedTextField(value = key, onValueChange = onKey, label = { Text("API Key") },
        placeholder = { Text(if (keySaved) stringResource(R.string.use_saved_key) else stringResource(R.string.enter_service_key)) },
        singleLine = true, enabled = !testing && !recording,
        visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
        trailingIcon = { TextButton({ visible = !visible }, enabled = !recording) { Text(if (visible) stringResource(R.string.hide) else stringResource(R.string.show)) } },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { keyboard?.hide() }),
        modifier = Modifier.fillMaxWidth())
    OutlinedButton(test, enabled = !testing && !recording) {
        if (testing) { CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp); Spacer(Modifier.width(Design.spaceSm)) }
        Text(if (testing) stringResource(R.string.testing) else stringResource(R.string.test_connection))
    }
}

@Composable
internal fun PreferenceGroups(
    config: LiveTranslateConfig, options: AppOptions, enabled: Boolean,
    onConfig: ((LiveTranslateConfig) -> LiveTranslateConfig) -> Unit,
    onOptions: ((AppOptions) -> AppOptions) -> Unit, canClear: Boolean, clear: () -> Unit,
    recording: Boolean = false, dialogueTargets: (@Composable () -> Unit)? = null,
) {
    val colors = MaterialTheme.colorScheme
    GroupTitle(stringResource(R.string.translation))
    var expanded by remember { mutableStateOf(false) }
    if (dialogueTargets != null) dialogueTargets() else Box {
        OutlinedButton({ expanded = true }, Modifier.fillMaxWidth(), enabled = enabled) { Text(stringResource(R.string.target_choice, config.languageName)) }
        DropdownMenu(expanded, { expanded = false }) {
            LiveTranslateConfig.LANGUAGES.forEach { (code, name) ->
                DropdownMenuItem(text = { Text(name) }, onClick = { expanded = false; onConfig { it.copy(language = code) } })
            }
        }
    }
    GroupTitle(stringResource(R.string.translated_audio))
    SettingSwitch(stringResource(R.string.play_translation), config.audioOutput, enabled) { value -> onConfig { it.copy(audioOutput = value) } }
    if (config.audioOutput) {
        if (dialogueTargets != null) Text(stringResource(R.string.dialogue_playback_timing), style = Design.caption)
        else Segments(stringResource(R.string.playback_timing), listOf(stringResource(R.string.streaming_playback), stringResource(R.string.final_playback)), config.playbackTiming.ordinal) { i ->
            if (enabled) onConfig { it.copy(playbackTiming = PlaybackTiming.entries[i]) }
        }
        var volume by remember(config.volume) { mutableFloatStateOf(config.volume) }
        Text(stringResource(R.string.volume_format, (volume * 100).toInt()))
        Slider(volume, { volume = it }, enabled = enabled, onValueChangeFinished = { onConfig { it.copy(volume = volume) } })
        Text(stringResource(R.string.headphones_brief), style = Design.caption)
    }
    GroupTitle(stringResource(R.string.network))
    SettingSwitch(stringResource(R.string.auto_reconnect), options.autoReconnect, enabled) { value -> onOptions { it.copy(autoReconnect = value) } }
    SettingSwitch(stringResource(R.string.bluetooth_microphone), options.bluetoothMicrophone, enabled) { value -> onOptions { it.copy(bluetoothMicrophone = value) } }
    if (recording) Text(stringResource(R.string.bluetooth_next_start), style = Design.caption)
    GroupTitle(stringResource(R.string.session_history))
    SettingSwitch(stringResource(R.string.save_history), options.saveSessions, enabled) { value -> onOptions { it.copy(saveSessions = value) } }
    Text(stringResource(R.string.history_brief), style = Design.caption)
    OutlinedButton(clear, enabled = canClear && enabled, colors = ButtonDefaults.outlinedButtonColors(contentColor = colors.error)) { Text(stringResource(R.string.delete_sessions)) }
    GroupTitle(stringResource(R.string.about))
    Text(stringResource(R.string.app_name), style = Design.source)
    Text(stringResource(R.string.privacy_brief), style = Design.caption)
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
