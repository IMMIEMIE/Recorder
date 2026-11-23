import SwiftUI

/// Foundation parses CommonMark and supplies block identities even for nested lists.
struct AIAnswerBlock: Identifiable {
    enum Style: Equatable {
        case paragraph, heading(Int), code, divider, tableRow(header: Bool)
    }
    let id: Int
    var style: Style = .paragraph
    var text = AttributedString()
    var listDepth = 0
    var marker: String?
    var quoted = false
    var cells: [AttributedString] = []

    static func parse(_ markdown: String) -> [Self] {
        guard let document = try? AttributedString(markdown: markdown,
            options: .init(allowsExtendedAttributes: false, failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return [Self(id: 0, text: AttributedString(markdown))]
        }
        var blocks: [Self] = []
        var seenItems = Set<Int>()
        for (intent, range) in document.runs[\.presentationIntent] {
            let components = intent?.components ?? []
            let text = inlineText(document[range])
            var block = Self(id: components.first?.identity ?? 0, text: text)
            var item: (id: Int, number: Int)?
            var column: Int?
            var row: (id: Int, header: Bool)?
            for component in components {
                switch component.kind {
                case .paragraph: break
                case let .header(level): block.style = .heading(level)
                case .codeBlock: block.style = .code
                case .thematicBreak: block.style = .divider
                case .blockQuote: block.quoted = true
                case let .listItem(ordinal):
                    if item == nil { item = (component.identity, ordinal) }
                case .orderedList, .unorderedList:
                    block.listDepth += 1
                    if block.listDepth == 1, let item, seenItems.insert(item.id).inserted {
                        block.marker = component.kind == .orderedList ? "\(item.number)." : "•"
                    }
                case let .tableCell(index): column = index
                case .tableHeaderRow: row = (component.identity, true)
                case .tableRow: row = (component.identity, false)
                case let .table(columns):
                    if let row, let column, columns.indices.contains(column) {
                        if blocks.last?.id != row.id {
                            blocks.append(Self(id: row.id, style: .tableRow(header: row.header),
                                               cells: Array(repeating: AttributedString(), count: columns.count)))
                        }
                        blocks[blocks.count - 1].cells[column] = text
                    }
                @unknown default: break
                }
            }
            if row == nil { blocks.append(block) }
        }
        return blocks
    }

    private static func inlineText(_ source: AttributedSubstring) -> AttributedString {
        var result = AttributedString()
        for run in source.runs {
            // Whitelist formatting. Remote images become alt text. HTML stays inert.
            var span = AttributedString(String(source[run.range].characters))
            span.inlinePresentationIntent = run.inlinePresentationIntent
            if let url = run.link, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
               url.host != nil, url.user == nil, url.password == nil {
                span.link = url
            }
            result.append(span)
        }
        return result
    }
}

struct AIAnswerMarkdown: View {
    @ObservedObject var ai: AIWorkspace
    @State private var blocks: [AIAnswerBlock] = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let marker = block.marker { Text(verbatim: marker).foregroundStyle(.secondary) }
                    blockContent(block)
                }
                .padding(.leading, block.quoted ? 10 : 0)
                .overlay(alignment: .leading) {
                    if block.quoted { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3) }
                }
                .padding(.leading, CGFloat(block.listDepth) * 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        // Coalesce tokens into snapshots, including a final pass after stop or failure.
        .task(id: ai.running) {
            var previous: String?
            repeat {
                let source = ai.result
                if previous != source {
                    let parsed = await Task.detached(priority: .userInitiated) { AIAnswerBlock.parse(source) }.value
                    guard !Task.isCancelled else { return }
                    blocks = parsed
                    previous = source
                }
                guard ai.running else { return }
                try? await Task.sleep(for: .milliseconds(160))
            } while !Task.isCancelled
        }
    }

    @ViewBuilder private func blockContent(_ block: AIAnswerBlock) -> some View {
        switch block.style {
        case let .heading(level):
            Text(block.text).font(level == 1 ? .title2 : level == 2 ? .title3 : .headline)
                .fontWeight(.semibold).padding(.top, 5).accessibilityAddTraits(.isHeader)
        case .code:
            Text(block.text).font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case .divider:
            Divider()
        case let .tableRow(header):
            HStack(alignment: .top, spacing: 8) {
                ForEach(block.cells.indices, id: \.self) { index in
                    Text(block.cells[index]).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .fontWeight(header ? .semibold : .regular)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(header ? Color.secondary.opacity(0.12) : .clear)
        case .paragraph:
            Text(block.text).lineSpacing(3)
        }
    }
}
