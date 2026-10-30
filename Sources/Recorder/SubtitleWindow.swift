import SwiftUI
import AppKit
import CoreText

/// Subtitle style lives in UserDefaults: the SwiftUI view reads it through @AppStorage, the AppKit context menu writes it.
enum SubtitleStyle {
    static let fontSizeKey = "subtitle.fontSize"
    static let opacityKey = "subtitle.opacity"
    static let translationKey = "subtitle.showTranslation"
    static let backgroundKey = "subtitle.background"
    static let linesKey = "subtitle.maxLines"
    static let anchorXKey = "subtitle.anchorX"
    static let anchorYKey = "subtitle.anchorY"
    static let defaultFontSize = 24.0
    static let defaultOpacity = 0.7
    static let defaultLines = 2
    static let translationScale = 0.86
}

/// Short-lived UI state shared by the window controller and the view.
final class SubtitleStage: ObservableObject {
    @Published var hint = false
}

private final class SubtitlePanel: NSPanel {
    var onArrow: ((CGFloat, CGFloat) -> Void)?
    var onKeyChange: ((Bool) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Arrow keys move the subtitles whenever this panel is key, before any view can consume them.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let offset = Self.offset(for: event) { onArrow?(offset.dx, offset.dy); return }
        super.sendEvent(event)
    }
    override func becomeKey() { super.becomeKey(); onKeyChange?(true) }
    override func resignKey() { super.resignKey(); onKeyChange?(false) }
    private static func offset(for event: NSEvent) -> CGVector? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return nil }
        let step: CGFloat = flags.contains(.shift) ? 40 : flags.contains(.option) ? 1 : 10
        switch event.keyCode {
        case 123: return CGVector(dx: -step, dy: 0)
        case 124: return CGVector(dx: step, dy: 0)
        case 125: return CGVector(dx: 0, dy: -step)
        case 126: return CGVector(dx: 0, dy: step)
        default: return nil
        }
    }
}

