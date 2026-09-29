// swift-tools-version: 5.9
import PackageDescription

// RECORDER_INPROCESS=1 (scripts/build.sh, scripts/verify_inprocess.sh) builds the in-process MLX
// backend: the RecorderMLX model layer, its engine adapters in the app, and the RecorderVerify CLI.
// The default build keeps the Python sidecar and pulls no MLX dependencies.
let inProcess = Context.environment["RECORDER_INPROCESS"] == "1"

var products: [Product] = [.executable(name: "Recorder", targets: ["Recorder"])]
var dependencies: [Package.Dependency] = []
var recorderDependencies: [Target.Dependency] = ["Cwebrtcvad"]
var recorderSettings: [SwiftSetting] = []
var targets: [Target] = [
    .target(name: "Cwebrtcvad",
            path: "Sources/Cwebrtcvad",
            exclude: ["webrtc/common_audio/vad/include/webrtc_vad.h"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."),
                        .define("WEBRTC_POSIX"),
                        .define("WEBRTC_MAC")]),
]

if inProcess {
    // mlx-swift is pinned to the kernels of the bundled mlx.metallib (mlx 0.32.2, see requirements.lock);
    // mlx-swift-lm has no 0.32-compatible release tag yet, so it is pinned by revision.
    dependencies += [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.2"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "c043fb3b1ccf00f54ef8882a1e8da45c6e32e6f8"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ]
    targets.append(.target(name: "RecorderMLX", dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
    ]))
    targets.append(.executableTarget(name: "RecorderVerify", dependencies: ["RecorderMLX"]))
    products.append(.executable(name: "RecorderVerify", targets: ["RecorderVerify"]))
    recorderDependencies.append("RecorderMLX")
    recorderSettings.append(.define("RECORDER_INPROCESS"))
}

targets.append(.executableTarget(name: "Recorder", dependencies: recorderDependencies,
                                 exclude: inProcess ? [] : ["Engines"],
                                 swiftSettings: recorderSettings))

let package = Package(
    name: "Recorder",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
