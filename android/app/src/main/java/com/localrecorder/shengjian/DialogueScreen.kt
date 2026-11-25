package com.localrecorder.shengjian

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.localrecorder.live.LiveTranslateConfig
import com.localrecorder.live.SessionState
import com.localrecorder.live.SubtitleRow
import com.localrecorder.shengjian.ui.theme.Design
import com.localrecorder.shengjian.ui.theme.LocalStatusColors

/** Unified language button backed by [LanguagePickerSheet], rotated 180° when facing the partner. */
@Composable
internal fun LanguageChoice(
    label: String,
    selected: String,
    onSelect: (String) -> Unit,
    enabled: Boolean = true,
    other: String? = null,
    inverted: Boolean = false,
    leadingDot: Color? = null,
    containerColor: Color = MaterialTheme.colorScheme.surfaceContainerLowest,
) {
    var open by rememberSaveable { mutableStateOf(false) }
    LanguagePillButton(
        label = label,
        enabled = enabled,
        leadingDot = leadingDot,
        containerColor = containerColor,
        onClick = { open = true },
    )
    if (open && enabled) {
        LanguagePickerSheet(
            title = stringResource(R.string.choose_language),
            subtitle = if (inverted) null else stringResource(R.string.language_live_hint),
            selected = selected,
            other = other,
            inverted = inverted,
            onSelect = onSelect,
            onDismiss = { open = false },
        )
    }
}

