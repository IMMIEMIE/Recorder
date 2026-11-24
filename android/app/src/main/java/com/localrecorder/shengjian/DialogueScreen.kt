package com.localrecorder.shengjian

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.SessionState
import com.localrecorder.live.SubtitleRow
import com.localrecorder.shengjian.ui.theme.Design

/** A dialog keeps the language choices facing the reader, including on the rotated half. */
@Composable
internal fun LanguageChoice(label: String, selected: String, onSelect: (String) -> Unit, enabled: Boolean = true,
                            other: String? = null, inverted: Boolean = false) {
    var open by rememberSaveable { mutableStateOf(false) }
    TextButton({ open = true }, enabled = enabled) { Text(label) }
    if (open && enabled) Dialog(onDismissRequest = { open = false }) {
        Surface(modifier = Modifier.rotate(if (inverted) 180f else 0f), shape = MaterialTheme.shapes.large,
            color = MaterialTheme.colorScheme.surfaceContainerHigh) {
            LazyColumn(Modifier.fillMaxWidth().padding(Design.spaceSm)) {
                item { Text(label.removeSuffix(" ▾"), Modifier.padding(Design.spaceMd), style = Design.title) }
                items(LiveTranslateConfig.LANGUAGES, key = { it.first }) { (code, name) ->
                    DropdownMenuItem(text = { Text(name) }, enabled = code != other,
                        trailingIcon = if (code == selected) ({ Glyph(R.drawable.ic_check_circle) }) else null,
                        onClick = { open = false; onSelect(code) })
                }
            }
        }
    }
}

@Composable
internal fun DialogueScreen(
    rows: List<SubtitleRow>, languageA: String, languageB: String, state: SessionState, startEnabled: Boolean,
    speech: Boolean, playing: Boolean, status: String, snackbar: SnackbarHostState,
    facing: Boolean, toggleFacing: () -> Unit,
    setLanguages: (String, String) -> Unit, record: () -> Unit, exit: () -> Unit, onSpeech: () -> Unit,
    stopPlayback: () -> Unit, settings: () -> Unit,
    listA: LazyListState = rememberLazyListState(), listB: LazyListState = rememberLazyListState(),
) {
    val canEdit = state != SessionState.FINISHING
    val active = state != SessionState.IDLE
    val rowsForPair = remember(rows, languageA, languageB) {
        rows.asReversed().filter { row ->
            when (row.speaker) {
                "A" -> row.sourceLanguage == languageA && row.targetLanguage == languageB
                "B" -> row.sourceLanguage == languageB && row.targetLanguage == languageA
                "unknown" -> true
                else -> false
            }
        }
    }
    Scaffold(snackbarHost = { SnackbarHost(snackbar) }, contentWindowInsets = WindowInsets.safeDrawing) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            DialoguePanel("B", languageB, languageA, rowsForPair, listB, facing, canEdit, { setLanguages(languageA, it) }, Modifier.weight(1f))
            HorizontalDivider()
            Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainerLow)
                .padding(horizontal = Design.spaceXs, vertical = Design.spaceXs)) {
                if (status.isNotBlank()) Text(status, Modifier.fillMaxWidth(), style = Design.caption, textAlign = TextAlign.Center)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceEvenly) {
                    Tool(R.drawable.ic_arrow_back, stringResource(R.string.dialogue_exit), canEdit, exit)
                    Tool(R.drawable.ic_swap_languages, stringResource(R.string.dialogue_swap), canEdit) { setLanguages(languageB, languageA) }
                    Button(record, enabled = startEnabled, shape = MaterialTheme.shapes.medium,
                        contentPadding = PaddingValues(horizontal = Design.spaceSm), modifier = Modifier.weight(1f).heightIn(min = 48.dp)) {
                        Glyph(if (active) R.drawable.ic_stop else R.drawable.ic_mic)
                        Spacer(Modifier.width(Design.spaceXs))
                        Text(stringResource(when (state) {
                            SessionState.IDLE -> R.string.dialogue_start
                            SessionState.FINISHING -> R.string.finishing
                            else -> R.string.stop
                        }))
                    }
                    Tool(R.drawable.ic_rotate_panel, stringResource(if (facing) R.string.dialogue_side_by_side else R.string.dialogue_face), click = toggleFacing)
                    var menu by remember { mutableStateOf(false) }
                    Box {
                        Tool(R.drawable.ic_more_vert, stringResource(R.string.more_actions)) { menu = true }
                        DropdownMenu(menu, { menu = false }) {
                            DropdownMenuItem(text = { Text(stringResource(if (speech) R.string.dialogue_speech_off else R.string.dialogue_speech_on)) },
                                enabled = canEdit, onClick = { menu = false; onSpeech() })
                            if (playing) DropdownMenuItem(text = { Text(stringResource(R.string.stop_audio)) },
                                onClick = { menu = false; stopPlayback() })
                            DropdownMenuItem(text = { Text(stringResource(R.string.settings)) }, onClick = { menu = false; settings() })
                        }
                    }
                }
            }
            HorizontalDivider()
            DialoguePanel("A", languageA, languageB, rowsForPair, listA, false, canEdit, { setLanguages(it, languageB) }, Modifier.weight(1f))
        }
    }
}

@Composable
private fun DialoguePanel(side: String, language: String, other: String, rows: List<SubtitleRow>, list: LazyListState, inverted: Boolean,
                          enabled: Boolean, setLanguage: (String) -> Unit, modifier: Modifier) {
    val name = LiveTranslateConfig.LANGUAGES.firstOrNull { it.first == language }?.second ?: language
    val visible = remember(rows, side) {
        rows.filter { row -> if (row.speaker == side || row.speaker == "unknown") row.source.isNotBlank() else row.translation.isNotBlank() }
    }
    Column(modifier.fillMaxWidth().rotate(if (inverted) 180f else 0f).padding(horizontal = Design.spaceMd)) {
        LanguageChoice(stringResource(R.string.dialogue_seat, side, name), language, setLanguage, enabled, other, inverted)
        if (visible.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.dialogue_waiting, name), style = Design.source, textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            val wasFollowing = list.firstVisibleItemIndex == 0
            LaunchedEffect(visible.firstOrNull()?.key) { if (wasFollowing) list.scrollToItem(0) }
            LazyColumn(Modifier.fillMaxSize(), state = list, reverseLayout = true, contentPadding = PaddingValues(bottom = Design.spaceSm)) {
                items(visible, key = { it.key }) { row ->
                    val unknown = row.speaker == "unknown"
                    val original = unknown || row.speaker == side
                    Column(Modifier.fillMaxWidth().padding(vertical = Design.spaceXs)) {
                        if (unknown) Text(stringResource(R.string.dialogue_unknown), style = Design.caption, color = MaterialTheme.colorScheme.tertiary)
                        Text(if (original) row.source else row.translation, style = if (original) Design.source else Design.translation,
                            color = if (original) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface)
                    }
                }
            }
        }
    }
}
