import SwiftUI
import AppKit

private final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SubtitleWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(model: AppModel, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: visible.midX - 380, y: visible.minY + 70, width: 760, height: 240)
        let panel = SubtitlePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.title = "声笺字幕"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 160)
        panel.contentView = NSHostingView(rootView: SubtitleView(model: model))
        super.init(window: panel)
        panel.delegate = self
        panel.setFrameAutosaveName("RecorderSubtitleWindow")
        panel.setFrameUsingName("RecorderSubtitleWindow")
        // A disconnected display must not leave the subtitles unreachable.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersection(panel.frame).width >= 120 && $0.visibleFrame.intersection(panel.frame).height >= 60 }) {
            panel.setFrame(frame, display: false)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() { window?.makeKeyAndOrderFront(nil) }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// A dedicated drag area works even when the hosting view consumes background mouse events.
private struct SubtitleDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

struct SubtitleView: View {
    @ObservedObject var model: AppModel
    @AppStorage("subtitle.fontSize") private var fontSize = 24.0
    @AppStorage("subtitle.opacity") private var opacity = 0.72
    @AppStorage("subtitle.showTranslation") private var showTranslation = true
    @State private var settings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "captions.bubble")
                    Text("声笺字幕").fontWeight(.medium)
                    Circle().fill(model.recording ? Color.green : Color.white.opacity(0.5)).frame(width: 5, height: 5)
                    Text(model.statusTitle).foregroundStyle(.white.opacity(0.65))
                    Spacer(minLength: 0)
                }.overlay(SubtitleDragArea()).help("拖动此处移动字幕窗口")
                Button { settings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("字幕样式").accessibilityLabel("字幕样式")
                    .popover(isPresented: $settings) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("字幕样式").font(.headline)
                            Text("字号：\(Int(fontSize))")
                            Slider(value: $fontSize, in: 16...40, step: 1).accessibilityLabel("字幕字号")
                            Text("背景不透明度：\(Int(opacity * 100))%")
                            Slider(value: $opacity, in: 0.25...0.95, step: 0.05).accessibilityLabel("背景不透明度")
                            Toggle("显示译文", isOn: $showTranslation)
                            Text("拖动顶部移动窗口，拖动边缘调整大小。样式和窗口位置会自动保存。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(20).frame(width: 290)
                    }
                Button { model.setSubtitleMode(false) } label: { Image(systemName: "xmark") }
                    .help("关闭字幕窗口，继续转写").accessibilityLabel("关闭字幕窗口")
            }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 18).padding(.vertical, 12)
            Divider().overlay(.white.opacity(0.12))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let latest = model.finalText.last {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(latest.text).foregroundStyle(.white)
                                if showTranslation && !latest.translation.isEmpty {
                                    Text(latest.translation).foregroundStyle(Color(red: 0.65, green: 0.88, blue: 1))
                                } else if showTranslation && latest.translating {
                                    Text("翻译中…").font(.system(size: 14)).foregroundStyle(.white.opacity(0.55))
                                }
                            }
                        }
                        if !model.partial.isEmpty {
                            Text(model.partial).foregroundStyle(.white.opacity(0.65))
                        }
                        if model.finalText.isEmpty && model.partial.isEmpty {
                            Text(model.recording ? "正在聆听…" : "开始转写后，字幕将显示在这里")
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Color.clear.frame(height: 1).id("subtitle-end")
                    }.font(.system(size: fontSize, weight: .medium)).lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                .onChange(of: model.partial) { _, _ in proxy.scrollTo("subtitle-end", anchor: .bottom) }
                .onChange(of: model.finalText.count) { _, _ in proxy.scrollTo("subtitle-end", anchor: .bottom) }
                .onChange(of: model.translationTick) { _, _ in proxy.scrollTo("subtitle-end", anchor: .bottom) }
            }
        }.background(.black.opacity(opacity), in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15), lineWidth: 1))
            .preferredColorScheme(.dark)
    }
}
