@file:OptIn(ExperimentalMaterial3Api::class)

package com.localrecorder.shengjian

import android.content.res.Configuration
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.android.tools.screenshot.PreviewTest
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.shengjian.ui.theme.Design
import com.localrecorder.shengjian.ui.theme.LocalStatusColors
import com.localrecorder.shengjian.ui.theme.ShengjianTheme

// Review fixtures only. No controller, credentials, microphone, wall clock or network.
private enum class Page { Transcript, History, Settings, Export, Welcome }

private val samples = listOf(
    "这附近有什么安静的地方？" to "Is there somewhere quiet near here?",
    "早晨的河边很安静，适合散步。" to "The waterfront is quiet in the morning. It’s a good place for a walk.",
    "我们沿着河岸走一会儿吧。" to "Let's walk along the river for a while.",
    "从旧桥出发，经过那座图书馆。" to "Start at the old bridge and pass the library.",
    "可以在那里停下来听听水声。" to "We could stop there and listen to the water.",
)

@Composable
private fun Glyph(@DrawableRes id: Int, label: String? = null) {
    Icon(painterResource(id), contentDescription = label)
}

@Composable
private fun Tool(@DrawableRes id: Int, label: String, click: () -> Unit) {
    IconButton(onClick = click, modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)) { Glyph(id, label) }
}