@Composable
internal fun DialogueScreen(
    rows: List<SubtitleRow>,
    languageA: String,
    languageB: String,
    state: SessionState,
    startEnabled: Boolean,
    speech: Boolean,
    playing: Boolean,
    status: String,
    snackbar: SnackbarHostState,
    facing: Boolean,
    toggleFacing: () -> Unit,
    setLanguages: (String, String) -> Unit,
    record: () -> Unit,
    exit: () -> Unit,
    onSpeech: () -> Unit,
    stopPlayback: () -> Unit,
    settings: () -> Unit,
    listA: LazyListState = rememberLazyListState(),
    listB: LazyListState = rememberLazyListState(),
) {
    val colors = MaterialTheme.colorScheme
    val statusColors = LocalStatusColors.current
    val haptics = LocalHapticFeedback.current
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
    val topRotation by animateFloatAsState(
        targetValue = if (facing) 180f else 0f,
        animationSpec = spring(dampingRatio = 0.78f, stiffness = Spring.StiffnessMediumLow),
        label = "dialogueTopRotation",
    )
    val recordBg by animateColorAsState(
        targetValue = if (active) statusColors.recording else colors.primary,
        animationSpec = tween(240),
        label = "dialogueRecordBg",
    )
    val recordFg by animateColorAsState(
        targetValue = if (active) onStatusColor(statusColors.recording) else colors.onPrimary,
        animationSpec = tween(240),
        label = "dialogueRecordFg",
    )

    Scaffold(
        containerColor = colors.surface,
        snackbarHost = { SnackbarHost(snackbar) },
        contentWindowInsets = WindowInsets.safeDrawing,
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            DialoguePanel(
                side = "B",
                language = languageB,
                other = languageA,
                rows = rowsForPair,
                list = listB,
                rotation = topRotation,
                invertedDialog = facing,
                enabled = canEdit,
                background = colors.surfaceContainerLow,
                pillColor = colors.surfaceContainerLowest,
                ownBubbleColor = colors.surfaceContainerHigh,
                ownBubbleText = colors.onSurfaceVariant,
                dotColor = colors.tertiary,
                roleTag = stringResource(if (facing) R.string.dialogue_facing_tag else R.string.dialogue_same_dir_tag),
                setLanguage = { setLanguages(languageA, it) },
                modifier = Modifier.weight(1f),
            )

            // Center Floating Control Island
            HorizontalDivider(color = colors.outlineVariant)
            Column(
                Modifier
                    .fillMaxWidth()
                    .background(colors.surfaceContainer)
                    .padding(horizontal = Design.spaceSm, vertical = 6.dp),
            ) {
                if (status.isNotBlank() && state != SessionState.RECORDING) {
                    Text(
                        status,
                        Modifier.fillMaxWidth().padding(bottom = 4.dp),
                        style = Design.caption,
                        color = statusColors.connecting,
                        textAlign = TextAlign.Center,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Tool(R.drawable.ic_arrow_back, stringResource(R.string.dialogue_exit), canEdit, colors.onSurface, exit)
                    Tool(R.drawable.ic_swap_languages, stringResource(R.string.dialogue_swap), canEdit, colors.onSurface) {
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        setLanguages(languageB, languageA)
                    }

                    Button(
                        onClick = {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            record()
                        },
                        enabled = startEnabled,
                        shape = CircleShape,
                        colors = ButtonDefaults.buttonColors(containerColor = recordBg, contentColor = recordFg),
                        contentPadding = PaddingValues(horizontal = 12.dp),
                        modifier = Modifier.weight(1f).heightIn(min = 48.dp),
                    ) {
                        if (state == SessionState.RECORDING) {
                            AnimatedEqualizer(recordFg, Modifier.size(16.dp))
                        } else {
                            Glyph(if (active) R.drawable.ic_stop else R.drawable.ic_mic, Modifier.size(18.dp))
                        }
                        Spacer(Modifier.width(6.dp))
                        Text(
                            stringResource(
                                when (state) {
                                    SessionState.IDLE -> R.string.dialogue_start
                                    SessionState.FINISHING -> R.string.finishing
                                    else -> R.string.stop
                                },
                            ),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }

                    // Direct translated audio toggle elevated onto the center bar
                    val speechBg = if (speech) colors.primaryContainer else Color.Transparent
                    val speechFg = if (speech) colors.onPrimaryContainer else colors.onSurfaceVariant
                    IconButton(
                        onClick = onSpeech,
                        enabled = canEdit,
                        modifier = Modifier
                            .sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                            .clip(CircleShape)
                            .background(speechBg),
                    ) {
                        Glyph(
                            if (speech) R.drawable.ic_volume_up else R.drawable.ic_volume_off,
                            Modifier.size(20.dp),
                            tint = if (canEdit) speechFg else speechFg.copy(alpha = 0.38f),
                        )
                    }

                    val rotateBg = if (facing) colors.secondaryContainer else Color.Transparent
                    val rotateFg = if (facing) colors.onSecondaryContainer else colors.onSurface
                    IconButton(
                        onClick = {
                            haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                            toggleFacing()
                        },
                        modifier = Modifier
                            .sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                            .clip(CircleShape)
                            .background(rotateBg),
                    ) {
                        Glyph(R.drawable.ic_rotate_panel, Modifier.size(20.dp), tint = rotateFg)
                    }

                    var menu by remember { mutableStateOf(false) }
                    Box {
                        Tool(R.drawable.ic_more_vert, stringResource(R.string.more_actions), true, colors.onSurfaceVariant) { menu = true }
                        DropdownMenu(menu, { menu = false }) {
                            if (playing) {
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.stop_audio)) },
                                    onClick = { menu = false; stopPlayback() },
                                )
                            }
                            DropdownMenuItem(
                                text = { Text(stringResource(if (speech) R.string.dialogue_speech_off else R.string.dialogue_speech_on)) },
                                enabled = canEdit,
                                onClick = { menu = false; onSpeech() },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.settings)) },
                                onClick = { menu = false; settings() },
                            )
                        }
                    }
                }
            }
            HorizontalDivider(color = colors.outlineVariant)

            DialoguePanel(
                side = "A",
                language = languageA,
                other = languageB,
                rows = rowsForPair,
                list = listA,
                rotation = 0f,
                invertedDialog = false,
                enabled = canEdit,
                background = colors.surface,
                pillColor = colors.surfaceContainerLow,
                ownBubbleColor = colors.secondaryContainer,
                ownBubbleText = colors.onSecondaryContainer,
                dotColor = colors.primary,
                roleTag = stringResource(R.string.dialogue_mine),
                setLanguage = { setLanguages(it, languageB) },
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun DialoguePanel(
    side: String,
    language: String,
    other: String,
    rows: List<SubtitleRow>,
    list: LazyListState,
    rotation: Float,
    invertedDialog: Boolean,
    enabled: Boolean,
    background: Color,
    pillColor: Color,
    ownBubbleColor: Color,
    ownBubbleText: Color,
    dotColor: Color,
    roleTag: String,
    setLanguage: (String) -> Unit,
    modifier: Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val name = LiveTranslateConfig.LANGUAGES.firstOrNull { it.first == language }?.second ?: language
    val visible = remember(rows, side) {
        rows.filter { row -> if (row.speaker == side || row.speaker == "unknown") row.source.isNotBlank() else row.translation.isNotBlank() }
    }
    Column(
        modifier
            .fillMaxWidth()
            .background(background)
            .graphicsLayer { rotationZ = rotation }
            .padding(horizontal = Design.spaceMd, vertical = 10.dp),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(bottom = Design.spaceSm),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            LanguageChoice(
                label = stringResource(R.string.side_label, side, name),
                selected = language,
                onSelect = setLanguage,
                enabled = enabled,
                other = other,
                inverted = invertedDialog,
                leadingDot = dotColor,
                containerColor = pillColor,
            )
            Spacer(Modifier.weight(1f))
            Text(
                roleTag,
                style = Design.caption,
                color = colors.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        if (visible.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    stringResource(R.string.dialogue_waiting, name),
                    style = Design.source,
                    textAlign = TextAlign.Center,
                    color = colors.onSurfaceVariant,
                )
            }
        } else {
            val wasFollowing = list.firstVisibleItemIndex == 0
            LaunchedEffect(visible.firstOrNull()?.key) { if (wasFollowing) list.scrollToItem(0) }
            val inspect = LocalInspectionMode.current
            LazyColumn(
                Modifier.fillMaxSize(),
                state = list,
                reverseLayout = true,
                verticalArrangement = Arrangement.spacedBy(10.dp),
                contentPadding = PaddingValues(bottom = Design.spaceXs),
            ) {
                items(visible, key = { it.key }) { row ->
                    val unknown = row.speaker == "unknown"
                    val isOwnOriginal = row.speaker == side
                    val isLivePartner = !unknown && !isOwnOriginal && !row.translationDone
                    Column(
                        Modifier.fillMaxWidth().then(if (inspect) Modifier else Modifier.animateItem()),
                        horizontalAlignment = if (isOwnOriginal) Alignment.End else Alignment.Start,
                    ) {
                        when {
                            unknown -> {
                                Surface(
                                    color = colors.tertiaryContainer.copy(alpha = 0.45f),
                                    shape = RoundedCornerShape(Design.radiusButton),
                                ) {
                                    Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                        Text(stringResource(R.string.dialogue_unknown), style = Design.caption, color = colors.tertiary)
                                        Text(row.source, style = Design.source, color = colors.onSurface)
                                    }
                                }
                            }
                            isOwnOriginal -> {
                                Surface(
                                    color = ownBubbleColor,
                                    shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp, bottomStart = 16.dp, bottomEnd = 6.dp),
                                    modifier = Modifier.widthIn(max = 310.dp),
                                ) {
                                    Text(
                                        row.source,
                                        style = Design.source,
                                        color = ownBubbleText.copy(alpha = if (row.sourceDone) 1f else Design.draftOpacity),
                                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                                    )
                                }
                            }
                            isLivePartner -> {
                                Surface(
                                    color = colors.surfaceContainerLowest,
                                    shape = RoundedCornerShape(Design.radiusCard),
                                    border = BorderStroke(1.dp, colors.outlineVariant),
                                ) {
                                    Column(Modifier.padding(horizontal = 12.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                            PulsingDot(colors.primary)
                                            Text(stringResource(R.string.dialogue_translating_partner), style = Design.caption, color = colors.primary)
                                        }
                                        Text(
                                            row.translation,
                                            style = Design.translation,
                                            color = colors.onSurface.copy(alpha = Design.draftOpacity),
                                        )
                                    }
                                }
                            }
                            else -> {
                                Text(
                                    row.translation,
                                    style = Design.translation,
                                    color = colors.onSurface,
                                    modifier = Modifier.padding(vertical = 2.dp),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