/// A borderless, transparent panel sized to its text and anchored at the bottom centre of the text block,
/// so new lines grow upwards like video subtitles. Only the text (and an optional bar behind each line) is drawn.
final class SubtitleWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private weak var model: AppModel?
    private let stage = SubtitleStage()
    /// Bottom centre of the subtitle block in screen coordinates.
    private var anchor: NSPoint
    private static let initialSize = NSSize(width: 360, height: 60)
    private var contentSize = SubtitleWindowController.initialSize
    private var placing = false
    private var hintTimer: Timer?

    init(model: AppModel, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.model = model
        let start = Self.savedAnchor() ?? Self.defaultAnchor()
        anchor = start
        let size = Self.initialSize
        let frame = NSRect(x: start.x - size.width / 2, y: start.y, width: size.width, height: size.height)
        let panel = SubtitlePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "声笺字幕"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        let hosting = NSHostingView(rootView: SubtitleView(model: model, stage: stage,
            // Resize outside the SwiftUI update that reported the size.
            onSize: { [weak self] size in DispatchQueue.main.async { self?.place(size) } },
            menu: { [weak self] in self?.makeMenu() ?? NSMenu() }))
        // The window follows the text through place(_:), not through Auto Layout constraints of the hosting view.
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.onArrow = { [weak self] dx, dy in self?.nudge(dx: dx, dy: dy) }
        panel.onKeyChange = { [weak self] key in
            if key { self?.showHint(for: 3) } else { self?.hideHint() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Becoming key shows the keyboard hint, so the arrow keys work right after entering subtitle mode.
    func show() { place(contentSize); window?.makeKeyAndOrderFront(nil) }
    func windowWillClose(_ notification: Notification) { hideHint(); onClose() }
    func windowDidMove(_ notification: Notification) {
        guard !placing, let frame = window?.frame else { return }
        anchor = NSPoint(x: frame.midX, y: frame.minY); saveAnchor()
    }

    private func place(_ size: NSSize) {
        guard let window, size.width >= 1, size.height >= 1 else { return }
        contentSize = size
        var frame = NSRect(x: (anchor.x - size.width / 2).rounded(), y: anchor.y.rounded(), width: size.width.rounded(.up), height: size.height.rounded(.up))
        // Keep the text on the display that holds the anchor; a disconnected display falls back to the main one.
        let point = anchor
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        if let area = screen?.visibleFrame {
            frame.origin.x = max(area.minX, min(frame.minX, area.maxX - frame.width))
            frame.origin.y = max(area.minY, min(frame.minY, area.maxY - frame.height))
        }
        guard frame != window.frame else { return }
        placing = true
        window.setFrame(frame, display: true)
        placing = false
    }
    private func nudge(dx: CGFloat, dy: CGFloat) {
        anchor = NSPoint(x: anchor.x + dx, y: anchor.y + dy)
        place(contentSize)
        // Follow the clamped position so repeated presses at a screen edge do not build up an invisible offset.
        if let frame = window?.frame { anchor = NSPoint(x: frame.midX, y: frame.minY) }
        saveAnchor(); showHint(for: 2)
    }
    private func resetPosition() { anchor = Self.defaultAnchor(); place(contentSize); saveAnchor() }
    private func showHint(for seconds: TimeInterval) {
        stage.hint = true
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.stage.hint = false }
    }
    private func hideHint() { hintTimer?.invalidate(); hintTimer = nil; stage.hint = false }

    private static func defaultAnchor() -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.midX, y: visible.minY + 70)
    }
    private static func savedAnchor() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard let x = defaults.object(forKey: SubtitleStyle.anchorXKey) as? Double, let y = defaults.object(forKey: SubtitleStyle.anchorYKey) as? Double else { return nil }
        let point = NSPoint(x: x, y: y)
        // A disconnected display must not leave the subtitles unreachable.
        let reachable = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(point) }
        return reachable ? point : nil
    }
    private func saveAnchor() {
        UserDefaults.standard.set(Double(anchor.x), forKey: SubtitleStyle.anchorXKey)
        UserDefaults.standard.set(Double(anchor.y), forKey: SubtitleStyle.anchorYKey)
    }

    private func makeMenu() -> NSMenu {
        let defaults = UserDefaults.standard
        let fontSize = defaults.object(forKey: SubtitleStyle.fontSizeKey) as? Double ?? SubtitleStyle.defaultFontSize
        let opacity = defaults.object(forKey: SubtitleStyle.opacityKey) as? Double ?? SubtitleStyle.defaultOpacity
        let lines = defaults.object(forKey: SubtitleStyle.linesKey) as? Int ?? SubtitleStyle.defaultLines
        let bars = (defaults.string(forKey: SubtitleStyle.backgroundKey) ?? "box") == "box"
        let translation = defaults.object(forKey: SubtitleStyle.translationKey) as? Bool ?? true
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(Self.submenu("字号", [18, 20, 24, 28, 32, 36, 40].map { size in
            SubtitleMenuItem("\(size)", checked: Int(fontSize.rounded()) == size) { defaults.set(Double(size), forKey: SubtitleStyle.fontSizeKey) }
        }))
        menu.addItem(Self.submenu("最多显示行数", [1, 2, 3].map { count in
            SubtitleMenuItem("\(count) 行", checked: lines == count) { defaults.set(count, forKey: SubtitleStyle.linesKey) }
        }))
        menu.addItem(Self.submenu("背景", [
            SubtitleMenuItem("每行半透明底色", checked: bars) { defaults.set("box", forKey: SubtitleStyle.backgroundKey) },
            SubtitleMenuItem("仅文字（带阴影）", checked: !bars) { defaults.set("text", forKey: SubtitleStyle.backgroundKey) }
        ]))
        let opacityMenu = Self.submenu("底色不透明度", [0.3, 0.5, 0.7, 0.9].map { value in
            SubtitleMenuItem("\(Int(value * 100))%", checked: abs(opacity - value) < 0.05) { defaults.set(value, forKey: SubtitleStyle.opacityKey) }
        })
        opacityMenu.isEnabled = bars
        menu.addItem(opacityMenu)
        menu.addItem(SubtitleMenuItem("显示译文", checked: translation) { defaults.set(!translation, forKey: SubtitleStyle.translationKey) })
        menu.addItem(.separator())
        menu.addItem(SubtitleMenuItem("回到默认位置") { [weak self] in self?.resetPosition() })
        menu.addItem(SubtitleMenuItem("关闭字幕") { [weak self] in self?.model?.setSubtitleMode(false) })
        return menu
    }
    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(); submenu.autoenablesItems = false
        for child in items { submenu.addItem(child) }
        item.submenu = submenu
        return item
    }
}

private final class SubtitleMenuItem: NSMenuItem {
    private var handler: (() -> Void)?
    convenience init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: "")
        self.handler = handler
        target = self
        state = checked ? .on : .off
    }
    @objc private func run() { handler?() }
}

/// Covers the subtitle text: dragging moves the panel, right-click opens the style menu.
private struct SubtitleDragArea: NSViewRepresentable {
    let menu: () -> NSMenu
    final class DragView: NSView {
        var provider: (() -> NSMenu)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeKey(); window?.performDrag(with: event) }
        override func menu(for event: NSEvent) -> NSMenu? { provider?() }
    }
    func makeNSView(context: Context) -> DragView { let view = DragView(); view.provider = menu; return view }
    func updateNSView(_ nsView: DragView, context: Context) { nsView.provider = menu }
}

