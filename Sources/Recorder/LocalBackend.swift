import Foundation
import RecorderBackend
import RecorderEngines
import RecorderMLX

/// Builds the in-process backend the app talks to. Kept out of AppModel so scripts/test_livetranslate.sh
/// can compile AppModel with a model-free stand-in (tests/LocalBackendStub.swift).
enum LocalBackend {
    static func makeChannel() throws -> BackendChannel {
        // config.json, translation.json and the Hugging Face cache (models/) live here, as with the
        // Python sidecar, so existing installs keep their settings and downloaded weights.
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalRecorder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // SwiftPM builds of mlx-swift carry no Metal kernels; build.sh bundles the mlx.metallib that
        // scripts/build_metallib.sh compiles from the pinned mlx-swift sources.
        MLXRuntime.configure(metallib: Bundle.main.resourceURL?.appendingPathComponent("mlx.metallib"))
        ASRValidation.whisperAssets = Bundle.main.resourceURL?.appendingPathComponent("whisper")
        let core = BackendCore(root: root, asrEngine: MLXASREngine(), translator: MLXTranslatorEngine())
        return InProcessChannel(core: core)
    }
}
