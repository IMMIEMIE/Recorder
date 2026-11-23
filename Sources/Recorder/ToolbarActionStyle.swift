import SwiftUI

/// Only the transcript toolbar uses this style. Button retains keyboard,
/// accessibility, focus and activation semantics.
struct ToolbarActionStyle: ButtonStyle {
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
