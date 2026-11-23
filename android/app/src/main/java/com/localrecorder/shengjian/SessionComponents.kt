package com.localrecorder.shengjian

import androidx.annotation.DrawableRes
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.localrecorder.live.SessionSnapshot
import com.localrecorder.live.SessionState
import com.localrecorder.live.SubtitleRow
import com.localrecorder.shengjian.ui.theme.Design
import com.localrecorder.shengjian.ui.theme.LocalStatusColors

@Composable
internal fun Glyph(@DrawableRes id: Int) = Icon(painterResource(id), contentDescription = null)

@Composable
internal fun Tool(@DrawableRes id: Int, label: String, enabled: Boolean = true, click: () -> Unit) {
    IconButton(onClick = click, enabled = enabled, modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)) {
        Icon(painterResource(id), contentDescription = label)
    }
}

@Composable
internal fun SessionHeader(title: String, openList: (() -> Unit)?, actions: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = Design.spaceSm),
        verticalAlignment = Alignment.CenterVertically) {
        if (openList != null) Tool(R.drawable.ic_menu, stringResource(R.string.session_history), click = openList)
        Text(title, Modifier.weight(1f).padding(horizontal = Design.spaceSm), style = Design.title,
            maxLines = 2, overflow = TextOverflow.Ellipsis)
        actions()
    }
}

@Composable
internal fun SessionStatus(snapshot: SessionSnapshot, language: String, hasSession: Boolean, targetControl: (@Composable () -> Unit)? = null) {
    val status = LocalStatusColors.current
    val colors = MaterialTheme.colorScheme
    val (label, tint) = when {
        snapshot.error.isNotBlank() -> stringResource(R.string.error_occurred) to colors.error
        snapshot.slowNetwork -> stringResource(R.string.slow_status) to status.slow
        snapshot.state == SessionState.RECORDING -> stringResource(R.string.recording) to status.recording
        snapshot.state != SessionState.IDLE -> snapshot.status to status.connecting
        hasSession -> stringResource(R.string.completed) to status.complete
        else -> stringResource(R.string.ready) to status.complete
    }
    Row(Modifier.fillMaxWidth().padding(start = Design.spaceLg, end = Design.spaceMd, bottom = Design.spaceSm),
        horizontalArrangement = Arrangement.spacedBy(Design.spaceSm), verticalAlignment = Alignment.CenterVertically) {
        if (snapshot.state == SessionState.CONNECTING || snapshot.state == SessionState.RECONNECTING) {
            CircularProgressIndicator(Modifier.size(20.dp), color = tint, strokeWidth = 2.dp)
        } else {
            val recording = snapshot.state == SessionState.RECORDING
            val pulse = if (recording) rememberInfiniteTransition(label = "录制中")
                .animateFloat(.72f, 1f, infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "声波").value else 1f
            val symbol = when {
                snapshot.error.isNotBlank() || snapshot.slowNetwork -> R.drawable.ic_warning
                recording -> R.drawable.ic_graphic_eq
                else -> R.drawable.ic_check_circle
            }
            Icon(painterResource(symbol), null, Modifier.size(24.dp).graphicsLayer { scaleY = pulse }, tint = tint)
        }
        Column(Modifier.weight(1f)) {
            Text(label, style = Design.caption, color = tint)
            if (snapshot.slowNetwork && snapshot.status.isNotBlank()) Text(snapshot.status, style = Design.caption, color = colors.onSurfaceVariant)
        }
        if (targetControl != null) targetControl() else Text(stringResource(R.string.target_format, language), style = Design.caption, color = colors.onSurfaceVariant)
    }
}

@Composable
internal fun SubtitleText(row: SubtitleRow, stamp: String? = null) {
    val colors = MaterialTheme.colorScheme
    val draft = row.source.isNotEmpty() && !row.sourceDone || row.translation.isNotEmpty() && !row.translationDone
    Column(Modifier.fillMaxWidth().padding(horizontal = Design.spaceLg, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(Design.spaceXs)) {
        val speaker = when (row.speaker) {
            "A", "B" -> stringResource(R.string.dialogue_speaker, row.speaker.orEmpty())
            "unknown" -> stringResource(R.string.dialogue_unknown)
            else -> null
        }
        val caption = listOfNotNull(stamp, speaker, stringResource(R.string.transcribing).takeIf { draft }).joinToString("  ·  ")
        if (caption.isNotEmpty()) Text(caption, style = Design.caption, color = if (draft) colors.primary else colors.onSurfaceVariant)
        if (row.translation.isNotEmpty()) Text(row.translation, style = Design.translation,
            color = colors.onSurface.copy(alpha = if (row.translationDone) 1f else Design.draftOpacity))
        if (row.source.isNotEmpty()) Text(row.source, style = Design.source,
            color = colors.onSurfaceVariant.copy(alpha = if (row.sourceDone) 1f else Design.draftOpacity))
    }
}

@Composable
internal fun SpeechToggle(checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit, stopPlayback: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.weight(1f).heightIn(min = 48.dp).toggleable(checked, enabled, Role.Switch, onChange),
            verticalAlignment = Alignment.CenterVertically) {
            Glyph(R.drawable.ic_volume_up)
            Text(stringResource(R.string.translated_audio), Modifier.weight(1f).padding(horizontal = Design.spaceSm))
            Switch(checked, onCheckedChange = null, enabled = enabled)
        }
        if (stopPlayback != null) Tool(R.drawable.ic_stop, stringResource(R.string.stop_audio), click = stopPlayback)
    }
}

@Composable
internal fun GroupTitle(label: String) {
    Text(label, Modifier.padding(top = Design.spaceMd), style = Design.caption, color = MaterialTheme.colorScheme.primary)
}

@Composable
internal fun Welcome(settings: () -> Unit, later: () -> Unit) {
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(Design.spaceLg),
            verticalArrangement = Arrangement.spacedBy(Design.spaceLg, Alignment.CenterVertically)) {
            Icon(painterResource(R.drawable.ic_launcher_foreground), null, Modifier.size(84.dp)
                .background(MaterialTheme.colorScheme.primary, CircleShape), tint = Color.Unspecified)
            Text(stringResource(R.string.start_live), style = Design.title)
            Text(stringResource(R.string.welcome_description), style = Design.source)
            ListItem(headlineContent = { Text(stringResource(R.string.permission_mic)) }, supportingContent = { Text(stringResource(R.string.welcome_audio)) }, leadingContent = { Glyph(R.drawable.ic_mic) })
            ListItem(headlineContent = { Text(stringResource(R.string.permission_notifications)) }, supportingContent = { Text(stringResource(R.string.welcome_notification)) }, leadingContent = { Glyph(R.drawable.ic_graphic_eq) })
            Button(settings, Modifier.fillMaxWidth()) { Glyph(R.drawable.ic_key); Spacer(Modifier.width(Design.spaceSm)); Text(stringResource(R.string.setup_service)) }
            TextButton(later, Modifier.align(Alignment.CenterHorizontally)) { Text(stringResource(R.string.later)) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun Segments(title: String, choices: List<String>, selected: Int, onSelect: (Int) -> Unit) {
    Text(title, style = Design.caption)
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        choices.forEachIndexed { i, choice ->
            SegmentedButton(selected = i == selected, onClick = { onSelect(i) },
                shape = SegmentedButtonDefaults.itemShape(i, choices.size)) { Text(choice) }
        }
    }
}
