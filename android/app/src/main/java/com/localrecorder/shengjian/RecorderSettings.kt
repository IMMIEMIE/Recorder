package com.localrecorder.shengjian

import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.localrecorder.live.InterfaceLanguage
import com.localrecorder.live.LiveServiceProfile
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.PlaybackTiming
import com.localrecorder.live.SessionState
import com.localrecorder.shengjian.ui.theme.Design
import com.localrecorder.shengjian.ui.theme.LocalStatusColors

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

    val context = LocalContext.current
    val activity = context as? ComponentActivity
    val interfaceLanguage = remember(context) { AppLocale.currentLanguage(context) }
    val recording = ui.session.state != SessionState.IDLE
    SettingsLayout(back = ::leave, recording = recording, service = {
        if (recording) {
            Text(stringResource(R.string.dialogue_service_locked), style = Design.caption, color = LocalStatusColors.current.recording)
        }
        ServiceFields(
            profile = profile,
            config = ui.config,
            key = key,
            keySaved = remember(profile.endpoint, ui.hasKey) { controller.hasKey(profile.endpoint) },
            testing = ui.testing,
            testSucceeded = ui.testSucceeded,
            statusMessage = when {
                ui.testing -> stringResource(R.string.test_in_progress)
                ui.testSucceeded == false && ui.settingsMessage.isNotEmpty() -> stringResource(R.string.test_failure, ui.settingsMessage)
                else -> ui.settingsMessage
            },
            isError = invalid || ui.testSucceeded == false,
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
    }) {
        PreferenceGroups(
            config = ui.config,
            options = ui.options,
            enabled = !ui.testing && ui.session.state != SessionState.FINISHING,
            onConfig = { change -> if (commitService()) controller.saveSettings(change(controller.ui.value.config), "", controller.ui.value.options) },
            onOptions = { change -> if (commitService()) controller.saveSettings(controller.ui.value.config, "", change(controller.ui.value.options)) },
            canClear = ui.sessions.isNotEmpty() && ui.recordingId == null,
            clear = { confirmClear = true },
            recording = recording,
            interfaceLanguage = interfaceLanguage,
            onSelectInterfaceLanguage = { selected ->
                if (selected != interfaceLanguage && activity != null) {
                    if (commitService()) AppLocale.applyLanguage(activity, selected)
                }
            },
            dialogueTargets = if (ui.dialogueMode) ({
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("A" to ui.dialogueLanguageA, "B" to ui.dialogueLanguageB).forEach { (side, code) ->
                        val name = LiveTranslateConfig.LANGUAGES.first { it.first == code }.second
                        val other = if (side == "A") ui.dialogueLanguageB else ui.dialogueLanguageA
                        LanguageChoice(
                            label = stringResource(R.string.side_label, side, name),
                            selected = code,
                            onSelect = { if (side == "A") controller.setDialogueLanguages(it, other) else controller.setDialogueLanguages(other, it) },
                            enabled = ui.session.state != SessionState.FINISHING,
                            other = other,
                            leadingDot = if (side == "A") MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.tertiary,
                        )
                    }
                }
            }) else null,
        )
    }
    if (discard) {
        ConfirmDialog(
            stringResource(R.string.settings_unsaved),
            stringResource(R.string.discard_hint),
            stringResource(R.string.discard_changes),
            onDismiss = { discard = false },
            onConfirm = onBack,
        )
    }
    if (confirmClear) {
        ConfirmDialog(
            stringResource(R.string.delete_all_question),
            stringResource(R.string.delete_all_detail),
            stringResource(R.string.delete_all),
            onDismiss = { confirmClear = false },
            onConfirm = { controller.deleteAll(); confirmClear = false },
        )
    }
}

/** The service editor is a slot so profile/protocol changes can supply their own fields. */
@Composable
internal fun SettingsLayout(
    back: () -> Unit,
    recording: Boolean = false,
    service: @Composable ColumnScope.() -> Unit,
    preferences: @Composable ColumnScope.() -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    Surface(Modifier.fillMaxSize(), color = colors.surface) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = Design.spaceSm, vertical = Design.spaceXs),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Tool(R.drawable.ic_arrow_back, stringResource(R.string.back), click = back)
                Text(stringResource(R.string.settings), style = Design.title, modifier = Modifier.weight(1f))
                if (recording) {
                    val rec = LocalStatusColors.current.recording
                    Surface(color = rec.copy(alpha = 0.12f), shape = CircleShape, modifier = Modifier.padding(end = Design.spaceSm)) {
                        Text(
                            stringResource(R.string.recording),
                            style = Design.caption,
                            color = rec,
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                        )
                    }
                }
            }
            HorizontalDivider(color = colors.outlineVariant)
            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .fillMaxWidth()
                    .padding(horizontal = Design.spaceMd, vertical = Design.spaceMd),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                GroupTitle(stringResource(R.string.service_section))
                SettingsCard { service() }
                preferences()
            }
        }
    }
}

