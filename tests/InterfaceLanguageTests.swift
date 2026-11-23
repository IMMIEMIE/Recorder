import SwiftUI

@main
struct InterfaceLanguageTests {
    @MainActor static func main() {
        let names = ["fr-FR", "zh-CN", "en-GB"]
        precondition(InterfaceLanguage.system.locale(preferredLanguages: names).identifier == "zh-Hans")
        precondition(InterfaceLanguage.system.locale(preferredLanguages: ["en-AU", "zh-CN"]).identifier == "en")
        precondition(InterfaceLanguage.system.locale(preferredLanguages: ["ko-KR"]).identifier == "en")
        precondition(InterfaceLanguage.english.locale(preferredLanguages: names).identifier == "en")

        let suite = "test.interface-language.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let liveConfig = Data(#"{"language":"ja","enabled":true}"#.utf8)
        defaults.set(liveConfig, forKey: "livetranslate.configuration.v1")
        defaults.set("日本語", forKey: "ai.targetLanguage")
        let settings = InterfaceLanguageSettings(defaults: defaults)
        precondition(settings.selection == .system)
        for (choice, settingsLabel) in [(InterfaceLanguage.english, "Settings"), (.simplifiedChinese, "设置")] {
            settings.selection = choice
            let restored = InterfaceLanguageSettings(defaults: defaults)
            precondition(restored.selection == choice && restored.string("设置") == settingsLabel)
            // Render the same kind of localized literal used by controls in the shipped app.
            precondition(snapshot(Text("设置"), locale: restored.locale) ==
                         snapshot(Text(verbatim: settingsLabel), locale: restored.locale))
            let reasoningStatus = "服务正在推理…"
            let expectedStatus = choice == .english ? "The service is reasoning…" : reasoningStatus
            precondition(snapshot(Text(LocalizedStringKey(reasoningStatus)), locale: restored.locale) ==
                         snapshot(Text(verbatim: expectedStatus), locale: restored.locale))
            let typedTitle = "开始转写"
            precondition(snapshot(Text(typedTitle), locale: restored.locale) ==
                         snapshot(Text(verbatim: typedTitle), locale: restored.locale))
        }
        settings.selection = .system
        precondition(InterfaceLanguageSettings(defaults: defaults).selection == .system)
        precondition(defaults.data(forKey: "livetranslate.configuration.v1") == liveConfig)
        precondition(defaults.string(forKey: "ai.targetLanguage") == "日本語")
        defaults.set("unknown", forKey: InterfaceLanguage.preferenceKey)
        precondition(InterfaceLanguageSettings(defaults: defaults).selection == .system)
        print("Interface language selection, persistence and localized SwiftUI rendering passed.")
    }

    @MainActor static func snapshot(_ text: Text, locale: Locale) -> Data {
        let renderer = ImageRenderer(content: text.font(.body).foregroundStyle(.black)
            .padding(4).background(.white).environment(\.locale, locale))
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fatalError("Could not render localized text")
        }
        return png
    }
}
