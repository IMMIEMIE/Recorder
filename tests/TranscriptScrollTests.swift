import AppKit
import SwiftUI

@main @MainActor
struct TranscriptScrollTests {
    static func fixture(_ count: Int, title: String) -> SessionFile {
        let start: Int64 = 1_700_000_000_000
        let segments = (0...count / 250).map {
            SessionFile.Segment(startedAtMs: start + Int64($0) * 750_000, targetLanguage: "en", mode: "local_asr")
        }
        let rows = (0..<count).map { i in
            SessionFile.Row(segment: i / 250, kind: i % 113 == 112 ? .break : .text, offsetMs: Int64(i * 3000),
                            source: "\(title) \(i) " + String(repeating: "一段示例文字。", count: 1 + i % 4),
                            translation: "Translation \(i) " + String(repeating: "another phrase ", count: 1 + i % 7))
        }
        return SessionFile(id: SessionFile.newID(), title: title, titleEdited: true, createdAtMs: start,
                           updatedAtMs: start, segments: segments, rows: rows)
    }

    static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    static func settle(_ seconds: TimeInterval = 0.12) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    static func ms(_ work: () -> Void) -> Double {
        let start = CACurrentMediaTime()
        work()
        return (CACurrentMediaTime() - start) * 1000
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let count = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 1500
        precondition(count >= 500)
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, integrateSystem: false)
        settle()
        let live = fixture(count, title: "Live")
        let history = fixture(count, title: "History")
        try model.sessionLibrary.save(live)
        try model.sessionLibrary.save(history)
        model.installActiveSession(live)
        model.state = "recording"