@Composable
internal fun ServiceFields(
    profile: LiveServiceProfile,
    config: LiveTranslateConfig,
    key: String,
    keySaved: Boolean,
    testing: Boolean,
    onEdit: (LiveServiceProfile) -> Unit,
    onSelect: (LiveServiceProfile) -> Unit,
    onKey: (String) -> Unit,
    test: () -> Unit,
    recording: Boolean = false,
    testSucceeded: Boolean? = null,
    statusMessage: String = "",
    isError: Boolean = false,
) {
    var visible by remember(profile.id) { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current
    val colors = MaterialTheme.colorScheme
    val statusColors = LocalStatusColors.current

    LiveServiceProfileEditor(profile, config, testing, onEdit, onSelect, recording)
    OutlinedTextField(
        value = key,
        onValueChange = onKey,
        label = { Text(stringResource(R.string.api_key)) },
        placeholder = { Text(if (keySaved) stringResource(R.string.use_saved_key) else stringResource(R.string.enter_service_key)) },
        singleLine = true,
        enabled = !testing && !recording,
        shape = RoundedCornerShape(Design.radiusButton),
        colors = OutlinedTextFieldDefaults.colors(
            unfocusedContainerColor = colors.surfaceContainerLowest,
            focusedContainerColor = colors.surfaceContainerLowest,
            unfocusedBorderColor = colors.outlineVariant,
        ),
        visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
        trailingIcon = {
            TextButton({ visible = !visible }, enabled = !recording) {
                Text(if (visible) stringResource(R.string.hide) else stringResource(R.string.show))
            }
        },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { keyboard?.hide() }),
        modifier = Modifier.fillMaxWidth(),
    )

    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        FilledTonalButton(
            onClick = test,
            enabled = !testing && !recording,
            shape = RoundedCornerShape(Design.radiusButton),
            modifier = Modifier.heightIn(min = 44.dp),
        ) {
            if (testing) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(Design.spaceSm))
            }
            Text(if (testing) stringResource(R.string.testing) else stringResource(R.string.test_connection))
        }
        val helper = statusMessage.ifBlank { stringResource(R.string.service_auto_save) }
        val helperColor = when {
            isError -> colors.error
            testSucceeded == true -> statusColors.complete
            else -> colors.onSurfaceVariant
        }
        Row(
            Modifier.weight(1f),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (testSucceeded == true) {
                Glyph(R.drawable.ic_check_circle, Modifier.size(15.dp), tint = statusColors.complete)
            } else if (isError) {
                Glyph(R.drawable.ic_warning, Modifier.size(15.dp), tint = colors.error)
            }
            Text(helper, style = Design.caption, color = helperColor)
        }
    }
}

