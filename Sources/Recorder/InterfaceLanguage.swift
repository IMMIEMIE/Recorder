import SwiftUI

enum InterfaceLanguage: String, CaseIterable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let preferenceKey = "interface.language"

    func locale(preferredLanguages: [String]) -> Locale {
        if self == .system {
            for identifier in preferredLanguages {
                switch Locale(identifier: identifier).language.languageCode?.identifier {
                case "zh": return Locale(identifier: Self.simplifiedChinese.rawValue)
                case "en": return Locale(identifier: Self.english.rawValue)
                default: continue
                }
            }
            return Locale(identifier: Self.english.rawValue)
        }
        return Locale(identifier: rawValue)
    }
}

/// Shared by the SwiftUI scenes and the separately hosted AppKit subtitle panel.
final class InterfaceLanguageSettings: ObservableObject {
    static let shared = InterfaceLanguageSettings()

    @Published var selection: InterfaceLanguage {
        didSet { defaults.set(selection.rawValue, forKey: InterfaceLanguage.preferenceKey) }
    }
    @Published private var preferredLanguages = Locale.preferredLanguages
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: InterfaceLanguage.preferenceKey).flatMap(InterfaceLanguage.init) ?? .system
        NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in Locale.preferredLanguages }.assign(to: &$preferredLanguages)
    }

    var locale: Locale { selection.locale(preferredLanguages: preferredLanguages) }

    /// AppKit titles and other plain strings do not inherit SwiftUI's locale environment.
    func string(_ key: String, in bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: locale.identifier, withExtension: "lproj"),
              let localized = Bundle(url: url) else { return key }
        return localized.localizedString(forKey: key, value: key, table: nil)
    }
}

struct InterfaceLanguagePicker: View {
    @ObservedObject var settings: InterfaceLanguageSettings

    var body: some View {
        Picker("界面语言", selection: $settings.selection) {
            Text("跟随系统").tag(InterfaceLanguage.system)
            Text(verbatim: "English").tag(InterfaceLanguage.english)
            Text(verbatim: "简体中文").tag(InterfaceLanguage.simplifiedChinese)
        }
        .pickerStyle(.segmented)
    }
}
