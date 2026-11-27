package com.localrecorder.shengjian

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.provider.Settings
import android.text.Layout
import android.text.StaticLayout
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.localrecorder.live.SessionSnapshot
import com.localrecorder.live.SessionState
import com.localrecorder.live.SubtitleRow
import com.localrecorder.live.SubtitleTailWindow
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Lightweight WindowManager floating subtitle overlay (TYPE_APPLICATION_OVERLAY + FLAG_NOT_FOCUSABLE).
 *
 * Uses native Android Views rather than ComposeView to stay dependency-free, avoid service lifecycle
 * owner pitfalls, and keep the APK well within the size budget. Styled with Shengjian's exact light
 * and dark design tokens.
 */
class FloatingSubtitleOverlay(
    private val appContext: Context,
    private val onToggleBilingual: () -> Unit,
    private val onOpenApp: () -> Unit,
    private val onStopSession: () -> Unit,
    private val onCloseOverlay: () -> Unit,
    private val onPositionChanged: (x: Int, y: Int) -> Unit,
) {
    private val windowManager = appContext.getSystemService(WindowManager::class.java)
    private var rootView: LinearLayout? = null
    private var params: WindowManager.LayoutParams? = null
    private var darkApplied: Boolean? = null

    private var statusDot: View? = null
    private var statusLabel: TextView? = null
    private var prevTranslation: TextView? = null
    private var prevSource: TextView? = null
    private var currentTranslation: TextView? = null
    private var currentSource: TextView? = null
    private var controlsRow: LinearLayout? = null
    private var bilingualBtn: TextView? = null
    private var openAppBtn: TextView? = null
    private var stopBtn: TextView? = null
    private var closeBtn: ImageButton? = null

    private var controlsExpanded = false
    private var lastSnapshot: SessionSnapshot? = null
    private var lastBilingual = true
    private var lastDark = false
    private var lastTextWidthPx = 0

    private data class TailCacheKey(
        val text: String,
        val widthPx: Int,
        val maxLines: Int,
        val textSizePx: Float,
        val bold: Boolean,
    )

    private val tailCache = LinkedHashMap<TailCacheKey, String>(MAX_TAIL_CACHE_SIZE + 1, 0.75f, true)

    val isShowing: Boolean get() = rootView != null

    fun showOrUpdate(
        snapshot: SessionSnapshot,
        bilingual: Boolean,
        savedX: Int,
        savedY: Int,
    ) {
        if (!Settings.canDrawOverlays(appContext)) {
            hide()
            return
        }
        val dark = isDarkTheme(appContext)
        if (rootView == null || darkApplied != dark) {
            val existingX = params?.x ?: savedX
            val existingY = params?.y ?: savedY
            hide()
            attachView(dark, existingX, existingY)
        }
        clampWindowPosition()
        bindContent(snapshot, bilingual, dark)
    }

    fun hide() {
        val view = rootView ?: return
        rootView = null
        params = null
        darkApplied = null
        statusDot = null
        statusLabel = null
        prevTranslation = null
        prevSource = null
        currentTranslation = null
        currentSource = null
        controlsRow = null
        bilingualBtn = null
        openAppBtn = null
        stopBtn = null
        closeBtn = null
        lastSnapshot = null
        lastTextWidthPx = 0
        tailCache.clear()
        try {
            windowManager?.removeViewImmediate(view)
        } catch (_: Exception) {
            try {
                windowManager?.removeView(view)
            } catch (_: Exception) {
            }
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun attachView(dark: Boolean, savedX: Int, savedY: Int) {
        val wm = windowManager ?: return
        val localized = AppLocale.localizedContext(appContext)
        val palette = if (dark) DARK_PALETTE else LIGHT_PALETTE
        val metrics = appContext.resources.displayMetrics
        val maxWidthPx = overlayWidthPx(metrics)

        val container = LinearLayout(localized).apply {
            orientation = LinearLayout.VERTICAL
            val padH = dp(CONTAINER_PADDING_H_DP)
            val padV = dp(10)
            setPadding(padH, padV, padH, padV)
            elevation = dp(8).toFloat()
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(16).toFloat()
                setColor(palette.surface)
                setStroke(dp(1), palette.border)
            }
        }

        // Top compact drag handle & status line
        val header = LinearLayout(localized).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
        }
        val dot = View(localized).apply {
            layoutParams = LinearLayout.LayoutParams(dp(7), dp(7)).apply {
                marginEnd = dp(6)
            }
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(palette.recording)
            }
        }
        val statusText = TextView(localized).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            setTextColor(palette.source)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val dragPill = View(localized).apply {
            layoutParams = LinearLayout.LayoutParams(dp(26), dp(3)).apply {
                marginStart = dp(8)
            }
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(2).toFloat()
                setColor(palette.border)
            }
        }
        header.addView(dot)
        header.addView(statusText)
        header.addView(dragPill)
        container.addView(header)

        // Previous row (optional, compact) — tail-windowed so the ending bridges smoothly into the latest row.
        val prevTransView = makeSubtitleView(
            context = localized,
            textSizeSp = 14f,
            color = palette.translation,
            bold = false,
            topPaddingDp = 6,
            initialAlpha = 0.72f,
            initialVisibility = View.GONE,
        )
        val prevSrcView = makeSubtitleView(
            context = localized,
            textSizeSp = 12f,
            color = palette.source,
            bold = false,
            topPaddingDp = 1,
            initialAlpha = 0.68f,
            initialVisibility = View.GONE,
        )

        // Current / latest row (prominent) — tail-windowed so newly streamed words are always visible promptly.
        val curTransView = makeSubtitleView(
            context = localized,
            textSizeSp = 16f,
            color = palette.translation,
            bold = true,
            topPaddingDp = 6,
        )
        val curSrcView = makeSubtitleView(
            context = localized,
            textSizeSp = 13f,
            color = palette.source,
            bold = false,
            topPaddingDp = 2,
            initialVisibility = View.GONE,
        )

        container.addView(prevTransView)
        container.addView(prevSrcView)
        container.addView(curTransView)
        container.addView(curSrcView)

        // Compact quick-action bar (shown when user taps the overlay)
        val actions = LinearLayout(localized).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(8), 0, 0)
            visibility = if (controlsExpanded) View.VISIBLE else View.GONE
        }
        val toggleBilingual = makeActionChip(localized, palette.chipBg, palette.chipFg) {
            onToggleBilingual()
        }
        val openApp = makeActionChip(localized, palette.chipBg, palette.chipFg) {
            onOpenApp()
        }
        val stopSession = makeActionChip(localized, palette.dangerBg, palette.dangerFg) {
            onStopSession()
        }
        val closeOverlay = ImageButton(localized).apply {
            setImageResource(R.drawable.ic_close)
            setColorFilter(palette.source)
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            contentDescription = localized.getString(R.string.floating_close)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(palette.chipBg)
            }
            layoutParams = LinearLayout.LayoutParams(dp(30), dp(30))
            setPadding(dp(6), dp(6), dp(6), dp(6))
            setOnClickListener { onCloseOverlay() }
        }

        actions.addView(toggleBilingual, chipLayoutParams())
        actions.addView(openApp, chipLayoutParams())
        actions.addView(stopSession, chipLayoutParams())
        actions.addView(closeOverlay)
        container.addView(actions)

        val defaultX = ((metrics.widthPixels - maxWidthPx) / 2).coerceAtLeast(dp(12))
        val defaultY = dp(84)
        val initialX = if (savedX == Int.MIN_VALUE) defaultX else savedX
        val initialY = if (savedY == Int.MIN_VALUE) defaultY else savedY

        val layoutParams = WindowManager.LayoutParams(
            maxWidthPx,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = clampX(initialX, maxWidthPx, metrics.widthPixels)
            y = clampY(initialY, metrics.heightPixels)
        }

        val touchSlop = ViewConfiguration.get(appContext).scaledTouchSlop
        var startRawX = 0f
        var startRawY = 0f
        var startWinX = 0
        var startWinY = 0
        var dragging = false

        container.setOnTouchListener { v, event ->
            val lp = params ?: return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startRawX = event.rawX
                    startRawY = event.rawY
                    startWinX = lp.x
                    startWinY = lp.y
                    dragging = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - startRawX).roundToInt()
                    val dy = (event.rawY - startRawY).roundToInt()
                    if (!dragging && (abs(dx) > touchSlop || abs(dy) > touchSlop)) {
                        dragging = true
                    }
                    if (dragging) {
                        val dm = appContext.resources.displayMetrics
                        val widthPx = if (v.width > 0) v.width else lp.width
                        lp.x = clampX(startWinX + dx, widthPx, dm.widthPixels)
                        lp.y = clampY(startWinY + dy, dm.heightPixels)
                        try {
                            wm.updateViewLayout(v, lp)
                        } catch (_: Exception) {
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (dragging) {
                        onPositionChanged(lp.x, lp.y)
                    } else {
                        v.performClick()
                        controlsExpanded = !controlsExpanded
                        controlsRow?.visibility = if (controlsExpanded) View.VISIBLE else View.GONE
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    if (dragging) onPositionChanged(lp.x, lp.y)
                    true
                }
                else -> false
            }
        }

        container.addOnLayoutChangeListener { v, left, _, right, _, oldLeft, _, oldRight, _ ->
            val newWidth = right - left
            val oldWidth = oldRight - oldLeft
            if (newWidth > 0 && newWidth != oldWidth) {
                val contentWidth = (newWidth - v.paddingLeft - v.paddingRight).coerceAtLeast(1)
                if (contentWidth != lastTextWidthPx) {
                    v.post {
                        val snapshot = lastSnapshot ?: return@post
                        if (rootView !== v) return@post
                        bindContent(snapshot, lastBilingual, lastDark, overrideContainerWidthPx = newWidth)
                    }
                }
            }
        }

        try {
            wm.addView(container, layoutParams)
            rootView = container
            params = layoutParams
            darkApplied = dark
            statusDot = dot
            statusLabel = statusText
            prevTranslation = prevTransView
            prevSource = prevSrcView
            currentTranslation = curTransView
            currentSource = curSrcView
            controlsRow = actions
            bilingualBtn = toggleBilingual
            openAppBtn = openApp
            stopBtn = stopSession
            closeBtn = closeOverlay
        } catch (_: Exception) {
            rootView = null
            params = null
            darkApplied = null
        }
    }

    private fun bindContent(
        snapshot: SessionSnapshot,
        bilingual: Boolean,
        dark: Boolean,
        overrideContainerWidthPx: Int? = null,
    ) {
        lastSnapshot = snapshot
        lastBilingual = bilingual
        lastDark = dark
        val textWidthPx = currentTextWidthPx(overrideContainerWidthPx)
        lastTextWidthPx = textWidthPx

        val localized = AppLocale.localizedContext(appContext)
        val palette = if (dark) DARK_PALETTE else LIGHT_PALETTE

        val dotColor = when {
            snapshot.slowNetwork -> palette.slow
            snapshot.state == SessionState.RECORDING -> palette.recording
            else -> palette.connecting
        }
        (statusDot?.background as? GradientDrawable)?.setColor(dotColor)

        val statusText = localized.formatStatus(snapshot).ifBlank {
            when (snapshot.state) {
                SessionState.CONNECTING -> localized.getString(R.string.connecting)
                SessionState.RECONNECTING -> localized.getString(R.string.status_reconnecting)
                SessionState.FINISHING -> localized.getString(R.string.finishing)
                else -> localized.getString(R.string.recording)
            }
        }
        statusLabel?.text = statusText

        bilingualBtn?.text = localized.getString(if (bilingual) R.string.bilingual else R.string.translation_only)
        openAppBtn?.text = localized.getString(R.string.floating_open_app)
        stopBtn?.text = localized.getString(R.string.stop)
        closeBtn?.contentDescription = localized.getString(R.string.floating_close)

        val recent: List<SubtitleRow> = snapshot.rows
            .asSequence()
            .filter { it.marker.isEmpty() && it.markerMessage == null && (it.translation.isNotBlank() || it.source.isNotBlank()) }
            .toList()
            .takeLast(2)

        if (recent.isEmpty()) {
            prevTranslation?.visibility = View.GONE
            prevSource?.visibility = View.GONE
            currentTranslation?.apply {
                visibility = View.VISIBLE
                alpha = 0.72f
                val waiting = localized.getString(R.string.floating_waiting_audio)
                if (text?.toString() != waiting) text = waiting
            }
            currentSource?.visibility = View.GONE
            return
        }

        if (recent.size == 2) {
            bindRow(
                row = recent[0],
                bilingual = bilingual,
                translationView = prevTranslation,
                sourceView = prevSource,
                translationMaxLines = PREV_TRANSLATION_MAX_LINES,
                sourceMaxLines = PREV_SOURCE_MAX_LINES,
                textWidthPx = textWidthPx,
                baseAlpha = 0.72f,
            )
            bindRow(
                row = recent[1],
                bilingual = bilingual,
                translationView = currentTranslation,
                sourceView = currentSource,
                translationMaxLines = CURRENT_TRANSLATION_MAX_LINES,
                sourceMaxLines = CURRENT_SOURCE_MAX_LINES,
                textWidthPx = textWidthPx,
                baseAlpha = 1f,
            )
        } else {
            prevTranslation?.visibility = View.GONE
            prevSource?.visibility = View.GONE
            bindRow(
                row = recent[0],
                bilingual = bilingual,
                translationView = currentTranslation,
                sourceView = currentSource,
                translationMaxLines = CURRENT_TRANSLATION_MAX_LINES,
                sourceMaxLines = CURRENT_SOURCE_MAX_LINES,
                textWidthPx = textWidthPx,
                baseAlpha = 1f,
            )
        }
    }

    private fun bindRow(
        row: SubtitleRow,
        bilingual: Boolean,
        translationView: TextView?,
        sourceView: TextView?,
        translationMaxLines: Int,
        sourceMaxLines: Int,
        textWidthPx: Int,
        baseAlpha: Float,
    ) {
        val primaryText = row.translation.ifBlank { row.source }
        val primaryDone = if (row.translation.isNotBlank()) row.translationDone else row.sourceDone
        translationView?.apply {
            visibility = View.VISIBLE
            val display = tailText(this, primaryText, textWidthPx, translationMaxLines)
            if (text?.toString() != display) text = display
            alpha = if (primaryDone) baseAlpha else baseAlpha * DRAFT_OPACITY
        }

        val showSource = bilingual && row.translation.isNotBlank() && row.source.isNotBlank()
        sourceView?.apply {
            if (showSource) {
                visibility = View.VISIBLE
                val display = tailText(this, row.source, textWidthPx, sourceMaxLines)
                if (text?.toString() != display) text = display
                alpha = if (row.sourceDone) baseAlpha else baseAlpha * DRAFT_OPACITY
            } else {
                visibility = View.GONE
            }
        }
    }

    private fun makeSubtitleView(
        context: Context,
        textSizeSp: Float,
        color: Int,
        bold: Boolean,
        topPaddingDp: Int,
        initialAlpha: Float = 1f,
        initialVisibility: Int = View.VISIBLE,
    ): TextView = TextView(context).apply {
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        )
        setTextSize(TypedValue.COMPLEX_UNIT_SP, textSizeSp)
        if (bold) typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        setTextColor(color)
        alpha = initialAlpha
        // Tail-windowing bounds the visible line count while keeping the newest words intact;
        // greedy line breaking prevents earlier visible lines from reflowing on each incoming token.
        maxLines = Int.MAX_VALUE
        ellipsize = null
        breakStrategy = Layout.BREAK_STRATEGY_SIMPLE
        hyphenationFrequency = Layout.HYPHENATION_FREQUENCY_NONE
        setPadding(0, dp(topPaddingDp), 0, 0)
        visibility = initialVisibility
    }

    private fun tailText(view: TextView, raw: String, containerContentWidthPx: Int, maxLines: Int): String {
        val normalized = raw.trim()
        if (normalized.isEmpty() || maxLines <= 0) return ""
        val availableWidth = (containerContentWidthPx - view.totalPaddingLeft - view.totalPaddingRight).coerceAtLeast(1)
        val key = TailCacheKey(
            text = normalized,
            widthPx = availableWidth,
            maxLines = maxLines,
            textSizePx = view.textSize,
            bold = view.typeface?.isBold == true,
        )
        tailCache[key]?.let { return it }
        val result = SubtitleTailWindow.tail(normalized, maxLines) { text ->
            val layout = StaticLayout.Builder.obtain(text, 0, text.length, view.paint, availableWidth)
                .setAlignment(Layout.Alignment.ALIGN_NORMAL)
                .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                .setIncludePad(view.includeFontPadding)
                .setLineSpacing(view.lineSpacingExtra, view.lineSpacingMultiplier)
                .build()
            List(layout.lineCount) { i ->
                text.substring(layout.getLineStart(i), layout.getLineEnd(i))
            }
        }
        if (tailCache.size >= MAX_TAIL_CACHE_SIZE) {
            val eldest = tailCache.entries.iterator()
            if (eldest.hasNext()) {
                eldest.next()
                eldest.remove()
            }
        }
        tailCache[key] = result
        return result
    }

    private fun currentTextWidthPx(overrideContainerWidthPx: Int? = null): Int {
        val dm = appContext.resources.displayMetrics
        val container = rootView
        val containerWidth = overrideContainerWidthPx?.takeIf { it > 0 }
            ?: params?.width?.takeIf { it > 0 }
            ?: overlayWidthPx(dm)
        val horizontalPadding = if (container != null) {
            container.paddingLeft + container.paddingRight
        } else {
            dp(CONTAINER_PADDING_H_DP) * 2
        }
        return (containerWidth - horizontalPadding).coerceAtLeast(1)
    }

    private fun overlayWidthPx(dm: android.util.DisplayMetrics): Int =
        minOf((dm.widthPixels * 0.90f).roundToInt(), dp(420))

    private fun clampWindowPosition() {
        val view = rootView ?: return
        val lp = params ?: return
        val dm = appContext.resources.displayMetrics
        val targetWidth = overlayWidthPx(dm)
        val clampedX = clampX(lp.x, targetWidth, dm.widthPixels)
        val clampedY = clampY(lp.y, dm.heightPixels)
        if (lp.width != targetWidth || lp.x != clampedX || lp.y != clampedY) {
            lp.width = targetWidth
            lp.x = clampedX
            lp.y = clampedY
            try {
                windowManager?.updateViewLayout(view, lp)
            } catch (_: Exception) {
            }
        }
    }

    private fun makeActionChip(context: Context, bg: Int, fg: Int, onClick: () -> Unit): TextView =
        TextView(context).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            setTextColor(fg)
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setPadding(dp(10), dp(6), dp(10), dp(6))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(999).toFloat()
                setColor(bg)
            }
            setOnClickListener { onClick() }
        }

    private fun chipLayoutParams(): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
            marginEnd = dp(6)
        }

    private fun clampX(x: Int, widthPx: Int, screenWidthPx: Int): Int {
        val margin = dp(8)
        val maxX = (screenWidthPx - widthPx - margin).coerceAtLeast(margin)
        return x.coerceIn(margin, maxX)
    }

    private fun clampY(y: Int, screenHeightPx: Int): Int {
        val topMin = dp(24)
        val bottomMax = (screenHeightPx - dp(120)).coerceAtLeast(topMin)
        return y.coerceIn(topMin, bottomMax)
    }

    private fun dp(value: Int): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value.toFloat(), appContext.resources.displayMetrics).roundToInt()

    private fun isDarkTheme(context: Context): Boolean =
        (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    private data class Palette(
        val surface: Int,
        val border: Int,
        val translation: Int,
        val source: Int,
        val chipBg: Int,
        val chipFg: Int,
        val dangerBg: Int,
        val dangerFg: Int,
        val recording: Int,
        val connecting: Int,
        val slow: Int,
    )

    private companion object {
        const val DRAFT_OPACITY = 0.84f
        const val CONTAINER_PADDING_H_DP = 14
        const val PREV_TRANSLATION_MAX_LINES = 2
        const val PREV_SOURCE_MAX_LINES = 1
        const val CURRENT_TRANSLATION_MAX_LINES = 3
        const val CURRENT_SOURCE_MAX_LINES = 2
        const val MAX_TAIL_CACHE_SIZE = 32

        val LIGHT_PALETTE = Palette(
            surface = 0xF2F1F5F1.toInt(),
            border = 0xFFBCCBC2.toInt(),
            translation = 0xFF18231F.toInt(),
            source = 0xFF475950.toInt(),
            chipBg = 0xFFD9E9E2.toInt(),
            chipFg = 0xFF263F37.toInt(),
            dangerBg = 0xFFFFE0DE.toInt(),
            dangerFg = 0xFF74181E.toInt(),
            recording = 0xFF953342.toInt(),
            connecting = 0xFF365F84.toInt(),
            slow = 0xFF805205.toInt(),
        )

        val DARK_PALETTE = Palette(
            surface = 0xF217201B.toInt(),
            border = 0xFF44574B.toInt(),
            translation = 0xFFE4ECE6.toInt(),
            source = 0xFFB8C8BD.toInt(),
            chipBg = 0xFF344C43.toInt(),
            chipFg = 0xFFD3EDE0.toInt(),
            dangerBg = 0xFF71262B.toInt(),
            dangerFg = 0xFFFFDADB.toInt(),
            recording = 0xFFFFA8B6.toInt(),
            connecting = 0xFFA5D1F7.toInt(),
            slow = 0xFFF3CD84.toInt(),
        )
    }
}
