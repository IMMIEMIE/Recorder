import SwiftUI

/// Only the transcript toolbar uses this style. Button retains keyboard,
/// accessibility, focus and activation semantics. Labels stay on one line and
/// every item, icon-only or not, gets the same height.
struct ToolbarActionStyle: ButtonStyle {
    /// Height of the label area; with the vertical padding every toolbar item is 26 pt tall.
    static let contentHeight: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let pressed = enabled && configuration.isPressed
            let highlighted = enabled && hovering
            let border = enabled ? (highlighted || pressed ? DesignTokens.primary : DesignTokens.outline) : DesignTokens.outlineVariant
            return configuration.label
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: ToolbarActionStyle.contentHeight, minHeight: ToolbarActionStyle.contentHeight)
                .padding(.horizontal, DesignTokens.spaceSm)
                .padding(.vertical, DesignTokens.spaceXs)
                .foregroundStyle(enabled ? (pressed ? DesignTokens.onPrimary : DesignTokens.primary) : DesignTokens.onSurfaceVariant)
                .background {
                    RoundedRectangle(cornerRadius: DesignTokens.radiusInput)
                        .fill(pressed ? DesignTokens.primary : highlighted ? DesignTokens.primaryContainer : DesignTokens.surfaceContainerLow)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.radiusInput)
                        .strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: enabled ? [] : [3, 3]))
                }
                .contentShape(RoundedRectangle(cornerRadius: DesignTokens.radiusInput))
                .onHover { hovering = $0 }
        }
    }
}

/// How much room the transcript toolbar's secondary actions (AI 提问, 导出会话…, 复制) get.
/// `MainView` offers the variants in this order through `ViewThatFits`.
enum ToolbarDensity: CaseIterable {
    /// Icon and text.
    case full
    /// Icon only, with the name as tooltip and accessibility label.
    case compact
    /// Collected into one 「更多操作」 menu.
    case overflow
}

/// Reports at most `cap` as the ideal width of its content, so `ViewThatFits` reserves
/// only that much for a long title before choosing a toolbar variant. With a concrete
/// width proposal the content still takes all the room it is given.
struct IdealWidthCap: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let size = view.sizeThatFits(proposal)
        return proposal.width == nil ? CGSize(width: min(size.width, cap), height: size.height) : size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(bounds.size))
    }
}
