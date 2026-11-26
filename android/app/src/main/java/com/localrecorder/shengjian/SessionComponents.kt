package com.localrecorder.shengjian

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.annotation.DrawableRes
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.localrecorder.live.AudioSourceMode
import com.localrecorder.live.InterfaceLanguage
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.SessionSnapshot
import com.localrecorder.live.SessionState
import com.localrecorder.live.SubtitleRow
import com.localrecorder.shengjian.ui.theme.Design
import com.localrecorder.shengjian.ui.theme.LocalStatusColors
import kotlinx.coroutines.launch

@Composable
internal fun Glyph(@DrawableRes id: Int, modifier: Modifier = Modifier, tint: Color = LocalContentColor.current) =
    Icon(painterResource(id), contentDescription = null, modifier = modifier, tint = tint)

@Composable
internal fun Tool(
    @DrawableRes id: Int,
    label: String,
    enabled: Boolean = true,
    tint: Color = LocalContentColor.current,
    click: () -> Unit,
) {
    IconButton(onClick = click, enabled = enabled, modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)) {
        Icon(painterResource(id), contentDescription = label, tint = if (enabled) tint else tint.copy(alpha = 0.38f))
    }
}

/** High-contrast foreground color paired with the semantic recording color in both light and dark themes. */
internal fun onStatusColor(background: Color): Color =
    if (background.luminance() > 0.45f) Color(0xFF420D18) else Color.White

