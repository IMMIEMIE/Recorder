@file:OptIn(ExperimentalMaterial3Api::class)

package com.localrecorder.shengjian

import android.content.res.Configuration
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListPrefetchStrategy
import androidx.compose.foundation.lazy.layout.PrefetchRequest
import androidx.compose.foundation.lazy.layout.PrefetchScheduler
import androidx.compose.foundation.lazy.rememberLazyListState
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.android.tools.screenshot.PreviewTest
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.SessionSnapshot
import com.localrecorder.live.SessionState
import com.localrecorder.live.SubtitleRow
import com.localrecorder.sessions.ExportContent
import com.localrecorder.sessions.ExportFormat
import com.localrecorder.shengjian.ui.theme.Design
import com.localrecorder.shengjian.ui.theme.LocalStatusColors
import com.localrecorder.shengjian.ui.theme.ShengjianTheme

// Review fixtures only. No controller, credentials, microphone, wall clock or network.
private enum class Page { Transcript, History, Settings, Export, Welcome, Dialogue }

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
                        History(Modifier.width(280.dp).fillMaxHeight(), { page = Page.Transcript }, { page = Page.Settings })
                        VerticalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    }
                    when (page) {
                        Page.Dialogue -> DialogueReview { page = Page.Transcript }
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
    val barColor = colors.primary
    Column(modifier.background(colors.surfaceContainerLow)) {
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = Design.spaceSm, top = Design.spaceSm, bottom = Design.spaceXs),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.session_history), style = Design.title)
                Surface(color = colors.surfaceContainer, shape = CircleShape) {
                    Text(stringResource(R.string.session_count, 3), style = Design.caption, color = colors.onSurfaceVariant, modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp))
                }
            }
            Tool(R.drawable.ic_settings, stringResource(R.string.settings), click = settings)
        }
        FilledTonalButton(
            onClick = select,
            shape = RoundedCornerShape(Design.radiusCard),
            colors = ButtonDefaults.filledTonalButtonColors(
                containerColor = colors.primaryContainer,
                contentColor = colors.onPrimaryContainer,
            ),
            modifier = Modifier.fillMaxWidth().padding(horizontal = Design.spaceMd, vertical = Design.spaceSm).heightIn(min = 48.dp),
        ) {
            Glyph(R.drawable.ic_add, Modifier.size(18.dp))
            Spacer(Modifier.width(Design.spaceSm))
            Text(stringResource(R.string.new_session), fontWeight = FontWeight.SemiBold)
        }
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 12.dp)) {
            for ((group, titles) in listOf(stringResource(R.string.today) to listOf("河岸散步", "访谈提纲"), stringResource(R.string.yesterday) to listOf("周末读书会"))) {
                Text(group, Modifier.padding(horizontal = 12.dp, vertical = Design.spaceSm), style = Design.caption, color = colors.onSurfaceVariant)
                for (title in titles) {
                    val active = title == "河岸散步"
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .padding(vertical = 2.dp)
                            .clip(RoundedCornerShape(Design.radiusCard))
                            .background(if (active) colors.secondaryContainer else colors.surfaceContainerLow)
                            .drawBehind {
                                if (active) {
                                    val bw = 3.dp.toPx()
                                    val inset = 10.dp.toPx()
                                    drawRoundRect(barColor, Offset(4.dp.toPx(), inset), Size(bw, size.height - inset * 2), CornerRadius(bw, bw))
                                }
                            }
                            .clickable(onClick = select)
                            .padding(start = 16.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text(title, style = Design.source.copy(fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal))
                                if (active) {
                                    val rec = LocalStatusColors.current.recording
                                    Surface(color = rec.copy(alpha = 0.13f), shape = CircleShape) {
                                        Text(stringResource(R.string.recording), style = MaterialTheme.typography.labelSmall, color = rec, modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp))
                                    }
                                }
                            }
                            Text(if (active) "09:41" else if (title == "访谈提纲") "08:15" else "14:20", style = Design.caption, color = colors.onSurfaceVariant)
                        }
                        Tool(R.drawable.ic_more_vert, stringResource(R.string.session_actions), tint = colors.onSurfaceVariant, click = select)
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
    Column(Modifier.fillMaxSize().background(colors.surface)) {
        SessionHeader(
            title = "河岸散步",
            openList = if (wide) null else ({ navigate(Page.History) }),
            statusContent = {
                StatusPill(
                    SessionSnapshot(state = if (recording) SessionState.RECORDING else SessionState.IDLE),
                    hasSession = true,
                )
            },
        ) {
            FilledTonalButton(
                onClick = { navigate(Page.Dialogue) },
                shape = CircleShape,
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                modifier = Modifier.heightIn(min = 40.dp),
            ) {
                Glyph(R.drawable.ic_dialogue, Modifier.size(16.dp))
                Spacer(Modifier.width(5.dp))
                Text(stringResource(R.string.dialogue_chip), style = Design.caption.copy(fontWeight = FontWeight.SemiBold))
            }
            Box {
                Tool(R.drawable.ic_more_vert, stringResource(R.string.more_actions), tint = colors.onSurfaceVariant) { more = true }
                DropdownMenu(more, { more = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.export_session)) }, onClick = { more = false; navigate(Page.Export) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.settings)) }, onClick = { more = false; navigate(Page.Settings) })
                }
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState(), reverseScrolling = true).padding(top = 18.dp, bottom = 8.dp),
                verticalArrangement = Arrangement.Bottom,
            ) {
                samples.forEachIndexed { i, (translation, source) ->
                    val done = i != samples.lastIndex || !recording
                    SubtitleText(
                        SubtitleRow(i.toString(), source, done, translation, done),
                        if (i < 2) "09:40" else if (i < 4) "09:41" else "09:42",
                    )
                }
            }
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(24.dp)
                    .align(Alignment.TopCenter)
                    .background(Brush.verticalGradient(listOf(colors.surface, colors.surface.copy(alpha = 0f)))),
            )
        }
        BottomActionDock(
            languageLabel = stringResource(R.string.target_pill, "中文"),
            languageEnabled = true,
            onOpenLanguage = {},
            audioOutput = speech,
            audioEnabled = true,
            onToggleAudio = { speech = it },
            playing = recording && speech,
            onStopPlayback = {},
            active = recording,
            primaryLabel = stringResource(if (recording) R.string.stop_translation else R.string.start_live),
            primaryEnabled = true,
            onPrimaryClick = toggle,
        )
    }
}

