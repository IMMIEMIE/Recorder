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

    // Snapshot the menu inputs so audio levels, partials and translation tokens can
    // redraw MainView without rebuilding the menu while someone is choosing a language.
    private let mode: Mode
    private let summary: Text
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        mode = model.liveEnabled
            ? .live(language: model.liveConfiguration.languageName)
            : .standard(target: model.translationTarget, enabled: model.translationEnabled, busy: model.translatorBusy)
        summary = Text(model.translationSummary)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.mode == rhs.mode && lhs.summary == rhs.summary
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
            Label(mode.title, systemImage: "character.bubble")
        }
        .fixedSize()
        .help(summary)
    }
}