@Composable
internal fun AnimatedEqualizer(tint: Color, modifier: Modifier = Modifier.size(16.dp)) {
    val transition = rememberInfiniteTransition(label = "eq")
    val b1 by transition.animateFloat(0.32f, 1f, infiniteRepeatable(tween(720, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "b1")
    val b2 by transition.animateFloat(1f, 0.35f, infiniteRepeatable(tween(580, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "b2")
    val b3 by transition.animateFloat(0.45f, 1f, infiniteRepeatable(tween(820, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "b3")
    val b4 by transition.animateFloat(0.85f, 0.28f, infiniteRepeatable(tween(640, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "b4")
    Canvas(modifier) {
        val bars = floatArrayOf(b1, b2, b3, b4)
        val barWidth = size.width / 7f
        val gap = barWidth * 0.9f
        val totalWidth = barWidth * 4 + gap * 3
        val startX = (size.width - totalWidth) / 2f
        bars.forEachIndexed { index, fraction ->
            val h = size.height * fraction.coerceIn(0.25f, 1f)
            val x = startX + index * (barWidth + gap)
            val y = (size.height - h) / 2f
            drawRoundRect(
                color = tint,
                topLeft = Offset(x, y),
                size = Size(barWidth, h),
                cornerRadius = CornerRadius(barWidth / 2f, barWidth / 2f),
            )
        }
    }
}

@Composable
internal fun PulsingDot(color: Color, modifier: Modifier = Modifier.size(7.dp)) {
    val transition = rememberInfiniteTransition(label = "pulse")
    val alpha by transition.animateFloat(1f, 0.38f, infiniteRepeatable(tween(950), RepeatMode.Reverse), label = "alpha")
    Box(
        modifier
            .graphicsLayer { this.alpha = alpha }
            .clip(CircleShape)
            .background(color),
    )
}

@Composable
internal fun SessionHeader(
    title: String,
    openList: (() -> Unit)?,
    statusContent: (@Composable () -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .padding(horizontal = Design.spaceSm, vertical = Design.spaceXs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (openList != null) Tool(R.drawable.ic_menu, stringResource(R.string.session_history), click = openList)
        Column(
            Modifier
                .weight(1f)
                .padding(horizontal = Design.spaceSm),
            verticalArrangement = Arrangement.spacedBy(Design.spaceXs),
        ) {
            Text(
                title,
                style = Design.title,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (statusContent != null) statusContent()
        }
        actions()
    }
}

@Composable
internal fun StatusPill(snapshot: SessionSnapshot, hasSession: Boolean, modifier: Modifier = Modifier) {
    val status = LocalStatusColors.current
    val colors = MaterialTheme.colorScheme
    val context = LocalContext.current
    val config = LocalConfiguration.current
    val statusText = remember(snapshot.status, snapshot.statusMessage, context, config) { context.formatStatus(snapshot) }
    val key = when {
        snapshot.error.isNotBlank() || snapshot.errorMessage != null -> 0
        snapshot.slowNetwork -> 1
        snapshot.state == SessionState.RECORDING -> 2
        snapshot.state == SessionState.CONNECTING || snapshot.state == SessionState.RECONNECTING -> 3
        snapshot.state == SessionState.FINISHING -> 4
        hasSession -> 5
        else -> 6
    }
    AnimatedContent(
        targetState = key,
        transitionSpec = {
            (fadeIn(tween(180)) + scaleIn(initialScale = 0.96f, animationSpec = tween(180)))
                .togetherWith(fadeOut(tween(140)))
        },
        modifier = modifier,
        label = "statusPill",
    ) { mode ->
        val (label, tint) = when (mode) {
            0 -> stringResource(R.string.error_occurred) to colors.error
            1 -> stringResource(R.string.slow_status) to status.slow
            2 -> stringResource(R.string.recording) to status.recording
            3 -> statusText.ifBlank { stringResource(R.string.connecting) } to status.connecting
            4 -> stringResource(R.string.finishing) to status.connecting
            5 -> stringResource(R.string.completed) to status.complete
            else -> stringResource(R.string.ready) to status.complete
        }
        Surface(
            color = tint.copy(alpha = 0.12f),
            shape = CircleShape,
        ) {
            Row(
                Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                when (mode) {
                    2 -> AnimatedEqualizer(tint, Modifier.size(14.dp))
                    3, 4 -> CircularProgressIndicator(Modifier.size(13.dp), color = tint, strokeWidth = 1.8.dp)
                    0, 1 -> Glyph(R.drawable.ic_warning, Modifier.size(14.dp), tint = tint)
                    else -> Glyph(R.drawable.ic_check_circle, Modifier.size(14.dp), tint = tint)
                }
                Text(label, style = Design.caption, color = tint, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
internal fun SubtitleText(row: SubtitleRow, stamp: String? = null, onCopy: (() -> Unit)? = null) {
    val colors = MaterialTheme.colorScheme
    val draft = row.source.isNotEmpty() && !row.sourceDone || row.translation.isNotEmpty() && !row.translationDone
    val speaker = when (row.speaker) {
        "A", "B" -> stringResource(R.string.dialogue_speaker, row.speaker.orEmpty())
        "unknown" -> stringResource(R.string.dialogue_unknown)
        else -> null
    }
    val caption = listOfNotNull(stamp, speaker, stringResource(R.string.transcribing).takeIf { draft }).joinToString("  ·  ")

    if (draft) {
        val barColor = colors.primary
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Design.spaceMd, vertical = 6.dp),
            color = colors.surfaceContainerLow,
            shape = RoundedCornerShape(Design.radiusCard),
            border = BorderStroke(1.dp, colors.outlineVariant),
        ) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .drawBehind {
                        val barWidth = 3.5.dp.toPx()
                        val insetY = 10.dp.toPx()
                        if (size.height > insetY * 2) {
                            drawRoundRect(
                                color = barColor,
                                topLeft = Offset(0f, insetY),
                                size = Size(barWidth, size.height - insetY * 2),
                                cornerRadius = CornerRadius(barWidth, barWidth),
                            )
                        }
                    }
                    .padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(Design.spaceXs),
            ) {
                if (caption.isNotEmpty()) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        PulsingDot(colors.primary)
                        Text(caption, style = Design.caption, color = colors.primary)
                    }
                }
                if (row.translation.isNotEmpty()) {
                    Text(
                        row.translation,
                        style = Design.translation,
                        color = colors.onSurface.copy(alpha = if (row.translationDone) 1f else Design.draftOpacity),
                    )
                }
                if (row.source.isNotEmpty()) {
                    Text(
                        row.source,
                        style = Design.source,
                        color = colors.onSurfaceVariant.copy(alpha = if (row.sourceDone) 1f else Design.draftOpacity),
                    )
                }
            }
        }
    } else {
        val rowModifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 2.dp)
            .clip(RoundedCornerShape(Design.radiusButton))
            .then(if (onCopy != null) Modifier.clickable(onClick = onCopy) else Modifier)
            .padding(horizontal = 12.dp, vertical = 10.dp)
        Column(rowModifier, verticalArrangement = Arrangement.spacedBy(Design.spaceXs)) {
            if (caption.isNotEmpty()) {
                Text(caption, style = Design.caption, color = colors.onSurfaceVariant)
            }
            if (row.translation.isNotEmpty()) {
                Text(row.translation, style = Design.translation, color = colors.onSurface)
            }
            if (row.source.isNotEmpty()) {
                Text(row.source, style = Design.source, color = colors.onSurfaceVariant)
            }
        }
    }
}

@Composable
internal fun LanguagePillButton(
    label: String,
    enabled: Boolean = true,
    leadingDot: Color? = null,
    showGlobe: Boolean = false,
    containerColor: Color = MaterialTheme.colorScheme.surfaceContainerLowest,
    onClick: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = CircleShape,
        color = containerColor,
        border = BorderStroke(1.dp, colors.outlineVariant),
        modifier = Modifier.heightIn(min = 40.dp),
    ) {
        Row(
            Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (leadingDot != null) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(leadingDot))
            } else if (showGlobe) {
                Glyph(R.drawable.ic_language, Modifier.size(16.dp), tint = colors.primary)
            }
            Text(
                label,
                style = Design.caption.copy(fontWeight = FontWeight.SemiBold),
                color = if (enabled) colors.onSurface else colors.onSurface.copy(alpha = 0.38f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Glyph(R.drawable.ic_expand_more, Modifier.size(16.dp), tint = colors.onSurfaceVariant)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LanguagePickerSheet(
    title: String,
    selected: String,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
    other: String? = null,
    inverted: Boolean = false,
    subtitle: String? = null,
) {
    val colors = MaterialTheme.colorScheme
    val gridContent: @Composable () -> Unit = {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = Design.spaceMd, vertical = Design.spaceSm),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(Modifier.fillMaxWidth().padding(horizontal = Design.spaceXs), verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = Design.title, modifier = Modifier.weight(1f))
                if (subtitle != null) {
                    Text(subtitle, style = Design.caption, color = colors.onSurfaceVariant)
                }
            }
            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth().heightIn(max = 320.dp),
            ) {
                items(LiveTranslateConfig.LANGUAGES, key = { it.first }) { (code, name) ->
                    val isSelected = code == selected
                    val isEnabled = code != other
                    Surface(
                        onClick = { onSelect(code); onDismiss() },
                        enabled = isEnabled,
                        shape = RoundedCornerShape(Design.radiusButton),
                        color = if (isSelected) colors.primaryContainer else colors.surfaceContainerLowest,
                        border = BorderStroke(if (isSelected) 1.5.dp else 1.dp, if (isSelected) colors.primary else colors.outlineVariant),
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) {
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 12.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(
                                code.uppercase(),
                                style = Design.caption,
                                color = if (isSelected) colors.onPrimaryContainer.copy(alpha = 0.72f) else colors.onSurfaceVariant,
                            )
                            Text(
                                name,
                                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal),
                                color = when {
                                    !isEnabled -> colors.onSurface.copy(alpha = 0.38f)
                                    isSelected -> colors.onPrimaryContainer
                                    else -> colors.onSurface
                                },
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                            if (isSelected) {
                                Glyph(R.drawable.ic_check_circle, Modifier.size(18.dp), tint = colors.primary)
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(Design.spaceSm))
        }
    }

    if (inverted) {
        Dialog(onDismissRequest = onDismiss) {
            Surface(
                modifier = Modifier.graphicsLayer { rotationZ = 180f },
                shape = RoundedCornerShape(Design.radiusSheet),
                color = colors.surfaceContainerLow,
            ) {
                Box(Modifier.padding(top = Design.spaceMd)) { gridContent() }
            }
        }
    } else {
        ModalBottomSheet(onDismissRequest = onDismiss, containerColor = colors.surfaceContainerLow) {
            gridContent()
        }
    }
}

@Composable
internal fun OverlayPermissionDialog(
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.floating_subtitle)) },
        text = { Text(stringResource(R.string.floating_permission_rationale)) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(stringResource(R.string.floating_permission_go_settings))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.cancel))
            }
        },
    )
}

internal fun openOverlayPermissionSettings(context: Context) {
    val specific = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}"))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    try {
        context.startActivity(specific)
    } catch (_: Exception) {
        try {
            context.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) {
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AudioSourceBar(
    selected: AudioSourceMode,
    canSwitch: Boolean,
    systemAudioSupported: Boolean,
    floatingSubtitleEnabled: Boolean,
    overlayPermissionGranted: Boolean,
    onSelect: (AudioSourceMode) -> Unit,
    onUnsupportedTap: () -> Unit,
    onToggleFloatingSubtitle: (Boolean) -> Unit,
    onRequestOverlayPermission: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val choices = listOf(
        AudioSourceMode.MICROPHONE to stringResource(R.string.audio_mode_mic),
        AudioSourceMode.SYSTEM_AUDIO to stringResource(R.string.audio_mode_system),
        AudioSourceMode.SYSTEM_AND_MIC to stringResource(R.string.audio_mode_mixed),
    )
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(colors.surface)
            .padding(horizontal = Design.spaceMd, vertical = Design.spaceXs),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            choices.forEachIndexed { index, (mode, label) ->
                val unsupported = mode.usesSystemAudio && !systemAudioSupported
                val isSelected = selected == mode
                SegmentedButton(
                    selected = isSelected,
                    onClick = {
                        if (unsupported) onUnsupportedTap() else onSelect(mode)
                    },
                    enabled = canSwitch && !unsupported,
                    shape = SegmentedButtonDefaults.itemShape(index, choices.size),
                    colors = SegmentedButtonDefaults.colors(
                        activeContainerColor = colors.secondaryContainer,
                        activeContentColor = colors.onSecondaryContainer,
                        inactiveContainerColor = colors.surfaceContainerLow,
                        inactiveContentColor = if (unsupported) colors.onSurface.copy(alpha = 0.38f) else colors.onSurfaceVariant,
                    ),
                ) {
                    Text(
                        label,
                        style = Design.caption.copy(fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Medium),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        AnimatedVisibility(
            visible = !systemAudioSupported,
            enter = fadeIn(tween(180)),
            exit = fadeOut(tween(140)),
        ) {
            Text(
                stringResource(R.string.system_audio_android_10_hint),
                style = Design.caption,
                color = colors.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = Design.spaceXs),
            )
        }
        AnimatedVisibility(
            visible = systemAudioSupported && selected.usesSystemAudio,
            enter = fadeIn(tween(180)),
            exit = fadeOut(tween(140)),
        ) {
            Row(
                Modifier.fillMaxWidth().padding(top = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = if (overlayPermissionGranted) {
                        stringResource(
                            if (floatingSubtitleEnabled) R.string.floating_subtitle_active_hint
                            else R.string.floating_subtitle_off_hint,
                        )
                    } else {
                        stringResource(R.string.floating_subtitle_optional_hint)
                    },
                    style = Design.caption,
                    color = colors.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f).padding(end = Design.spaceSm),
                )
                Surface(
                    onClick = {
                        if (overlayPermissionGranted) onToggleFloatingSubtitle(!floatingSubtitleEnabled)
                        else onRequestOverlayPermission()
                    },
                    shape = CircleShape,
                    color = if (overlayPermissionGranted && floatingSubtitleEnabled) colors.primaryContainer else colors.surfaceContainer,
                    border = BorderStroke(
                        1.dp,
                        if (overlayPermissionGranted && floatingSubtitleEnabled) colors.primary.copy(alpha = 0.45f) else colors.outlineVariant,
                    ),
                    modifier = Modifier.heightIn(min = 34.dp),
                ) {
                    Row(
                        Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                    ) {
                        Glyph(
                            R.drawable.ic_subtitles,
                            Modifier.size(15.dp),
                            tint = if (overlayPermissionGranted && floatingSubtitleEnabled) colors.onPrimaryContainer else colors.onSurfaceVariant,
                        )
                        Text(
                            text = when {
                                !overlayPermissionGranted -> stringResource(R.string.enable_floating_subtitle)
                                floatingSubtitleEnabled -> stringResource(R.string.floating_subtitle_on)
                                else -> stringResource(R.string.floating_subtitle_off)
                            },
                            style = Design.caption.copy(fontWeight = FontWeight.SemiBold),
                            color = if (overlayPermissionGranted && floatingSubtitleEnabled) colors.onPrimaryContainer else colors.onSurfaceVariant,
                            maxLines = 1,
                            softWrap = false,
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun BottomActionDock(
    languageLabel: String,
    languageEnabled: Boolean,
    onOpenLanguage: () -> Unit,
    audioOutput: Boolean,
    audioEnabled: Boolean,
    onToggleAudio: (Boolean) -> Unit,
    playing: Boolean,
    onStopPlayback: (() -> Unit)?,
    active: Boolean,
    primaryLabel: String,
    primaryEnabled: Boolean,
    onPrimaryClick: () -> Unit,
    returnToRecording: (() -> Unit)? = null,
    @DrawableRes idlePrimaryIcon: Int = R.drawable.ic_mic,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val status = LocalStatusColors.current
    val haptics = LocalHapticFeedback.current
    val buttonBg by animateColorAsState(
        targetValue = if (active) status.recording else colors.primary,
        animationSpec = tween(240),
        label = "dockPrimaryBg",
    )
    val buttonFg by animateColorAsState(
        targetValue = if (active) onStatusColor(status.recording) else colors.onPrimary,
        animationSpec = tween(240),
        label = "dockPrimaryFg",
    )
    val borderColor = colors.outlineVariant

    Surface(
        modifier = modifier.fillMaxWidth(),
        color = colors.surfaceContainerLow,
        shape = RoundedCornerShape(topStart = Design.radiusSheet, topEnd = Design.radiusSheet),
        tonalElevation = 2.dp,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .drawBehind {
                    drawLine(
                        color = borderColor.copy(alpha = 0.7f),
                        start = Offset(0f, 0f),
                        end = Offset(size.width, 0f),
                        strokeWidth = 1.dp.toPx(),
                    )
                }
                .navigationBarsPadding()
                .displayCutoutPadding()
                .padding(horizontal = Design.spaceMd, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            FlowRow(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                LanguagePillButton(
                    label = languageLabel,
                    enabled = languageEnabled,
                    showGlobe = true,
                    onClick = onOpenLanguage,
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    AnimatedVisibility(
                        visible = audioOutput && playing && onStopPlayback != null,
                        enter = fadeIn(tween(180)) + scaleIn(initialScale = 0.9f),
                        exit = fadeOut(tween(140)) + scaleOut(targetScale = 0.9f),
                    ) {
                        Surface(
                            onClick = { onStopPlayback?.invoke() },
                            shape = CircleShape,
                            color = colors.primaryContainer,
                            modifier = Modifier.heightIn(min = 40.dp),
                        ) {
                            Row(
                                Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(5.dp),
                            ) {
                                AnimatedEqualizer(colors.onPrimaryContainer, Modifier.size(14.dp))
                                Text(
                                    stringResource(R.string.stop_audio_short),
                                    style = Design.caption,
                                    color = colors.onPrimaryContainer,
                                    maxLines = 1,
                                    softWrap = false,
                                )
                            }
                        }
                    }
                    val audioDesc = stringResource(R.string.translated_audio)
                    Surface(
                        onClick = { onToggleAudio(!audioOutput) },
                        enabled = audioEnabled,
                        shape = CircleShape,
                        color = if (audioOutput) colors.secondaryContainer else colors.surfaceContainer,
                        modifier = Modifier
                            .heightIn(min = 40.dp)
                            .semantics { contentDescription = audioDesc },
                    ) {
                        Row(
                            Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Glyph(
                                if (audioOutput) R.drawable.ic_volume_up else R.drawable.ic_volume_off,
                                Modifier.size(16.dp),
                                tint = if (audioOutput) colors.onSecondaryContainer else colors.onSurfaceVariant,
                            )
                            Text(
                                stringResource(if (audioOutput) R.string.audio_on else R.string.audio_off),
                                style = Design.caption,
                                color = if (audioOutput) colors.onSecondaryContainer else colors.onSurfaceVariant,
                                maxLines = 1,
                                softWrap = false,
                            )
                        }
                    }
                }
            }

            if (returnToRecording != null) {
                TextButton(onClick = returnToRecording, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.return_to_recording))
                }
            }

            Button(
                onClick = {
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    onPrimaryClick()
                },
                enabled = primaryEnabled,
                colors = ButtonDefaults.buttonColors(
                    containerColor = buttonBg,
                    contentColor = buttonFg,
                ),
                shape = RoundedCornerShape(Design.radiusCard),
                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp),
            ) {
                Glyph(if (active) R.drawable.ic_stop else idlePrimaryIcon, Modifier.size(20.dp))
                Spacer(Modifier.width(Design.spaceSm))
                Text(
                    primaryLabel,
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
internal fun GroupTitle(label: String) {
    Text(
        label,
        Modifier.padding(start = 4.dp, top = Design.spaceSm, bottom = 2.dp),
        style = Design.caption.copy(fontWeight = FontWeight.SemiBold),
        color = MaterialTheme.colorScheme.primary,
    )
}

@Composable
internal fun SettingsCard(
    modifier: Modifier = Modifier,
    containerColor: Color = MaterialTheme.colorScheme.surfaceContainerLow,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = containerColor,
        shape = RoundedCornerShape(Design.radiusCard),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column(
            Modifier.fillMaxWidth().padding(Design.spaceMd),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            content = content,
        )
    }
}

@Composable
internal fun Welcome(settings: () -> Unit, later: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val transition = rememberInfiniteTransition(label = "welcomeHalo")
    val haloScale by transition.animateFloat(
        initialValue = 1f,
        targetValue = 1.09f,
        animationSpec = infiniteRepeatable(tween(2800, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "haloScale",
    )
    Surface(Modifier.fillMaxSize(), color = colors.surface) {
        Column(
            Modifier
                .fillMaxSize()
                .safeDrawingPadding()
                .padding(horizontal = Design.spaceLg, vertical = Design.spaceMd),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(contentAlignment = Alignment.Center, modifier = Modifier.padding(bottom = Design.spaceLg)) {
                    Box(
                        Modifier
                            .size(112.dp)
                            .graphicsLayer { scaleX = haloScale; scaleY = haloScale }
                            .clip(CircleShape)
                            .background(colors.primaryContainer.copy(alpha = 0.55f)),
                    )
                    Surface(
                        modifier = Modifier.size(80.dp),
                        shape = RoundedCornerShape(20.dp),
                        color = colorResource(R.color.launcher_background),
                        shadowElevation = 4.dp,
                    ) {
                        Box(Modifier.fillMaxSize().clip(RoundedCornerShape(20.dp)), contentAlignment = Alignment.Center) {
                            Icon(
                                painterResource(R.drawable.ic_launcher_foreground),
                                contentDescription = stringResource(R.string.app_name),
                                modifier = Modifier.requiredSize(120.dp),
                                tint = Color.Unspecified,
                            )
                        }
                    }
                }

                Text(stringResource(R.string.welcome_title), style = Design.title, textAlign = TextAlign.Center)
                Spacer(Modifier.height(Design.spaceSm))
                Text(
                    stringResource(R.string.welcome_description),
                    style = Design.source,
                    color = colors.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(Design.spaceLg))

                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    WelcomePermissionCard(
                        icon = R.drawable.ic_mic,
                        iconBg = colors.primaryContainer,
                        iconTint = colors.onPrimaryContainer,
                        title = stringResource(R.string.permission_mic),
                        detail = stringResource(R.string.welcome_privacy_mic),
                    )
                    WelcomePermissionCard(
                        icon = R.drawable.ic_notifications,
                        iconBg = colors.secondaryContainer,
                        iconTint = colors.onSecondaryContainer,
                        title = stringResource(R.string.permission_notifications),
                        detail = stringResource(R.string.welcome_notification),
                    )
                }
            }

            Spacer(Modifier.height(Design.spaceMd))
            Button(
                onClick = settings,
                shape = RoundedCornerShape(Design.radiusCard),
                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp),
            ) {
                Glyph(R.drawable.ic_key, Modifier.size(18.dp))
                Spacer(Modifier.width(Design.spaceSm))
                Text(stringResource(R.string.setup_service))
            }
            Spacer(Modifier.height(Design.spaceXs))
            TextButton(onClick = later, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.later), color = colors.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun WelcomePermissionCard(
    @DrawableRes icon: Int,
    iconBg: Color,
    iconTint: Color,
    title: String,
    detail: String,
) {
    val colors = MaterialTheme.colorScheme
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = colors.surfaceContainerLow,
        shape = RoundedCornerShape(Design.radiusCard),
        border = BorderStroke(1.dp, colors.outlineVariant),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(14.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Box(
                Modifier
                    .size(40.dp)
                    .clip(RoundedCornerShape(Design.radiusButton))
                    .background(iconBg),
                contentAlignment = Alignment.Center,
            ) {
                Glyph(icon, Modifier.size(20.dp), tint = iconTint)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold), color = colors.onSurface)
                Text(detail, style = Design.caption, color = colors.onSurfaceVariant)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun Segments(title: String, choices: List<String>, selected: Int, onSelect: (Int) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = Design.caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            choices.forEachIndexed { i, choice ->
                SegmentedButton(
                    selected = i == selected,
                    onClick = { onSelect(i) },
                    shape = SegmentedButtonDefaults.itemShape(i, choices.size),
                ) {
                    Text(choice, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun InterfaceLanguagePickerSheet(
    selected: InterfaceLanguage,
    onSelect: (InterfaceLanguage) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var closing by remember { mutableStateOf(false) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.surfaceContainerLow,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Design.spaceMd, vertical = Design.spaceSm),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                stringResource(R.string.interface_language),
                style = Design.title,
                modifier = Modifier.padding(horizontal = Design.spaceXs, vertical = 4.dp),
            )
            val choices = remember { listOf(InterfaceLanguage.SYSTEM) + InterfaceLanguage.SUPPORTED }
            choices.forEach { option ->
                val isSelected = option == selected
                val label = option.nativeName ?: stringResource(R.string.follow_system)
                Surface(
                    onClick = {
                        if (closing) return@Surface
                        closing = true
                        scope.launch {
                            try {
                                sheetState.hide()
                            } finally {
                                onDismiss()
                            }
                            if (option != selected) {
                                onSelect(option)
                            }
                        }
                    },
                    shape = RoundedCornerShape(Design.radiusButton),
                    color = if (isSelected) colors.primaryContainer else colors.surfaceContainerLowest,
                    border = BorderStroke(if (isSelected) 1.5.dp else 1.dp, if (isSelected) colors.primary else colors.outlineVariant),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                ) {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Text(
                            label,
                            style = MaterialTheme.typography.bodyMedium.copy(fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal),
                            color = if (isSelected) colors.onPrimaryContainer else colors.onSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        if (isSelected) {
                            Glyph(R.drawable.ic_check_circle, Modifier.size(18.dp), tint = colors.primary)
                        }
                    }
                }
            }
            Spacer(Modifier.height(Design.spaceMd))
        }
    }
}
