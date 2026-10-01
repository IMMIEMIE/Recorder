import Foundation

/// Model-free LocalBackend for scripts/test_livetranslate.sh: the real BackendCore with the
/// placeholder engines, rooted in a temporary directory instead of Application Support.
enum LocalBackend {
    static func makeChannel() throws -> BackendChannel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let core = BackendCore(root: root, asrEngine: PlaceholderASREngine(), apiRecognizer: APIRecognizer(),
                               translator: PlaceholderTranslatorEngine(), downloader: HubDownloader())
        return InProcessChannel(core: core)
    }
}
