package com.localrecorder.shengjian

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.Saver
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
    OutlinedButton(onClick = { open = true }, enabled = !testing) { Text("服务配置 · " + profile.name) }
    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
        saved.catalog.profiles.forEach { item ->
            DropdownMenuItem(text = { Text(item.name + " · " + item.modelID) }, onClick = { open = false; onSelect(item) })
        }
        DropdownMenuItem(text = { Text("新建配置") }, onClick = {
            open = false
            onEdit(LiveServiceProfile(id = UUID.randomUUID().toString(), name = "新配置"))
        })
    }
    ProfileField("配置名称", profile.name) { onEdit(profile.copy(name = it)) }
    Text("协议 · " + profile.protocolID + " · " + profile.version)
    ProfileField("服务地址", profile.endpoint) { onEdit(profile.copy(endpoint = it)) }
    ProfileField("模型 ID", profile.modelID) { onEdit(profile.copy(modelID = it)) }
    var advanced by remember { mutableStateOf(false) }
    TextButton(onClick = { advanced = !advanced }) { Text("断句和上行音频") }
    if (advanced) {
        val vad = profile.turnDetection == "server_vad"
        OutlinedButton(onClick = { onEdit(profile.copy(turnDetection = if (vad) "speaker_detection" else "server_vad")) }) {
            Text("断句方式 · " + if (vad) "静音检测" else "说话人检测")
        }
        if (vad) {
            Text("静音阈值 · " + "%.2f".format(profile.threshold))
            Slider(value = profile.threshold.toFloat(), onValueChange = { onEdit(profile.copy(threshold = it.toDouble())) })
            Text("静音时长 · " + profile.silenceMS + " 毫秒")
            Slider(value = profile.silenceMS.toFloat(), valueRange = 100f..3000f, steps = 28,
                onValueChange = { onEdit(profile.copy(silenceMS = kotlin.math.round(it / 100).toInt() * 100)) })
        }
        Text("上行音频 · PCM16 · 16 kHz · 单声道")
        val context = LocalContext.current
        TextButton(onClick = {
            context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("LiveTranslate 配置", saved.toJson()))
        }) { Text("复制已保存的探针配置") }
    }
}

@Composable
private fun ProfileField(label: String, value: String, update: (String) -> Unit) {
    OutlinedTextField(value, update, modifier = Modifier.fillMaxWidth(), label = { Text(label) }, singleLine = true)
}

@Composable
internal fun ProfileSwitchButtons(config: LiveTranslateConfig, onSwitch: (LiveServiceProfile) -> Unit) {
    config.catalog.profiles.filter { it.id != config.profile.id }.forEach { other ->
        TextButton(onClick = { onSwitch(other) }) { Text("切换到「" + other.name + "」") }
    }
}
