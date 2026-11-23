package com.localrecorder.shengjian

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.Saver
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.LiveServiceProfile
import org.json.JSONObject
import java.util.UUID

internal val profileSaver = Saver<LiveServiceProfile, String>(
    save = { it.json().toString() }, restore = { LiveServiceProfile.parse(JSONObject(it)) },
)

@Composable
internal fun LiveServiceProfileEditor(profile: LiveServiceProfile, saved: LiveTranslateConfig, testing: Boolean,
                                     onEdit: (LiveServiceProfile) -> Unit, onSelect: (LiveServiceProfile) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val newName = stringResource(R.string.new_profile_name)
    OutlinedButton(onClick = { open = true }, enabled = !testing) { Text(stringResource(R.string.profile_title, profile.name)) }
    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
        saved.catalog.profiles.forEach { item ->
            DropdownMenuItem(text = { Text(item.name + " · " + item.modelID) }, onClick = { open = false; onSelect(item) })
        }
        DropdownMenuItem(text = { Text(stringResource(R.string.new_profile)) }, onClick = {
            open = false
            onEdit(LiveServiceProfile(id = UUID.randomUUID().toString(), name = newName))
        })
    }
    ProfileField(stringResource(R.string.profile_name), profile.name, !testing) { onEdit(profile.copy(name = it)) }
    Text(stringResource(R.string.protocol_detail, profile.protocolID, profile.version))
    ProfileField(stringResource(R.string.endpoint), profile.endpoint, !testing) { onEdit(profile.copy(endpoint = it)) }
    ProfileField(stringResource(R.string.model_id), profile.modelID, !testing) { onEdit(profile.copy(modelID = it)) }
    var advanced by remember { mutableStateOf(false) }
    TextButton(onClick = { advanced = !advanced }) { Text(stringResource(R.string.profile_advanced)) }
    if (advanced) {
        val vad = profile.turnDetection == "server_vad"
        OutlinedButton(onClick = { onEdit(profile.copy(turnDetection = if (vad) "speaker_detection" else "server_vad")) }, enabled = !testing) {
            Text(stringResource(R.string.detection_mode, stringResource(if (vad) R.string.quiet_detection else R.string.speaker_detection)))
        }
        if (vad) {
            Text(stringResource(R.string.quiet_threshold, profile.threshold))
            Slider(value = profile.threshold.toFloat(), enabled = !testing, onValueChange = { onEdit(profile.copy(threshold = it.toDouble())) })
            Text(stringResource(R.string.quiet_duration, profile.silenceMS))
            Slider(value = profile.silenceMS.toFloat(), enabled = !testing, valueRange = 100f..3000f, steps = 28,
                onValueChange = { onEdit(profile.copy(silenceMS = kotlin.math.round(it / 100).toInt() * 100)) })
        }
        Text(stringResource(R.string.pcm_input))
        val context = LocalContext.current
        TextButton(onClick = {
            context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText(context.getString(R.string.profile_clipboard), saved.toJson()))
        }) { Text(stringResource(R.string.copy_probe_profile)) }
    }
}

@Composable
private fun ProfileField(label: String, value: String, enabled: Boolean, update: (String) -> Unit) {
    val keyboard = LocalSoftwareKeyboardController.current
    OutlinedTextField(value, update, enabled = enabled, modifier = Modifier.fillMaxWidth(),
        label = { Text(label) }, singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { keyboard?.hide() }))
}

@Composable
internal fun ProfileSwitchButtons(config: LiveTranslateConfig, onSwitch: (LiveServiceProfile) -> Unit) {
    config.catalog.profiles.filter { it.id != config.profile.id }.forEach { other ->
        TextButton(onClick = { onSwitch(other) }) { Text(stringResource(R.string.profile_switch, other.name)) }
    }
}
