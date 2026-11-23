@file:OptIn(ExperimentalMaterial3Api::class)

package com.localrecorder.shengjian

import android.content.res.Configuration
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
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
                        Page.Welcome -> Welcome({ page = Page.Settings }, { page = Page.Transcript })
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
            Tool(R.drawable.ic_settings, "设置", click = settings)
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
        SessionHeader("河岸散步", if (wide) null else ({ navigate(Page.History) })) {
            Box {
                Tool(R.drawable.ic_more_vert, "更多操作") { more = true }
                DropdownMenu(more, { more = false }) {
                    DropdownMenuItem(text = { Text("导出会话") }, onClick = { more = false; navigate(Page.Export) })
                    DropdownMenuItem(text = { Text("设置") }, onClick = { more = false; navigate(Page.Settings) })
                }
            }
        }
        SessionStatus(com.localrecorder.live.SessionSnapshot(state = if (recording) com.localrecorder.live.SessionState.RECORDING else com.localrecorder.live.SessionState.IDLE),
            "中文", true)
        HorizontalDivider()
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState(), reverseScrolling = true),
            verticalArrangement = Arrangement.Bottom) {
            samples.forEachIndexed { i, (translation, source) ->
                val done = i != samples.lastIndex || !recording
                SubtitleText(com.localrecorder.live.SubtitleRow(i.toString(), source, done, translation, done), if (i < 2) "09:40" else if (i < 4) "09:41" else "09:42")
            }
        }
        Surface(color = colors.surfaceContainerLow) {
            Column(Modifier.fillMaxWidth().padding(horizontal = Design.spaceMd, vertical = Design.spaceSm)) {
                SpeechToggle(speech, !recording, { speech = it })
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
    var config by remember { mutableStateOf(LiveTranslateConfig(endpoint = "wss://example.org/realtime")) }
    var key by remember { mutableStateOf("") }
    var options by remember { mutableStateOf(AppOptions()) }
    SettingsLayout(back, service = {
        ServiceFields(config.endpoint, key, true, false, false, { config = config.copy(endpoint = it) }, { key = it }, {})
    }) {
        PreferenceGroups(config, options, true, { config = it(config) }, { options = it(options) }, true, {})
    }
}

@Composable
private fun Export(close: () -> Unit) {
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.scrim.copy(alpha = .32f)), contentAlignment = Alignment.BottomCenter) {
        Surface(shape = BottomSheetDefaults.ExpandedShape, color = MaterialTheme.colorScheme.surfaceContainerLow) {
            var format by remember { mutableStateOf(com.localrecorder.sessions.ExportFormat.TXT) }
            var content by remember { mutableStateOf(com.localrecorder.sessions.ExportContent.BILINGUAL) }
            Column {
                BottomSheetDefaults.DragHandle(Modifier.align(Alignment.CenterHorizontally))
                ExportChoices("河岸散步", format, content, { format = it }, { content = it }, close, close, close)
            }
        }
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