@Composable
internal fun PreferenceGroups(
    config: LiveTranslateConfig,
    options: AppOptions,
    enabled: Boolean,
    onConfig: ((LiveTranslateConfig) -> LiveTranslateConfig) -> Unit,
    onOptions: ((AppOptions) -> AppOptions) -> Unit,
    canClear: Boolean,
    clear: () -> Unit,
    recording: Boolean = false,
    interfaceLanguage: InterfaceLanguage = InterfaceLanguage.SYSTEM,
    onSelectInterfaceLanguage: (InterfaceLanguage) -> Unit = {},
    dialogueTargets: (@Composable () -> Unit)? = null,
) {
    val colors = MaterialTheme.colorScheme
    var showLanguageSheet by rememberSaveable { mutableStateOf(false) }
    var showInterfaceLanguageSheet by rememberSaveable { mutableStateOf(false) }

    // Group 2: Translation & Audio
    GroupTitle(stringResource(R.string.translation_and_audio))
    SettingsCard {
        if (dialogueTargets != null) {
            dialogueTargets()
        } else {
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(Design.radiusInput))
                    .clickable(enabled = enabled) { showLanguageSheet = true }
                    .heightIn(min = 48.dp)
                    .padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    stringResource(R.string.default_target_language),
                    style = Design.source,
                    color = colors.onSurface,
                    modifier = Modifier.weight(1f),
                )
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        config.languageName,
                        style = Design.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.primary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Glyph(R.drawable.ic_expand_more, Modifier.size(18.dp), tint = colors.primary)
                }
            }
        }

        HorizontalDivider(color = colors.outlineVariant.copy(alpha = 0.7f))

        SettingSwitch(
            label = stringResource(R.string.play_translation),
            subtitle = stringResource(R.string.headphones_brief),
            value = config.audioOutput,
            enabled = enabled,
        ) { value -> onConfig { it.copy(audioOutput = value) } }

        AnimatedVisibility(
            visible = config.audioOutput,
            enter = expandVertically(tween(220)) + fadeIn(tween(180)),
            exit = shrinkVertically(tween(180)) + fadeOut(tween(140)),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (dialogueTargets != null) {
                    Text(stringResource(R.string.dialogue_playback_timing), style = Design.caption, color = colors.onSurfaceVariant)
                } else {
                    Segments(
                        stringResource(R.string.playback_timing),
                        listOf(stringResource(R.string.streaming_playback), stringResource(R.string.final_playback)),
                        config.playbackTiming.ordinal,
                    ) { i -> if (enabled) onConfig { it.copy(playbackTiming = PlaybackTiming.entries[i]) } }
                }
                var volume by remember(config.volume) { mutableFloatStateOf(config.volume) }
                Column {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(stringResource(R.string.volume), style = Design.caption, color = colors.onSurfaceVariant)
                        Text("${(volume * 100).toInt()}%", style = Design.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.onSurface)
                    }
                    Slider(
                        value = volume,
                        onValueChange = { volume = it },
                        enabled = enabled,
                        onValueChangeFinished = { onConfig { it.copy(volume = volume) } },
                    )
                }
            }
        }
    }

    // Group 3: Network & Local History
    GroupTitle(stringResource(R.string.network_and_history))
    SettingsCard {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(Design.radiusInput))
                .clickable(enabled = enabled) { showInterfaceLanguageSheet = true }
                .heightIn(min = 48.dp)
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(stringResource(R.string.interface_language), style = Design.source, color = colors.onSurface)
                Text(stringResource(R.string.interface_language_hint), style = Design.caption, color = colors.onSurfaceVariant)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    interfaceLanguage.nativeName ?: stringResource(R.string.follow_system),
                    style = Design.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.primary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Glyph(R.drawable.ic_expand_more, Modifier.size(18.dp), tint = colors.primary)
            }
        }

        HorizontalDivider(color = colors.outlineVariant.copy(alpha = 0.7f))

        SettingSwitch(
            label = stringResource(R.string.auto_reconnect),
            subtitle = stringResource(R.string.auto_reconnect_short),
            value = options.autoReconnect,
            enabled = enabled,
        ) { value -> onOptions { it.copy(autoReconnect = value) } }

        HorizontalDivider(color = colors.outlineVariant.copy(alpha = 0.7f))

        SettingSwitch(
            label = stringResource(R.string.bluetooth_microphone),
            subtitle = if (recording) stringResource(R.string.bluetooth_next_start) else stringResource(R.string.bluetooth_short),
            value = options.bluetoothMicrophone,
            enabled = enabled,
        ) { value -> onOptions { it.copy(bluetoothMicrophone = value) } }

        HorizontalDivider(color = colors.outlineVariant.copy(alpha = 0.7f))

        SettingSwitch(
            label = stringResource(R.string.save_history),
            subtitle = stringResource(R.string.history_brief),
            value = options.saveSessions,
            enabled = enabled,
        ) { value -> onOptions { it.copy(saveSessions = value) } }
    }

    // Group 4: Danger zone card (visually separated)
    Surface(
        color = colors.errorContainer,
        shape = RoundedCornerShape(Design.radiusCard),
        border = BorderStroke(1.dp, colors.error.copy(alpha = 0.2f)),
        modifier = Modifier.fillMaxWidth().padding(top = Design.spaceXs),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Design.spaceMd, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                stringResource(R.string.delete_sessions),
                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium),
                color = colors.onErrorContainer,
                modifier = Modifier.weight(1f).padding(end = Design.spaceSm),
            )
            Surface(
                onClick = clear,
                enabled = canClear && enabled,
                shape = RoundedCornerShape(Design.radiusButton),
                color = colors.surfaceContainerLowest,
                modifier = Modifier.heightIn(min = 40.dp),
            ) {
                Box(Modifier.padding(horizontal = 14.dp, vertical = 8.dp), contentAlignment = Alignment.Center) {
                    Text(
                        stringResource(R.string.clear_all_action),
                        style = Design.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = if (canClear && enabled) colors.error else colors.error.copy(alpha = 0.38f),
                    )
                }
            }
        }
    }

    // Footer: About & Privacy
    Column(
        Modifier.fillMaxWidth().padding(vertical = Design.spaceSm, horizontal = Design.spaceSm),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(stringResource(R.string.version_footer), style = Design.caption, color = colors.onSurfaceVariant, textAlign = TextAlign.Center)
        Text(stringResource(R.string.privacy_brief), style = Design.caption, color = colors.onSurfaceVariant.copy(alpha = 0.85f), textAlign = TextAlign.Center)
    }

    if (showLanguageSheet) {
        LanguagePickerSheet(
            title = stringResource(R.string.choose_language),
            subtitle = stringResource(R.string.language_live_hint),
            selected = config.language,
            onSelect = { code -> onConfig { it.copy(language = code) } },
            onDismiss = { showLanguageSheet = false },
        )
    }
    if (showInterfaceLanguageSheet) {
        InterfaceLanguagePickerSheet(
            selected = interfaceLanguage,
            onSelect = onSelectInterfaceLanguage,
            onDismiss = { showInterfaceLanguageSheet = false },
        )
    }
}

@Composable
private fun SettingSwitch(
    label: String,
    subtitle: String? = null,
    value: Boolean,
    enabled: Boolean,
    change: (Boolean) -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .toggleable(value, enabled, Role.Switch, change),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f).padding(end = Design.spaceSm), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = Design.source, color = MaterialTheme.colorScheme.onSurface)
            if (!subtitle.isNullOrBlank()) {
                Text(subtitle, style = Design.caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Switch(value, onCheckedChange = null, enabled = enabled)
    }
}
