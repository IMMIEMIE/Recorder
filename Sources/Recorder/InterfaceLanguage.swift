import SwiftUI

enum InterfaceLanguage: String, CaseIterable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case tamil = "ta"

    static let preferenceKey = "interface.language"

    /// The 9 supported concrete languages in selector display order.
    static let supported: [InterfaceLanguage] = [
        .simplifiedChinese, .english, .traditionalChinese,
        .japanese, .korean, .spanish, .french, .german, .tamil,
    ]

    /// Fixed endonym shown in the language selector so users can always recover from any language.
    var nativeName: String? {
        switch self {
        case .system: return nil
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .tamil: return "தமிழ்"
        }
    }

    func locale(preferredLanguages: [String]) -> Locale {
        if self == .system {
            for identifier in preferredLanguages {
                if let matched = Self.match(identifier: identifier) {
                    return Locale(identifier: matched.rawValue)
                }
            }
            return Locale(identifier: Self.english.rawValue)
        }
        return Locale(identifier: rawValue)
    }

    private static func match(identifier: String) -> InterfaceLanguage? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map(String.init)
        let locale = Locale(identifier: identifier)
        let language = (locale.language.languageCode?.identifier ?? parts.first ?? "").lowercased()
        switch language {
        case "zh":
            let script = (locale.language.script?.identifier
                ?? parts.dropFirst().first { $0.count == 4 })?.lowercased()
            if script == "hant" { return .traditionalChinese }
            if script == "hans" { return .simplifiedChinese }
            let region = (locale.region?.identifier
                ?? parts.dropFirst().first { $0.count == 2 || ($0.count == 3 && $0.allSatisfy(\.isNumber)) })?.uppercased()
            if let region, ["TW", "HK", "MO"].contains(region) {
                return .traditionalChinese
            }
            return .simplifiedChinese
        case "en": return .english
        case "ja": return .japanese
        case "ko": return .korean
        case "es": return .spanish
        case "fr": return .french
        case "de": return .german
        case "ta": return .tamil
        default: return nil
        }
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
        lookup(key, in: bundle) ?? key
    }

    private func lookup(_ key: String, in bundle: Bundle) -> String? {
        let sentinel = "\u{0000}__MISSING__\u{0000}"
        for identifier in [locale.identifier, InterfaceLanguage.english.rawValue] {
            guard let url = bundle.url(forResource: identifier, withExtension: "lproj"),
                  let localized = Bundle(url: url) else { continue }
            let value = localized.localizedString(forKey: key, value: sentinel, table: nil)
            if value != sentinel { return value }
        }
        return nil
    }

    private func format(_ key: String, _ args: [CVarArg], in bundle: Bundle) -> String {
        let template = string(key, in: bundle)
        return String(format: template, locale: locale, arguments: args)
    }

    /// Localizes static and parameterized runtime status, error and marker messages emitted by
    /// the app, backend or engines while keeping canonical internal strings intact.
    func localizeMessage(_ raw: String, in bundle: Bundle = .main) -> String {
        guard !raw.isEmpty else { return "" }
        if let exact = lookup(raw, in: bundle) { return exact }

        // Composite wrapper messages (recursively localize inner messages).
        if let (kind, inner) = Self.splitMiddle(raw, prefix: "识别处理失败 (", middle: "): ", suffix: "。已确认文字仍保留，可重新加载识别服务恢复。") {
            return format("识别处理失败 (%@): %@。已确认文字仍保留，可重新加载识别服务恢复。", [kind, localizeMessage(inner, in: bundle)], in: bundle)
        }
        if let (kind, inner) = Self.splitMiddle(raw, prefix: "翻译模型加载失败 (", middle: "): ", suffix: "。原文不受影响。") {
            return format("翻译模型加载失败 (%@): %@。原文不受影响。", [kind, localizeMessage(inner, in: bundle)], in: bundle)
        }
        if let (kind, inner) = Self.splitMiddle(raw, prefix: "翻译失败 (", middle: "): ", suffix: "。原文不受影响。") {
            return format("翻译失败 (%@): %@。原文不受影响。", [kind, localizeMessage(inner, in: bundle)], in: bundle)
        }
        if let (kind, inner) = Self.splitMiddle(raw, prefix: "下载失败 (", middle: "): ", suffix: "") {
            return format("下载失败 (%@): %@", [kind, localizeMessage(inner, in: bundle)], in: bundle)
        }

        // Single-argument wrapper messages with recursive inner localization.
        let recursiveWrappers: [(prefix: String, suffix: String, key: String)] = [
            ("API 翻译失败：", "。原文仍保留。", "API 翻译失败：%@。原文仍保留。"),
            ("API 翻译未启动：", "。原文仍保留。", "API 翻译未启动：%@。原文仍保留。"),
            ("Hy-SimulMT 模型不可用：", "", "Hy-SimulMT 模型不可用：%@"),
            ("本地译音不可用：", "。字幕继续更新", "本地译音不可用：%@。字幕继续更新"),
            ("无法采集系统声音：", "。请在系统设置 → 隐私与安全性中允许声笺录制屏幕与系统音频；如刚开启权限，请重启声笺后重试。", "无法采集系统声音：%@。请在系统设置 → 隐私与安全性中允许声笺录制屏幕与系统音频；如刚开启权限，请重启声笺后重试。"),
            ("无法采集系统声音：", "。请在系统设置 → 隐私与安全性中允许声笺录制屏幕与系统音频。", "无法采集系统声音：%@。请在系统设置 → 隐私与安全性中允许声笺录制屏幕与系统音频。"),
            ("系统声音采集异常：", "。请在系统设置 → 隐私与安全性中允许声笺录制屏幕与系统音频；如刚开启权限，请重启声笺后重试。", "系统声音采集异常：%@。请在系统设置 → 隐私与安全性中允许声笺录制屏幕与系统音频；如刚开启权限，请重启声笺后重试。"),
            ("麦克风采集异常：", "", "麦克风采集异常：%@"),
            ("读取音频文件失败：", "", "读取音频文件失败：%@"),
            ("系统声音采集已中断：", "", "系统声音采集已中断：%@"),
            ("读取 AI 配置失败：", "", "读取 AI 配置失败：%@"),
            ("会话记录保存失败：", "", "会话记录保存失败：%@"),
            ("重命名失败：", "", "重命名失败：%@"),
            ("删除会话失败：", "", "删除会话失败：%@"),
            ("清空会话失败：", "", "清空会话失败：%@"),
            ("保存失败：", "", "保存失败：%@"),
            ("无法连接识别服务：", "", "无法连接识别服务：%@"),
            ("识别服务连接被关闭：", "", "识别服务连接被关闭：%@"),
            ("识别服务任务失败：", "", "识别服务任务失败：%@"),
            ("无法连接识别 API：", "", "无法连接识别 API：%@"),
            ("无法写入模型缓存：", "", "无法写入模型缓存：%@"),
        ]
        for rule in recursiveWrappers {
            if let inner = Self.extract(raw, prefix: rule.prefix, suffix: rule.suffix) {
                return format(rule.key, [localizeMessage(inner, in: bundle)], in: bundle)
            }
        }

        // Multi-argument patterns.
        if let (file, rest) = Self.splitMiddle(raw, prefix: "文件大小校验失败：", middle: " 应为 ", suffix: " 字节（多为网络中断，可重试）"),
           let (expected, actual) = Self.splitOnce(rest, separator: " 字节，实际 ") {
            return format("文件大小校验失败：%@ 应为 %@ 字节，实际 %@ 字节（多为网络中断，可重试）", [file, expected, actual], in: bundle)
        }
        if let (code, reason) = Self.splitMiddle(raw, prefix: "识别服务返回 HTTP ", middle: "（", suffix: "）") {
            return format("识别服务返回 HTTP %@（%@）", [code, reason], in: bundle)
        }
        if let (start, end) = Self.splitMiddle(raw, prefix: "", middle: "–", suffix: " 秒的音频未能完整翻译，已有文字已保留"),
           !start.isEmpty, !end.isEmpty {
            return format("%@–%@ 秒的音频未能完整翻译，已有文字已保留", [start, end], in: bundle)
        }
        if let (key, range) = Self.splitMiddle(raw, prefix: "", middle: " 必须在 ", suffix: " 范围内"),
           let (low, high) = Self.splitOnce(range, separator: "–") {
            return format("%@ 必须在 %@–%@ 范围内", [key, low, high], in: bundle)
        }
        if let (prefix, code) = Self.splitMiddle(raw, prefix: "", middle: "（HTTP ", suffix: "）"),
           !prefix.isEmpty, code.allSatisfy(\.isNumber), !code.isEmpty {
            return format("%@（HTTP %@）", [localizeMessage(prefix, in: bundle), code], in: bundle)
        }

        // Single-argument literal patterns (ordered most-specific first).
        let literalPatterns: [(prefix: String, suffix: String, key: String)] = [
            ("无法读取钥匙串（", "），请重新保存 API Key", "无法读取钥匙串（%@），请重新保存 API Key"),
            ("无法保存 API Key（", "）", "无法保存 API Key（%@）"),
            ("无法更新 API Key（", "）", "无法更新 API Key（%@）"),
            ("无法删除 API Key（", "）", "无法删除 API Key（%@）"),
            ("无法读取系统音频数据（", "）", "无法读取系统音频数据（%@）"),
            ("识别服务拒绝访问（HTTP 403）：此 API Key 未开通该模型或业务空间权限（", "）", "识别服务拒绝访问（HTTP 403）：此 API Key 未开通该模型或业务空间权限（%@）"),
            ("识别服务返回 HTTP ", "", "识别服务返回 HTTP %@"),
            ("识别 API 返回 HTTP ", "；请检查地址、模型、密钥或额度", "识别 API 返回 HTTP %@；请检查地址、模型、密钥或额度"),
            ("识别 API 返回 HTTP ", "", "识别 API 返回 HTTP %@"),
            ("有 ", " 个配置文件无法读取，其余配置已恢复。", "有 %@ 个配置文件无法读取，其余配置已恢复。"),
            ("已切换为固定流式识别模型 ", "，正在应用新设置…", "已切换为固定流式识别模型 %@，正在应用新设置…"),
            ("请先保存「", "」对应的密钥", "请先保存「%@」对应的密钥"),
            ("已切换到「", "」", "已切换到「%@」"),
            ("系统未安装 ", " 语音，请在系统设置中添加语音", "系统未安装 %@ 语音，请在系统设置中添加语音"),
            ("译文语言已切换为 ", "", "译文语言已切换为 %@"),
            ("未知配置字段: ", "", "未知配置字段: %@"),
            ("未知翻译配置字段: ", "", "未知翻译配置字段: %@"),
            ("", " 必须为字符串", "%@ 必须为字符串"),
            ("Whisper 离线辅助资源缺失: ", "", "Whisper 离线辅助资源缺失: %@"),
            ("离线资源缺失: ", "", "离线资源缺失: %@"),
            ("翻译模型资源缺失: ", "", "翻译模型资源缺失: %@"),
            ("本地缺少模型或版本 ", "，请先下载。", "本地缺少模型或版本 %@，请先下载。"),
            ("模型信息格式无效：", "", "模型信息格式无效：%@"),
            ("模型版本号无效：", "", "模型版本号无效：%@"),
            ("缺少文件校验信息：", "", "缺少文件校验信息：%@"),
            ("模型文件名无效：", "", "模型文件名无效：%@"),
            ("模型文件名不安全：", "", "模型文件名不安全：%@"),
            ("文件校验失败：", " 内容与模型仓库记录不一致，请重试", "文件校验失败：%@ 内容与模型仓库记录不一致，请重试"),
        ]
        for rule in literalPatterns {
            if let arg = Self.extract(raw, prefix: rule.prefix, suffix: rule.suffix), !arg.isEmpty {
                return format(rule.key, [arg], in: bundle)
            }
        }
        return raw
    }

    private static func extract(_ text: String, prefix: String, suffix: String) -> String? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix),
              text.count >= prefix.count + suffix.count else { return nil }
        let start = text.index(text.startIndex, offsetBy: prefix.count)
        let end = text.index(text.endIndex, offsetBy: -suffix.count)
        return String(text[start..<end])
    }

    private static func splitOnce(_ text: String, separator: String) -> (String, String)? {
        guard let range = text.range(of: separator) else { return nil }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }

    private static func splitMiddle(_ text: String, prefix: String, middle: String, suffix: String) -> (String, String)? {
        guard let body = extract(text, prefix: prefix, suffix: suffix) else { return nil }
        return splitOnce(body, separator: middle)
    }
}

struct InterfaceLanguagePicker: View {
    @ObservedObject var settings: InterfaceLanguageSettings

    var body: some View {
        Picker("界面语言", selection: $settings.selection) {
            Text("跟随系统").tag(InterfaceLanguage.system)
            ForEach(InterfaceLanguage.supported, id: \.self) { language in
                Text(verbatim: language.nativeName ?? language.rawValue).tag(language)
            }
        }
        .pickerStyle(.menu)
    }
}
