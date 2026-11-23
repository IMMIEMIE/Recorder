import SwiftUI

private enum TranscriptTarget { case end }

private struct TranscriptPosition: Equatable {
    let top: CGFloat
    let bottomGap: CGFloat
}

/// Keep the backing array visible to SwiftUI diffing, including same-ID changes to the row value.
private struct TranscriptRows: RandomAccessCollection {
    struct Element: Identifiable {
        let item: Transcript
        let startsSegment: Bool
        var id: String { item.id }
    }

    let items: [Transcript]
    var startIndex: Int { items.startIndex }
    var endIndex: Int { items.endIndex }
    subscript(index: Int) -> Element {
        let item = items[index]
        return Element(item: item, startsSegment: index > 0 && item.segment != items[index - 1].segment)
    }
}

struct TranscriptList: View {
    @ObservedObject var model: AppModel
    let accent: Color
    @State private var followLatest = true
    @State private var newBelow = false

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    rows.padding(30)
                        .background(GeometryReader { content in
                            let frame = content.frame(in: .named("transcript"))
                            let position = TranscriptPosition(top: frame.minY, bottomGap: frame.maxY - viewport.size.height)
                            Color.clear.onChange(of: position, initial: true) { previous, current in
                                if current.bottomGap <= 48 {
                                    followLatest = true
                                    newBelow = false
                                } else if abs(current.top - previous.top) > 0.5 {
                                    followLatest = false
                                }
                            }
                        })
                }
                .coordinateSpace(name: "transcript")
                .onChange(of: model.partial) { _, _ in keepLatest(proxy) }
                .onChange(of: model.finalText.count) { _, _ in keepLatest(proxy) }
                .onChange(of: model.translationTick) { _, _ in keepLatest(proxy) }
                .onChange(of: model.viewedSession?.id ?? model.activeSessionID) { _, _ in
                    jumpToLatest(proxy)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followLatest {
                        Button { jumpToLatest(proxy) } label: {
                            Label(newBelow ? "有新内容" : "回到底部", systemImage: "arrow.down")
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(accent)
                        .keyboardShortcut(.downArrow, modifiers: .command)
                        .help("回到最新文字，并恢复自动跟随（⌘↓）")
                        .padding(.trailing, 28).padding(.bottom, 16)
                    }
                }
            }
        }
    }

    private var rows: some View {
        let items = model.displayedTranscripts
        return LazyVStack(alignment: .leading, spacing: 24) {
            if items.isEmpty && (model.partial.isEmpty || model.viewedSession != nil) {
                VStack(spacing: 18) {
                    Image(systemName: "waveform.circle").font(.system(size: 62, weight: .ultraLight)).foregroundStyle(accent.opacity(0.55))
                    Text(model.viewedSession != nil ? "此会话没有文字" : model.recording ? "正在聆听…" : "点击开始转写").font(.system(size: 15)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 80)
            }
            ForEach(TranscriptRows(items: items)) { row in
                let item = row.item
                VStack(alignment: .leading, spacing: 24) {
                    if row.startsSegment {
                        SessionMarker(text: "继续录制" + (model.segmentStart(item.segment).map { " " + SessionExport.stamp($0, zone: .current) } ?? ""))
                    }
                    if item.isBreak {
                        SessionMarker(text: SessionExport.breakMarker)
                    } else {
                        transcriptLine(item)
                    }
                }
            }
            if !model.partial.isEmpty && model.viewedSession == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("识别中").font(.caption2).foregroundStyle(accent)
                    Text(model.partial).font(.system(size: 17)).lineSpacing(7).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            Color.clear.frame(height: 1).id(TranscriptTarget.end)
        }
    }

    private func transcriptLine(_ item: Transcript) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(String(format: "%02d:%02d", Int(item.seconds) / 60, Int(item.seconds) % 60)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 38).padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                if item.incomplete { Text("此段内容可能不完整").font(.caption2).foregroundStyle(.orange) }
                else if !item.sourceDone { Text("识别中…").font(.caption2).foregroundStyle(.secondary) }
                // Refresh the selectable AppKit text when a revision replaces its contents.
                // The surrounding transcript row retains its ID and scroll position.
                if !item.text.isEmpty {
                    Text(item.text).font(.system(size: 17)).lineSpacing(7).textSelection(.enabled).id(item.text)
                }
                let translation = item.translation
                if !translation.isEmpty {
                    Text(translation).font(.system(size: 15)).lineSpacing(5).foregroundStyle(.secondary).textSelection(.enabled).id(translation)
                } else if item.translating {
                    Text("翻译中…").font(.caption).foregroundStyle(.tertiary)
                }
                if model.canReplay(item) {
                    HStack {
                        Spacer()
                        Button { model.replay(item) } label: {
                            Label(model.replayingTranscriptID == item.id ? "停止" : "播放译音",
                                  systemImage: model.replayingTranscriptID == item.id ? "stop.fill" : "play.fill")
                        }.buttonStyle(.borderless).font(.caption)
                            .help("重播此段译音；停止本次自动译音，字幕继续更新")
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keepLatest(_ proxy: ScrollViewProxy) {
        guard model.viewedSession == nil else { return }
        if followLatest {
            proxy.scrollTo(TranscriptTarget.end, anchor: .bottom)
        } else if !model.finalText.isEmpty || !model.partial.isEmpty {
            newBelow = true
        }
    }

    private func jumpToLatest(_ proxy: ScrollViewProxy) {
        followLatest = true
        newBelow = false
        proxy.scrollTo(TranscriptTarget.end, anchor: .bottom)
    }
}
