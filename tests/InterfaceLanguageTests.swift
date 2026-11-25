import SwiftUI

@main
struct InterfaceLanguageTests {
    @MainActor static func main() {
        // 1. System preferred language matching, priority order, and Chinese script/region rules.
        let names = ["fr-FR", "zh-CN", "en-GB"]
        precondition(InterfaceLanguage.system.locale(preferredLanguages: names).identifier == "fr")
        precondition(InterfaceLanguage.system.locale(preferredLanguages: ["ar-SA", "de-DE", "zh-CN"]).identifier == "de")
        precondition(InterfaceLanguage.system.locale(preferredLanguages: ["en-AU", "zh-CN"]).identifier == "en")
        precondition(InterfaceLanguage.system.locale(preferredLanguages: ["ko-KR"]).identifier == "ko")
        precondition(InterfaceLanguage.system.locale(preferredLanguages: ["ja-JP"]).identifier == "ja")
        precondition(InterfaceLanguage.system.locale(preferredLanguages: ["es-MX"]).identifier == "es")
        precondition(InterfaceLanguage.system.locale(preferredLanguages: ["ta-IN"]).identifier == "ta")

        // Strict Simplified vs Traditional Chinese distinction.
        for hant in ["zh-Hant", "zh-Hant-TW", "zh-Hant-HK", "zh-TW", "zh-HK", "zh-MO", "zh_TW"] {
            precondition(
                InterfaceLanguage.system.locale(preferredLanguages: [hant]).identifier == "zh-Hant",
                "Expected zh-Hant for \(hant)"
            )
        }
        for hans in ["zh-Hans", "zh-Hans-CN", "zh-Hans-SG", "zh-CN", "zh-SG", "zh", "zh_CN"] {
            precondition(
                InterfaceLanguage.system.locale(preferredLanguages: [hans]).identifier == "zh-Hans",
                "Expected zh-Hans for \(hans)"
            )
        }

        // Unsupported languages fall back to English.
        for unsupported in [["ar-SA"], ["vi-VN", "th-TH"], ["pt-BR"], []] {
            precondition(
                InterfaceLanguage.system.locale(preferredLanguages: unsupported).identifier == "en",
                "Expected en fallback for \(unsupported)"
            )
        }

        // Explicit choice overrides system list.
        precondition(InterfaceLanguage.english.locale(preferredLanguages: names).identifier == "en")
        precondition(InterfaceLanguage.tamil.locale(preferredLanguages: names).identifier == "ta")
        precondition(InterfaceLanguage.supported.count == 9)

        // Endonyms stay fixed across all concrete languages.
        let expectedEndonyms: [(InterfaceLanguage, String)] = [
            (.simplifiedChinese, "简体中文"),
            (.english, "English"),
            (.traditionalChinese, "繁體中文"),
            (.japanese, "日本語"),
            (.korean, "한국어"),
            (.spanish, "Español"),
            (.french, "Français"),
            (.german, "Deutsch"),
            (.tamil, "தமிழ்"),
        ]
        for (lang, endonym) in expectedEndonyms {
            precondition(lang.nativeName == endonym)
        }
        precondition(InterfaceLanguage.system.nativeName == nil)

        // 2. Switching, persistence, isolation from translation/AI config, and SwiftUI rendering.
        let suite = "test.interface-language.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let liveConfig = Data(#"{"language":"ja","enabled":true}"#.utf8)
        defaults.set(liveConfig, forKey: "livetranslate.configuration.v1")
        defaults.set("日本語", forKey: "ai.targetLanguage")

        let settings = InterfaceLanguageSettings(defaults: defaults)
        precondition(settings.selection == .system)

        let expectedSettingsTitles: [(InterfaceLanguage, String)] = [
            (.simplifiedChinese, "设置"),
            (.english, "Settings"),
            (.traditionalChinese, "設定"),
            (.japanese, "設定"),
            (.korean, "설정"),
            (.spanish, "Ajustes"),
            (.french, "Paramètres"),
            (.german, "Einstellungen"),
            (.tamil, "அமைப்புகள்"),
        ]
        for (choice, settingsLabel) in expectedSettingsTitles {
            settings.selection = choice
            let restored = InterfaceLanguageSettings(defaults: defaults)
            precondition(restored.selection == choice)
            precondition(restored.string("设置") == settingsLabel, "Mismatch for \(choice.rawValue): \(restored.string("设置"))")
            // Verify SwiftUI Text literal lookup matches the resolved locale (including CJK language-tagged glyph shaping).
            var expectedAttr = AttributedString(settingsLabel)
            expectedAttr.languageIdentifier = choice.rawValue
            precondition(
                snapshot(Text("设置"), locale: restored.locale) == snapshot(Text(expectedAttr), locale: restored.locale),
                "Localized Text snapshot mismatch for \(choice.rawValue)"
            )
            var followAttr = AttributedString(restored.string("跟随系统"))
            followAttr.languageIdentifier = choice.rawValue
            precondition(
                snapshot(Text("跟随系统"), locale: restored.locale) == snapshot(Text(followAttr), locale: restored.locale),
                "Localized Follow System snapshot mismatch for \(choice.rawValue)"
            )

            // Verify static and parameterized runtime message localization across all 9 languages.
            let staticErr = restored.localizeMessage("请在系统设置中允许麦克风访问")
            precondition(!staticErr.isEmpty)
            if choice != .simplifiedChinese {
                precondition(staticErr != "请在系统设置中允许麦克风访问", "Expected localized error for \(choice.rawValue)")
            }

            let nestedErr = restored.localizeMessage(
                "识别处理失败 (ValueError): 离线资源缺失: config.json。已确认文字仍保留，可重新加载识别服务恢复。"
            )
            precondition(nestedErr.contains("ValueError") && nestedErr.contains("config.json"))
            if choice != .simplifiedChinese {
                precondition(!nestedErr.contains("识别处理失败") && !nestedErr.contains("离线资源缺失"),
                             "Untranslated fragment in \(choice.rawValue): \(nestedErr)")
            }

            let sizeErr = restored.localizeMessage(
                "文件大小校验失败：weights.safetensors 应为 100 字节，实际 50 字节（多为网络中断，可重试）"
            )
            precondition(sizeErr.contains("weights.safetensors") && sizeErr.contains("100") && sizeErr.contains("50"))
            if choice != .simplifiedChinese {
                precondition(!sizeErr.contains("文件大小校验失败"), "Untranslated size error in \(choice.rawValue): \(sizeErr)")
            }

            let httpErr = restored.localizeMessage("API Key 无效或无权访问该模型（HTTP 401）")
            precondition(httpErr.contains("401"))
            if choice != .simplifiedChinese {
                precondition(!httpErr.contains("API Key 无效或无权访问该模型"), "Untranslated HTTP error in \(choice.rawValue): \(httpErr)")
            }
        }

        // Verify plain String variables do not trigger implicit SwiftUI lookup (which is why UI uses localizeMessage / LocalizedStringKey).
        settings.selection = .english
        let reasoningStatus = "服务正在推理…"
        precondition(snapshot(Text(LocalizedStringKey(reasoningStatus)), locale: settings.locale) ==
                     snapshot(Text(verbatim: "The service is reasoning…"), locale: settings.locale))
        let typedTitle = "开始转写"
        precondition(snapshot(Text(typedTitle), locale: settings.locale) ==
                     snapshot(Text(verbatim: typedTitle), locale: settings.locale))

        // Verify config isolation and unknown stored value fallback.
        settings.selection = .system
        precondition(InterfaceLanguageSettings(defaults: defaults).selection == .system)
        precondition(defaults.data(forKey: "livetranslate.configuration.v1") == liveConfig)
        precondition(defaults.string(forKey: "ai.targetLanguage") == "日本語")
        defaults.set("unknown", forKey: InterfaceLanguage.preferenceKey)
        precondition(InterfaceLanguageSettings(defaults: defaults).selection == .system)
        print("Interface language selection (9 languages), Chinese script matching, runtime message localization, persistence and SwiftUI rendering passed.")
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
