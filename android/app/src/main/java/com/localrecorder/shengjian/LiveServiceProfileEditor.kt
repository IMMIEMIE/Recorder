package com.localrecorder.shengjian

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.Saver
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.localrecorder.live.LiveServiceProfile
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.shengjian.ui.theme.Design
import org.json.JSONObject
import java.util.UUID

internal val profileSaver = Saver<LiveServiceProfile, String>(
    save = { it.json().toString() },
    restore = { LiveServiceProfile.parse(JSONObject(it)) },
)

@Composable
internal fun LiveServiceProfileEditor(
    profile: LiveServiceProfile,
    saved: LiveTranslateConfig,
    testing: Boolean,
    onEdit: (LiveServiceProfile) -> Unit,
    onSelect: (LiveServiceProfile) -> Unit,
    recording: Boolean = false,
) {
    val colors = MaterialTheme.colorScheme
    val newName = stringResource(R.string.new_profile_name)
    val canSwitch = !testing && !recording

    // Horizontal profile selector chips replace the narrow dropdown menu.
    Row(
        Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        saved.catalog.profiles.forEach { item ->
            val selected = item.id == profile.id
            Surface(
                onClick = { onSelect(item) },
                enabled = canSwitch,
                shape = CircleShape,
                color = if (selected) colors.primary else colors.surfaceContainerLowest,
                border = BorderStroke(1.dp, if (selected) colors.primary else colors.outlineVariant),
                modifier = Modifier.heightIn(min = 38.dp),
            ) {
                Row(
                    Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        item.name,
                        style = Design.caption.copy(fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium),
                        color = if (selected) colors.onPrimary else colors.onSurface,
                    )
                }
            }
        }
        Surface(
            onClick = { onEdit(LiveServiceProfile(id = UUID.randomUUID().toString(), name = newName)) },
            enabled = canSwitch,
            shape = CircleShape,
            color = colors.surfaceContainer,
            modifier = Modifier.heightIn(min = 38.dp),
        ) {
            Row(
                Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Glyph(R.drawable.ic_add, Modifier.size(15.dp), tint = colors.primary)
                Text(stringResource(R.string.profile_new_short), style = Design.caption, color = colors.primary)
            }
        }
    }

    ProfileField(stringResource(R.string.profile_name), profile.name, !testing) { onEdit(profile.copy(name = it)) }
    val protocols = listOf(
        LiveServiceProfile.QWEN_PROTOCOL_ID to "Qwen LiveTranslate 3.8",
        LiveServiceProfile.GEMINI_PROTOCOL_ID to "Gemini Live 1.0",
    )
    Row(
        Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        protocols.forEach { (protocolID, label) ->
            val selected = profile.protocolID == protocolID
            Surface(
                onClick = { if (!selected) onEdit(profile.switchingProtocol(protocolID)) },
                enabled = canSwitch,
                shape = CircleShape,
                color = if (selected) colors.secondaryContainer else colors.surfaceContainerLowest,
                border = BorderStroke(1.dp, if (selected) colors.primary else colors.outlineVariant),
                modifier = Modifier.heightIn(min = 36.dp),
            ) {
                Text(
                    label,
                    style = Design.caption.copy(fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium),
                    color = if (selected) colors.onSecondaryContainer else colors.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
                )
            }
        }
    }
    if (protocols.none { it.first == profile.protocolID }) {
        Surface(
            color = colors.surfaceContainer,
            shape = RoundedCornerShape(Design.radiusInput),
        ) {
            Text(
                stringResource(R.string.protocol_detail, profile.protocolID, profile.version),
                style = Design.caption,
                color = colors.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            )
        }
    }
    ProfileField(stringResource(R.string.endpoint), profile.endpoint, !testing && !recording) { onEdit(profile.copy(endpoint = it)) }
    ProfileField(stringResource(R.string.model_id), profile.modelID, !testing) { onEdit(profile.copy(modelID = it)) }

    var advanced by remember { mutableStateOf(false) }
    val chevronRotation by animateFloatAsState(
        targetValue = if (advanced) 180f else 0f,
        animationSpec = tween(200),
        label = "advancedChevron",
    )
    HorizontalDivider(color = colors.outlineVariant.copy(alpha = 0.7f))
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Design.radiusInput))
            .clickable { advanced = !advanced }
            .heightIn(min = 44.dp)
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            stringResource(R.string.profile_advanced),
            style = Design.caption.copy(fontWeight = FontWeight.Medium),
            color = colors.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        Glyph(
            R.drawable.ic_expand_more,
            Modifier.size(18.dp).graphicsLayer { rotationZ = chevronRotation },
            tint = colors.onSurfaceVariant,
        )
    }

    AnimatedVisibility(
        visible = advanced,
        enter = expandVertically(tween(220)) + fadeIn(tween(180)),
        exit = shrinkVertically(tween(180)) + fadeOut(tween(140)),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (!profile.isGeminiLive) {
                val vad = profile.turnDetection == "server_vad"
                OutlinedButton(
                    onClick = { onEdit(profile.copy(turnDetection = if (vad) "speaker_detection" else "server_vad")) },
                    enabled = !testing,
                    shape = RoundedCornerShape(Design.radiusButton),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.detection_mode, stringResource(if (vad) R.string.quiet_detection else R.string.speaker_detection)))
                }
                if (vad) {
                    Column {
                        Text(stringResource(R.string.quiet_threshold, profile.threshold), style = Design.caption, color = colors.onSurfaceVariant)
                        Slider(
                            value = profile.threshold.toFloat(),
                            enabled = !testing,
                            onValueChange = { onEdit(profile.copy(threshold = it.toDouble())) },
                        )
                    }
                    Column {
                        Text(stringResource(R.string.quiet_duration, profile.silenceMS), style = Design.caption, color = colors.onSurfaceVariant)
                        Slider(
                            value = profile.silenceMS.toFloat(),
                            enabled = !testing,
                            valueRange = 100f..3000f,
                            steps = 28,
                            onValueChange = { onEdit(profile.copy(silenceMS = kotlin.math.round(it / 100).toInt() * 100)) },
                        )
                    }
                }
            }
            Text(stringResource(R.string.pcm_input), style = Design.caption, color = colors.onSurfaceVariant)
            val context = LocalContext.current
            TextButton(onClick = {
                context.getSystemService(ClipboardManager::class.java)
                    ?.setPrimaryClip(ClipData.newPlainText(context.getString(R.string.profile_clipboard), saved.toJson()))
            }) {
                Glyph(R.drawable.ic_content_copy, Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.copy_probe_profile))
            }
        }
    }
}

@Composable
private fun ProfileField(label: String, value: String, enabled: Boolean, update: (String) -> Unit) {
    val keyboard = LocalSoftwareKeyboardController.current
    val colors = MaterialTheme.colorScheme
    OutlinedTextField(
        value = value,
        onValueChange = update,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth(),
        label = { Text(label) },
        singleLine = true,
        shape = RoundedCornerShape(Design.radiusButton),
        colors = OutlinedTextFieldDefaults.colors(
            unfocusedContainerColor = colors.surfaceContainerLowest,
            focusedContainerColor = colors.surfaceContainerLowest,
            unfocusedBorderColor = colors.outlineVariant,
        ),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { keyboard?.hide() }),
    )
}

@Composable
internal fun ProfileSwitchButtons(config: LiveTranslateConfig, onSwitch: (LiveServiceProfile) -> Unit) {
    val others = config.catalog.profiles.filter { it.id != config.profile.id }
    if (others.isEmpty()) return
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        others.forEach { other ->
            Surface(
                onClick = { onSwitch(other) },
                shape = CircleShape,
                color = MaterialTheme.colorScheme.surfaceContainerLowest,
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
            ) {
                Text(
                    stringResource(R.string.profile_switch, other.name),
                    style = Design.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
        }
    }
}