        let frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: MainView(model: model))
        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        let opening = ms {
            host.frame = frame
            window.contentView = host
            window.orderBack(nil)
            layout()
        }
        settle()
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        guard let scroll = scrolls.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let document = scroll.documentView else { fatalError("Transcript scroll view missing") }
        let clip = scroll.contentView
        func scrollTo(_ y: CGFloat) {
            clip.scroll(to: NSPoint(x: 0, y: min(y, document.frame.height - clip.bounds.height)))
            scroll.reflectScrolledClipView(clip)
            layout()
            settle()
        }
        scrollTo(document.frame.height)
        scrollTo(max(1, document.frame.height / 2))
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 350, wheel2: 0, wheel3: 0)!
        let scrollStart = clip.bounds.minY
        let scrollSteps = (1...20).map { step in ms {
            clip.scroll(to: NSPoint(x: 0, y: scrollStart - CGFloat(step * 120)))
            scroll.reflectScrolledClipView(clip)
            layout()
        } }
        scroll.scrollWheel(with: NSEvent(cgEvent: event)!)
        settle()
        precondition(clip.bounds.minY < scrollStart, "Viewport did not scroll")
        func visibleLines() -> [(text: String, y: CGFloat)] {
            descendants(document).compactMap { view in
                guard let text = view.accessibilityValue() as? String else { return nil }
                let rect = clip.convert(view.bounds, from: view)
                guard clip.bounds.contains(rect) else { return nil }
                return (text, rect.minY - clip.bounds.minY)
            }.sorted { $0.y < $1.y }
        }
        func anchor(_ title: String) -> (text: String, y: CGFloat) {
            visibleLines().first { $0.text.hasPrefix(title + " ") }!
        }
        func drift(from anchor: (text: String, y: CGFloat)) -> CGFloat {
            guard let match = visibleLines().first(where: { $0.text == anchor.text }) else { return .infinity }
            return abs(match.y - anchor.y)
        }
        func shows(_ text: String) -> Bool { visibleLines().contains { $0.text == text } }
        let liveAnchor = anchor("Live")
        var updates: [Double] = []
        for tick in 1...20 {
            updates.append(ms {
                model.level = Float(tick) / 20
                model.partial = "Partial \(tick)"
                model.finalText[count - 1].translations[-1] = TranslationPart(text: "Revised \(tick)", revision: tick, done: false)
                model.translationTick += 1
                layout()
            })
        }
        model.finalText.append(Transcript(id: "new-tail", text: "New tail", seconds: 9999))
        layout()
        settle()
        let liveDrift = drift(from: liveAnchor)
        let viewCount = descendants(document).count
        let openHistory = ms { model.selectSession(history.id); layout() }
        settle()
        scrollTo(document.frame.height / 3)
        let historyAnchor = anchor("History")
        let reads = ms {
            var total = 0
            for _ in 0..<100 { total += model.displayedTranscripts.count }
            precondition(total == count * 100)
        }
        model.partial = "Hidden live partial"
        model.finalText.append(Transcript(id: "hidden", text: "Hidden live final", seconds: 10_000))
        model.translationTick += 1
        layout()
        settle()
        let historyDrift = drift(from: historyAnchor)
        precondition(model.displayedTranscripts.last?.text == history.rows.last?.source)
        print(String(format: "rows=%d open_ms=%.1f native_views=%d scroll_step_median_ms=%.2f update_median_ms=%.2f history_open_ms=%.1f history_reads_100_ms=%.2f live_drift_pt=%.1f history_drift_pt=%.1f",
                     count, opening, viewCount, scrollSteps.sorted()[scrollSteps.count / 2], updates.sorted()[updates.count / 2], openHistory, reads, liveDrift, historyDrift))
        fflush(stdout)
        if CommandLine.arguments.contains("--measure-only") { return }
        precondition(liveDrift <= 2 && historyDrift <= 2, "Detached reading position moved")
        precondition(viewCount < count / 2, "Offscreen rows still own native views")
        var revisedHistory = history
        let historicalRow = revisedHistory.rows.firstIndex { $0.source == historyAnchor.text }!
        revisedHistory.rows[historicalRow].translation = "Late history translation"
        try model.sessionLibrary.save(revisedHistory)
        model.selectSession(history.id)
        layout()
        settle()
        precondition(shows("Late history translation") && drift(from: historyAnchor) <= 2, "Historical update lost its anchor")
        model.selectSession(live.id)
        layout()
        settle()
        precondition(shows("Hidden live final"), "Switching back did not reveal the active tail")
        scrollTo(document.frame.height / 2)
        let beforeEdit = anchor("Live")
        let visibleSource = visibleLines().filter { $0.text.hasPrefix("Live ") }[1].text
        let visibleIndex = model.finalText.firstIndex { $0.text == visibleSource }!
        model.finalText[visibleIndex].text = "Updated source"
        model.finalText[visibleIndex].translations = [1: TranslationPart(text: "In-place translation", revision: 3, done: true)]
        model.translationTick += 1
        layout()
        settle()
        precondition(shows("Updated source") && shows("In-place translation"), "Visible row did not update")
        precondition(drift(from: beforeEdit) <= 2, "Updating a visible row moved its neighbor")
        model.finalText.insert(Transcript(id: "late", text: "Late sentence", seconds: 10), at: visibleIndex - 8)
        layout()
        settle()
        precondition(drift(from: beforeEdit) <= 2, "Late sentence inserted above the viewport moved its anchor")
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .function, .numericPad],
                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                   characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)!
        precondition(window.performKeyEquivalent(with: key), "Jump shortcut was unavailable")
        settle(0.75)
        precondition(shows("Hidden live final"), "Jump did not reach the latest row")
        model.finalText.append(Transcript(id: "after-jump", text: "Following again", seconds: 10_010))
        layout()
        settle()
        precondition(shows("Following again"), "Appends stopped following after jump")
        model.partial = String(repeating: "A wrapping partial line. ", count: 35)
        layout()
        settle()
        precondition(document.frame.height - clip.bounds.maxY <= 48, "Wrapping partial lost bottom follow")
        print("transcript scroll checks passed")
        window.orderOut(nil)
    }
}