private struct SubtitleSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Wraps text the way CoreText (and so SwiftUI's system font) breaks it, keeping the newest lines like live captions.
enum SubtitleLayout {
    private struct Key: Hashable { let text: String; let size: Double; let width: CGFloat; let lines: Int }
    private static var cache: [Key: [String]] = [:]

    static func lineWidth(fontSize: Double) -> CGFloat {
        let screen = NSScreen.main?.visibleFrame.width ?? 1440
        return max(240, min(screen - 120, CGFloat(fontSize) * 34))
    }
    static func tail(of raw: String, fontSize: Double, width: CGFloat, lines limit: Int) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, limit > 0 else { return [] }
        // The view re-renders on every audio level update; wrap each distinct text once.
        let key = Key(text: text, size: fontSize, width: width, lines: limit)
        if let cached = cache[key] { return cached }
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .medium)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let setter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 1_000_000), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        let source = text as NSString
        let lines = (CTFrameGetLines(frame) as? [CTLine] ?? []).map { line -> String in
            let range = CTLineGetStringRange(line)
            return source.substring(with: NSRange(location: range.location, length: range.length)).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let result = lines.isEmpty ? [text] : Array(lines.suffix(limit))
        if cache.count > 16 { cache.removeAll() }
        cache[key] = result
        return result
    }
    /// Latin text needs a space between the finished sentence and the one being recognised; CJK does not.
    static func join(_ finished: String, _ partial: String) -> String {
        guard let last = finished.unicodeScalars.last, let first = partial.unicodeScalars.first else { return finished + partial }
        func latin(_ scalar: Unicode.Scalar) -> Bool { scalar.isASCII && !CharacterSet.whitespacesAndNewlines.contains(scalar) }
        return latin(last) && latin(first) ? finished + " " + partial : finished + partial
    }
}

struct SubtitleView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stage: SubtitleStage
    let onSize: (CGSize) -> Void
    let menu: () -> NSMenu
    @AppStorage(SubtitleStyle.fontSizeKey) private var fontSize = SubtitleStyle.defaultFontSize
    @AppStorage(SubtitleStyle.opacityKey) private var opacity = SubtitleStyle.defaultOpacity
    @AppStorage(SubtitleStyle.translationKey) private var showTranslation = true
    @AppStorage(SubtitleStyle.backgroundKey) private var background = "box"
    @AppStorage(SubtitleStyle.linesKey) private var maxLines = SubtitleStyle.defaultLines

    /// The newest finished sentence followed by the one being recognised, so captions roll forward without jumps.
    private var sourceText: String {
        let finished = model.finalText.last?.text ?? ""
        if model.partial.isEmpty { return finished }
        return finished.isEmpty ? model.partial : SubtitleLayout.join(finished, model.partial)
    }

    var body: some View {
        let width = SubtitleLayout.lineWidth(fontSize: fontSize)
        let translationSize = fontSize * SubtitleStyle.translationScale
        let source = SubtitleLayout.tail(of: sourceText, fontSize: fontSize, width: width, lines: maxLines)
        let translation = showTranslation ? SubtitleLayout.tail(of: model.finalText.last?.translation ?? "", fontSize: translationSize, width: width, lines: maxLines) : []
        VStack(spacing: 4) {
            if stage.hint {
                Text("方向键移动 · ⇧ 加速 · ⌥ 微调 · 右键调整样式")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 2)
            }
            if source.isEmpty && translation.isEmpty {
                line(model.recording ? "正在聆听…" : "开始转写后，字幕将显示在这里", size: fontSize * 0.75, color: .white.opacity(0.75))
            }
            ForEach(Array(source.enumerated()), id: \.offset) { line($0.element, size: fontSize, color: .white) }
            ForEach(Array(translation.enumerated()), id: \.offset) { line($0.element, size: translationSize, color: Color(red: 0.65, green: 0.88, blue: 1)) }
        }
        .padding(8)
        // Nearly invisible fill: keeps the gaps between lines draggable instead of clicking through.
        .background(Color.black.opacity(0.01))
        .overlay {
            if stage.hint { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
        }
        .overlay(SubtitleDragArea(menu: menu))
        .fixedSize()
        .background(GeometryReader { proxy in Color.clear.preference(key: SubtitleSizeKey.self, value: proxy.size) })
        .onPreferenceChange(SubtitleSizeKey.self) { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("声笺字幕")
    }

    /// One caption line: YouTube-style bar behind the text, or text alone with a shadow for contrast.
    private func line(_ text: String, size: Double, color: Color) -> some View {
        let bars = background == "box"
        return Text(text)
            .font(.system(size: size, weight: .medium)).foregroundStyle(color)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, size * 0.35).padding(.vertical, size * 0.06)
            .background { if bars { RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(opacity)) } }
            .shadow(color: bars ? .clear : .black.opacity(0.95), radius: 1.5)
            .shadow(color: bars ? .clear : .black.opacity(0.75), radius: 4)
    }
}