@Composable
private fun Review(initial: Page = Page.Transcript) {
    var page by remember { mutableStateOf(initial) }
    var recording by remember { mutableStateOf(true) }
    ShengjianTheme {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
            BoxWithConstraints {
                val wide = maxWidth >= Design.wide
                Row(Modifier.fillMaxSize()) {
                    if (wide && page in listOf(Page.Transcript, Page.Export)) {
                        History(Modifier.width(256.dp).fillMaxHeight(), { page = Page.Transcript }, { page = Page.Settings })
                        VerticalDivider()
                    }
                    when (page) {
                        Page.Welcome -> Welcome { page = Page.Settings }
                        Page.Settings -> Settings { page = Page.Transcript }
                        Page.History -> History(Modifier.fillMaxSize(), { page = Page.Transcript }, { page = Page.Settings })
                        Page.Transcript, Page.Export -> Box(Modifier.fillMaxSize()) {
                            Transcript(wide, recording, { recording = !recording }, { page = it })
                            if (page == Page.Export) Export { page = Page.Transcript }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun History(modifier: Modifier, select: () -> Unit, settings: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Column(modifier.background(colors.surfaceContainerLow)) {
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = Design.spaceXs), verticalAlignment = Alignment.CenterVertically) {
            Text("会话记录", Modifier.weight(1f), style = Design.title)
            Tool(R.drawable.ic_settings, "设置", settings)
        }
        FilledTonalButton(onClick = select, modifier = Modifier.padding(horizontal = Design.spaceMd, vertical = Design.spaceSm)) {
            Glyph(R.drawable.ic_add)
            Spacer(Modifier.width(Design.spaceSm))
            Text("新建会话")
        }
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = Design.spaceSm)) {
            for ((group, titles) in listOf("今天" to listOf("河岸散步", "访谈提纲"), "昨天" to listOf("周末读书会"))) {
                Text(group, Modifier.padding(horizontal = Design.spaceMd, vertical = Design.spaceSm), style = Design.caption, color = colors.onSurfaceVariant)
                for (title in titles) {
                    val active = title == "河岸散步"
                    Column(Modifier.fillMaxWidth().clip(MaterialTheme.shapes.medium)
                        .background(if (active) colors.secondaryContainer else colors.surfaceContainerLow)
                        .clickable(onClick = select).padding(horizontal = Design.spaceMd, vertical = 12.dp)) {
                        Text(title, style = Design.source)
                        Text(if (active) "09:41 · 录制中" else if (title == "访谈提纲") "08:15" else "14:20",
                            style = Design.caption, color = if (active) LocalStatusColors.current.recording else colors.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
private fun Transcript(wide: Boolean, recording: Boolean, toggle: () -> Unit, navigate: (Page) -> Unit) {
    val colors = MaterialTheme.colorScheme
    var more by remember { mutableStateOf(false) }
    var speech by remember { mutableStateOf(true) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = Design.spaceSm), verticalAlignment = Alignment.CenterVertically) {
            if (!wide) Tool(R.drawable.ic_menu, "会话记录") { navigate(Page.History) }
            Text("河岸散步", Modifier.weight(1f).padding(horizontal = Design.spaceSm), style = Design.title)
            Box {
                Tool(R.drawable.ic_more_vert, "更多操作") { more = true }
                DropdownMenu(expanded = more, onDismissRequest = { more = false }) {
                    for ((text, page) in listOf("导出会话" to Page.Export, "设置" to Page.Settings)) {
                        DropdownMenuItem(text = { Text(text) }, onClick = { more = false; navigate(page) })
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(start = Design.spaceLg, end = Design.spaceMd, bottom = Design.spaceSm),
            horizontalArrangement = Arrangement.spacedBy(Design.spaceSm), verticalAlignment = Alignment.CenterVertically) {
            val status = if (recording) LocalStatusColors.current.recording else LocalStatusColors.current.complete
            Icon(painterResource(if (recording) R.drawable.ic_graphic_eq else R.drawable.ic_check_circle), null, tint = status)
            Text(if (recording) "录制中" else "已完成", style = Design.caption, color = status)
            Text("英语 → 简体中文", style = Design.caption, color = colors.onSurfaceVariant)
        }
        HorizontalDivider()
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState(), reverseScrolling = true)
            .padding(horizontal = Design.spaceLg, vertical = Design.spaceMd),
            verticalArrangement = Arrangement.spacedBy(Design.spaceLg, Alignment.Bottom)) {
            samples.forEachIndexed { i, (translation, source) ->
                val draft = i == samples.lastIndex && recording
                Column(verticalArrangement = Arrangement.spacedBy(Design.spaceXs)) {
                    Text(if (draft) "09:42  ·  识别中…" else if (i < 2) "09:40" else "09:41",
                        style = Design.caption, color = if (draft) colors.primary else colors.onSurfaceVariant)
                    Text(translation, style = Design.translation, color = colors.onSurface.copy(alpha = if (draft) Design.draftOpacity else 1f))
                    Text(source, style = Design.source, color = colors.onSurfaceVariant)
                }
            }
        }
        Surface(color = colors.surfaceContainerLow) {
            Column(Modifier.fillMaxWidth().padding(horizontal = Design.spaceMd, vertical = Design.spaceSm)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Glyph(R.drawable.ic_volume_up)
                    Text("译音", Modifier.weight(1f).padding(start = Design.spaceSm))
                    Switch(checked = speech, onCheckedChange = { speech = it }, modifier = Modifier.semantics { contentDescription = "播放译音" })
                }
                Button(onClick = toggle, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp), shape = MaterialTheme.shapes.medium) {
                    Glyph(if (recording) R.drawable.ic_stop else R.drawable.ic_mic)
                    Spacer(Modifier.width(Design.spaceSm))
                    Text(if (recording) "停止实时翻译" else "开始实时翻译")
                }
            }
        }
    }
}

@Composable
private fun Settings(back: () -> Unit) {
    var address by remember { mutableStateOf("wss://example.org/realtime") }
    var key by remember { mutableStateOf("preview-key") }
    var visible by remember { mutableStateOf(false) }
    var languages by remember { mutableStateOf(false) }
    var target by remember { mutableStateOf("简体中文") }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Tool(R.drawable.ic_arrow_back, "返回", back)
            Text("设置", style = Design.title)
        }
        Column(Modifier.padding(horizontal = Design.spaceLg), verticalArrangement = Arrangement.spacedBy(Design.spaceSm)) {
            GroupTitle("服务")
            OutlinedTextField(value = address, onValueChange = { address = it }, singleLine = true, label = { Text("服务地址") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(value = key, onValueChange = { key = it }, singleLine = true, label = { Text("API Key") },
                visualTransformation = if (visible) androidx.compose.ui.text.input.VisualTransformation.None else androidx.compose.ui.text.input.PasswordVisualTransformation(),
                trailingIcon = { TextButton({ visible = !visible }) { Text(if (visible) "隐藏" else "显示") } }, modifier = Modifier.fillMaxWidth())
            OutlinedButton(onClick = {}) { Glyph(R.drawable.ic_check_circle); Spacer(Modifier.width(Design.spaceSm)); Text("连接成功 · 重新测试") }
            GroupTitle("翻译")
            Box {
                OutlinedButton({ languages = true }, Modifier.fillMaxWidth()) { Text("目标语言 · $target ▾") }
                DropdownMenu(languages, { languages = false }) {
                    for ((_, name) in LiveTranslateConfig.LANGUAGES) {
                        DropdownMenuItem(text = { Text(name) }, onClick = { target = name; languages = false })
                    }
                }
            }
            GroupTitle("译音")
            ListItem(headlineContent = { Text("播放译音") }, trailingContent = { Switch(true, {}) })
            GroupTitle("网络")
            ListItem(headlineContent = { Text("断线自动重连") }, trailingContent = { Switch(true, {}) })
            GroupTitle("会话记录")
            ListItem(headlineContent = { Text("保存会话记录") }, trailingContent = { Switch(true, {}) })
            GroupTitle("关于")
            Text("声笺", Modifier.padding(bottom = Design.spaceLg))
        }
    }
}

@Composable
private fun GroupTitle(label: String) {
    Text(label, Modifier.padding(top = Design.spaceMd), style = Design.caption, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun Export(close: () -> Unit) {
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.scrim.copy(alpha = .32f)), contentAlignment = Alignment.BottomCenter) {
        Surface(shape = BottomSheetDefaults.ExpandedShape, color = MaterialTheme.colorScheme.surfaceContainerLow) {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = Design.spaceLg, vertical = Design.spaceSm),
                verticalArrangement = Arrangement.spacedBy(Design.spaceSm)) {
                BottomSheetDefaults.DragHandle(Modifier.align(Alignment.CenterHorizontally))
                Text("导出会话", style = Design.title)
                Text("河岸散步 · 只包含已定稿的文字", style = Design.source)
                Segments("格式", listOf("TXT", "Markdown"))
                Segments("内容", listOf("双语", "仅原文", "仅译文"))
                Button(close, Modifier.fillMaxWidth()) { Glyph(R.drawable.ic_upload_file); Spacer(Modifier.width(Design.spaceSm)); Text("保存到文件") }
                Row { TextButton(close) { Text("分享") }; TextButton(close) { Text("复制") } }
            }
        }
    }
}

@Composable
private fun Segments(title: String, choices: List<String>) {
    var selected by remember { mutableIntStateOf(0) }
    Text(title, style = Design.caption)
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        choices.forEachIndexed { i, choice ->
            SegmentedButton(selected = i == selected, onClick = { selected = i },
                shape = SegmentedButtonDefaults.itemShape(i, choices.size)) { Text(choice) }
        }
    }
}

@Composable
private fun Welcome(settings: () -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Design.spaceLg),
        verticalArrangement = Arrangement.spacedBy(Design.spaceLg, Alignment.CenterVertically)) {
        Icon(painterResource(R.drawable.ic_launcher_foreground), null, Modifier.size(84.dp).background(MaterialTheme.colorScheme.primary, CircleShape),
            tint = androidx.compose.ui.graphics.Color.Unspecified)
        Text("开始实时翻译", style = Design.title)
        Text("先填写服务地址与 API Key，再开始第一段会话。", style = Design.source)
        ListItem(headlineContent = { Text("麦克风") }, supportingContent = { Text("开始翻译时，语音会发送到你设置的服务。") }, leadingContent = { Glyph(R.drawable.ic_mic) })
        ListItem(headlineContent = { Text("通知") }, supportingContent = { Text("后台录制时显示当前状态和停止操作。") }, leadingContent = { Glyph(R.drawable.ic_graphic_eq) })
        Button(settings, Modifier.fillMaxWidth()) { Glyph(R.drawable.ic_key); Spacer(Modifier.width(Design.spaceSm)); Text("配置服务") }
    }
}

@PreviewTest @Preview(name = "PhoneLight", widthDp = 393, heightDp = 780, locale = "zh-rCN")
@Composable fun PhoneLight() = Review()

@PreviewTest @Preview(name = "PhoneDark", widthDp = 393, heightDp = 780, locale = "zh-rCN", uiMode = Configuration.UI_MODE_NIGHT_YES)
@Composable fun PhoneDark() = Review()

@PreviewTest @Preview(name = "TabletLight", widthDp = 960, heightDp = 660, locale = "zh-rCN")
@Composable fun TabletLight() = Review()

@PreviewTest @Preview(name = "TabletDark", widthDp = 960, heightDp = 660, locale = "zh-rCN", uiMode = Configuration.UI_MODE_NIGHT_YES)
@Composable fun TabletDark() = Review()

@PreviewTest @Preview(name = "History", widthDp = 393, heightDp = 780, locale = "zh-rCN")
@Composable fun HistoryPreview() = Review(Page.History)

@PreviewTest @Preview(name = "Settings", widthDp = 393, heightDp = 780, locale = "zh-rCN")
@Composable fun SettingsPreview() = Review(Page.Settings)

@PreviewTest @Preview(name = "Export", widthDp = 393, heightDp = 780, locale = "zh-rCN")
@Composable fun ExportPreview() = Review(Page.Export)

@PreviewTest @Preview(name = "Welcome", widthDp = 393, heightDp = 780, locale = "zh-rCN")
@Composable fun WelcomePreview() = Review(Page.Welcome)

@PreviewTest @Preview(name = "PhoneLargeType", widthDp = 393, heightDp = 780, fontScale = 2f, locale = "zh-rCN")
@Composable fun LargeTypePreview() = Review()
