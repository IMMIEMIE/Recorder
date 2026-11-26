import SwiftUI

struct TranslationMenu: View, Equatable {
    private enum Mode: Equatable {
        case standard(target: String, enabled: Bool, busy: Bool)
        case live(language: String)

        var title: LocalizedStringKey {
            switch self {
            case let .standard(target, enabled, _): return enabled ? "译为\(target)" : "翻译"
            case let .live(language): return "译为\(language)"
            }
        }
    }

    // MainView applies the tooltip outside the equatable menu. Interpolated localized
    // Text can compare unequal on every audio tick even when the help reads the same.
    private let mode: Mode
    private let model: AppModel
    private let localeIdentifier: String

    init(model: AppModel) {
        self.model = model
        self.localeIdentifier = InterfaceLanguageSettings.shared.locale.identifier
        mode = model.liveEnabled
            ? .live(language: model.liveConfiguration.languageName)
            : .standard(target: model.translationTarget, enabled: model.translationEnabled, busy: model.translatorBusy)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.mode == rhs.mode && lhs.localeIdentifier == rhs.localeIdentifier
    }

    var body: some View {
        Menu {
            switch mode {
            case let .standard(target, enabled, busy):
                Toggle("实时翻译", isOn: Binding(get: { enabled }, set: model.setTranslation(enabled:)))
                    .disabled(busy)
                Section("翻译为") {
                    Picker("翻译为", selection: Binding(get: { target }, set: model.setTranslationTarget)) {
                        ForEach(AppModel.translationTargets, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            case let .live(language):
                Text("LiveTranslate → \(language)")
            }
            Divider()
            SettingsLink { Text("翻译设置…") }
        } label: {
            // The transcript toolbar supplies `.menuStyle(.button)` + `ToolbarActionStyle`, so this
            // menu matches the buttons beside it; that style draws no indicator, hence the chevron.
            HStack(spacing: DesignTokens.spaceXs) {
                Label(mode.title, systemImage: "character.bubble")
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).accessibilityHidden(true)
            }
        }
        .fixedSize()
    }
}
