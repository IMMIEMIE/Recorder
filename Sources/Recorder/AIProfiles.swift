import SwiftUI
import CryptoKit

struct AIProfile: Codable, Equatable, Identifiable {
    var baseURL: String
    var modelID: String
    var id: String { baseURL }
    var configuration: AIServiceConfiguration {
        .init(endpoint: baseURL + "/chat/completions", model: modelID)
    }
    static func normalize(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/chat/completions") { value.removeLast("/chat/completions".count) }
        guard var parts = URLComponents(string: value + "/chat/completions") else { throw AIError.message("Base URL 无效") }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        guard let result = parts.url?.absoluteString else { throw AIError.message("Base URL 无效") }
        _ = try AIServiceConfiguration(endpoint: result, model: "validation").url()
        return String(result.dropLast("/chat/completions".count))
    }
}

/// One non-secret JSON file per normalized base URL. Credentials stay in Keychain.
struct AIProfileFiles {
    let directory: URL
    func file(for baseURL: String) -> URL {
        let digest = SHA256.hash(data: Data(baseURL.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    func load(reportInvalid: (String) -> Void = { _ in }) throws -> [AIProfile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { url -> AIProfile? in
                do {
                    let profile = try JSONDecoder().decode(AIProfile.self, from: Data(contentsOf: url))
                    guard try AIProfile.normalize(profile.baseURL) == profile.baseURL else { throw AIError.message("配置地址无效") }
                    _ = try profile.configuration.url()
                    return profile
                } catch { reportInvalid(url.lastPathComponent); return nil }
            }
            .sorted { $0.baseURL < $1.baseURL }
    }
    func save(_ profile: AIProfile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: file(for: profile.baseURL), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(for: profile.baseURL).path)
    }
    func remove(_ profile: AIProfile) throws { try FileManager.default.removeItem(at: file(for: profile.baseURL)) }
}

final class AIProfiles: ObservableObject {
    static let shared = AIProfiles()
    @Published private(set) var profiles: [AIProfile] = []
    @Published private(set) var selectedID = ""
    @Published var message = ""
    private let files: AIProfileFiles
    private let defaults: UserDefaults
    var selected: AIProfile? { profiles.first { $0.id == selectedID } }
    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        files = AIProfileFiles(directory: directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalRecorder/AIProfiles", isDirectory: true))
        do {
            var invalid: [String] = []
            profiles = try files.load { invalid.append($0) }
            if !invalid.isEmpty { message = "有 \(invalid.count) 个配置文件无法读取，其余配置已恢复。" }
            // Migrate the previous single-endpoint configuration once, without removing its key.
            if profiles.isEmpty, let data = defaults.data(forKey: "ai.configuration.v1") {
                let old = try JSONDecoder().decode(AIServiceConfiguration.self, from: data)
                let base = try AIProfile.normalize(old.endpoint)
                let profile = AIProfile(baseURL: base, modelID: old.model)
                if let key = try APIKeyStore.read(endpoint: old.endpoint) { try APIKeyStore.save(key, endpoint: base) }
                try files.save(profile); profiles = [profile]
                defaults.removeObject(forKey: "ai.configuration.v1")
            }
            let saved = defaults.string(forKey: "ai.selectedBaseURL") ?? ""
            selectedID = profiles.contains { $0.id == saved } ? saved : profiles.first?.id ?? ""
        } catch { message = "读取 AI 配置失败：\(error.localizedDescription)" }
    }
    func select(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedID = id; defaults.set(id, forKey: "ai.selectedBaseURL")
    }
    func save(base: String, model: String, key: String) throws -> AIProfile {
        let normalized = try AIProfile.normalize(base)
        let profile = AIProfile(baseURL: normalized, modelID: model.trimmingCharacters(in: .whitespacesAndNewlines))
        _ = try profile.configuration.url()
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty { try APIKeyStore.save(secret, endpoint: normalized) }
        try files.save(profile)
        profiles.removeAll { $0.id == normalized }; profiles.append(profile); profiles.sort { $0.id < $1.id }
        select(normalized); message = "已保存"
        return profile
    }
    func remove(_ profile: AIProfile) throws {
        try APIKeyStore.remove(endpoint: profile.baseURL)
        try files.remove(profile)
        profiles.removeAll { $0.id == profile.id }
        selectedID = profiles.first?.id ?? ""
        defaults.set(selectedID, forKey: "ai.selectedBaseURL")
        message = "已删除配置及密钥"
    }
}

struct AISettingsView: View {
    @ObservedObject private var profiles = AIProfiles.shared
    @State private var editingID = ""
    @State private var base = "https://api.deepseek.com"
    @State private var model = "deepseek-v4-flash"
    @State private var key = ""
    @State private var message = ""
    @State private var keyStatus = ""
    private func edit(_ profile: AIProfile?) {
        editingID = profile?.id ?? ""
        base = profile?.baseURL ?? ""; model = profile?.modelID ?? ""; key = ""; message = ""
        keyStatus = "尚未保存密钥"
        if let profile {
            do { keyStatus = try APIKeyStore.read(endpoint: profile.baseURL)?.isEmpty == false ? "密钥已保存，重启后可继续使用" : "尚未保存密钥" }
            catch { keyStatus = error.localizedDescription }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("已保存配置", selection: Binding(get: { editingID }, set: { id in
                    if id.isEmpty { edit(nil) } else { profiles.select(id); edit(profiles.selected) }
                })) {
                    Text("新配置").tag("")
                    ForEach(profiles.profiles) { Text($0.baseURL).tag($0.id) }
                }
                Button("新增") { edit(nil) }
            }
            HStack {
                Button("DeepSeek") { edit(profiles.profiles.first { $0.id == "https://api.deepseek.com" }); base = "https://api.deepseek.com"; if model.isEmpty { model = "deepseek-v4-flash" } }
                Button("OpenAI") { edit(profiles.profiles.first { $0.id == "https://api.openai.com/v1" }); base = "https://api.openai.com/v1" }
            }
            LabeledContent("Base URL") { TextField("https://api.example.com/v1", text: Binding(get: { base }, set: { base = $0; key = ""; keyStatus = "保存时将使用此地址对应的密钥" })) }
            LabeledContent("模型 ID") { TextField("模型 ID", text: $model) }
            LabeledContent("API Key") { SecureField("留空保留该 Base URL 已保存的密钥", text: $key) }
            Text("地址、模型和当前选择会持久保存，重启后自动恢复。密钥存于系统钥匙串；输入框留空不会清除已保存密钥。").font(.caption).foregroundStyle(.secondary)
            Text(keyStatus).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保存并使用") {
                    do { let saved = try profiles.save(base: base, model: model, key: key); edit(saved); message = "已保存并设为当前配置" }
                    catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
                Button("删除配置") {
                    guard let profile = profiles.profiles.first(where: { $0.id == editingID }) else { return }
                    do { try profiles.remove(profile); edit(profiles.selected); message = "已删除配置及密钥" }
                    catch { message = error.localizedDescription }
                }.disabled(editingID.isEmpty)
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            if !profiles.message.isEmpty && message.isEmpty { Text(profiles.message).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.textFieldStyle(.roundedBorder).padding(20)
            .onAppear { if let selected = profiles.selected { edit(selected) } }
    }
}