@Composable
private fun Settings(back: () -> Unit) {
    var config by remember { mutableStateOf(LiveTranslateConfig(endpoint = "wss://example.org/realtime")) }
    var key by remember { mutableStateOf("") }
    var options by remember { mutableStateOf(AppOptions()) }
    SettingsLayout(back, service = {
        ServiceFields(
            profile = config.profile,
            config = config,
            key = key,
            keySaved = true,
            testing = false,
            onEdit = { config = config.copy(catalog = config.catalog.using(it)) },
            onSelect = { config = config.copy(catalog = config.catalog.using(it)) },
            onKey = { key = it },
            test = {},
        )
    }) {
        PreferenceGroups(config, options, true, { config = it(config) }, { options = it(options) }, true, {})
    }
}

@Composable
private fun Export(close: () -> Unit) {
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.scrim.copy(alpha = .32f)), contentAlignment = Alignment.BottomCenter) {
        Surface(shape = BottomSheetDefaults.ExpandedShape, color = MaterialTheme.colorScheme.surfaceContainerLow) {
            var format by remember { mutableStateOf(ExportFormat.MARKDOWN) }
            var content by remember { mutableStateOf(ExportContent.BILINGUAL) }
            Column {
                BottomSheetDefaults.DragHandle(Modifier.align(Alignment.CenterHorizontally))
                ExportChoices(
                    title = "河岸散步",
                    format = format,
                    content = content,
                    setFormat = { format = it },
                    setContent = { content = it },
                    preview = "# 河岸散步\n\n**09:40**\n早晨的河边很安静，适合散步。\n> The waterfront is quiet in the morning.",
                    save = close,
                    share = close,
                    copy = close,
                )
            }
        }
    }
}

// Layoutlib has no device fingerprint for Compose's default prefetch scheduler. A still preview
// displays visible items only; use the real production lists without scheduling offscreen work.
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun previewListState() = rememberLazyListState(prefetchStrategy = remember {
    object : LazyListPrefetchStrategy by LazyListPrefetchStrategy() {
        override val prefetchScheduler = object : PrefetchScheduler {
            override fun schedulePrefetch(prefetchRequest: PrefetchRequest) = Unit
        }
    }
})

@Composable
private fun DialogueReview(exit: () -> Unit) {
    val rows = listOf(
        SubtitleRow(
            "1", "我们在河边碰面吧。", true, "Let's meet by the river.", true,
            sourceLanguage = "zh", targetLanguage = "en", speaker = "A",
        ),
        SubtitleRow(
            "2", "Shall we meet at the bridge?", true, "我们在桥上见面好吗？", true,
            sourceLanguage = "en", targetLanguage = "zh", speaker = "B",
        ),
    )
    DialogueScreen(
        rows, "zh", "en", SessionState.RECORDING, true, false, false,
        stringResource(R.string.recording), remember { SnackbarHostState() },
        facing = true, toggleFacing = {}, setLanguages = { _, _ -> }, record = {}, exit = exit, onSpeech = {}, stopPlayback = {}, settings = {},
        listA = previewListState(), listB = previewListState(),
    )
}

@PreviewTest @Preview(name = "PhoneDialogue", widthDp = 393, heightDp = 780, locale = "zh-rCN")
@Composable fun DialoguePreview() = Review(Page.Dialogue)

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

@PreviewTest @Preview(name = "PhoneLightDe", widthDp = 360, heightDp = 780, locale = "de")
@Composable fun PhoneLightDe() = Review()

@PreviewTest @Preview(name = "SettingsDe", widthDp = 360, heightDp = 780, locale = "de")
@Composable fun SettingsDe() = Review(Page.Settings)

@PreviewTest @Preview(name = "DialogueDe", widthDp = 360, heightDp = 780, locale = "de")
@Composable fun DialogueDe() = Review(Page.Dialogue)

@PreviewTest @Preview(name = "PhoneLightTa", widthDp = 360, heightDp = 780, locale = "ta")
@Composable fun PhoneLightTa() = Review()

@PreviewTest @Preview(name = "SettingsTa", widthDp = 360, heightDp = 780, locale = "ta")
@Composable fun SettingsTa() = Review(Page.Settings)

@PreviewTest @Preview(name = "DialogueTa", widthDp = 360, heightDp = 780, locale = "ta")
@Composable fun DialogueTa() = Review(Page.Dialogue)
