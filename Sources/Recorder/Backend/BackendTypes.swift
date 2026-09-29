import Foundation

enum Backend {
    static let rate = 16000
    static let frame = 320  // 20 ms, signed little-endian PCM16 mono
    static let maxMessage = 256 * 1024
    static let defaultModel = "mlx-community/Qwen3-ASR-1.7B-bf16"
    static let defaultTranslator = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    // UI value -> (English name for prompts, Chinese name for Chinese-instruction prompts)
    static let translationTargets: [String: (english: String, chinese: String)] = [
        "简体中文": ("Simplified Chinese", "简体中文"),
        "繁體中文": ("Traditional Chinese", "繁体中文"),
        "English": ("English", "英语"),
        "日本語": ("Japanese", "日语"),
        "한국어": ("Korean", "韩语"),
        "Français": ("French", "法语"),
        "Deutsch": ("German", "德语"),
        "Español": ("Spanish", "西班牙语"),
        "Русский": ("Russian", "俄语"),
    ]
}

/// Monotonic seconds, mirroring Python's time.monotonic().
func backendNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

/// Backend errors carry the original Python exception name so event text stays identical.
struct BackendError: Error, CustomStringConvertible {
    let kind: String
    let message: String
    var description: String { kind.isEmpty ? message : "\(kind): \(message)" }
    static func value(_ message: String) -> BackendError { BackendError(kind: "ValueError", message: message) }
}

func backendErrorText(_ error: Error) -> String {
    if let backend = error as? BackendError { return backend.description }
    return "\(String(describing: type(of: error))): \(error.localizedDescription)"
}

func backendErrorKind(_ error: Error) -> String {
    if let backend = error as? BackendError { return backend.kind }
    return String(describing: type(of: error))
}

func backendErrorMessage(_ error: Error) -> String {
    (error as? BackendError)?.message ?? error.localizedDescription
}

// JSON values from JSONSerialization arrive as NSNumber; on this toolchain even __NSCFNumber
// answers `is Bool` == true, so booleans are detected via objCType (JSON booleans are 'c').
func strictJSONInt(_ value: Any) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    let type = number.objCType[0]
    guard type == UInt8(UnicodeScalar("q").value) || type == UInt8(UnicodeScalar("i").value) ||
        type == UInt8(UnicodeScalar("l").value) || type == UInt8(UnicodeScalar("s").value) else { return nil }
    return number.intValue
}

func strictJSONBool(_ value: Any) -> Bool? {
    guard let number = value as? NSNumber, number.objCType[0] == UInt8(UnicodeScalar("c").value) else { return nil }
    return number.boolValue
}

/// One speech segment awaiting or undergoing recognition; mirrors the Segmenter emit dict.
struct SegmentJob {
    var sessionID = ""
    var segmentID = 0
    var revision = 0
    var startSample = 0
    var endSample = 0
    var lastVoicedSample: Int? = nil
    var final = false
    var forcedCut = false
    var pcm = Data()
}

/// A streaming-ASR sentence final published directly by the app.
struct StreamFinal {
    var sessionID: String
    var segmentID: Int
    var revision: Int
    var startSample: Int
    var forcedCut: Bool
    var text: String
}

protocol Transcriber: AnyObject {
    func transcribe(_ pcm: Data) async throws -> (text: String, elapsedMS: Int)
}

protocol ASREngine: Transcriber {
    var isLoaded: Bool { get }
    func load(config: ModelConfig, path: String) async throws
    func warmup() async throws
    func unload() async
}

protocol TranslatorEngine: AnyObject {
    var isLoaded: Bool { get }
    var modelID: String { get }
    func load(config: TranslationConfig, path: String) async throws
    func warmup() async throws
    func unload() async
    func stream(_ text: String, target: String, context: [(String, String)]) -> AsyncThrowingStream<String, Error>
}

protocol APIRecognizing: Transcriber {
    var key: String { get }
    func load(config: ModelConfig, key: String) throws
    func clearKey()
}
