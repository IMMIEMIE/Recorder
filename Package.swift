// swift-tools-version: 5.9
import PackageDescription

// Single-process app: the SwiftUI front end (Recorder) talks to the in-process backend
// (RecorderBackend: server.py semantics, plain Foundation + WebRTC VAD), whose local engines
// (RecorderEngines) run the MLX model layer (RecorderMLX). RecorderVerify drives the same layers
// with real models for the verification reports in docs/.
let package = Package(
    name: "Recorder",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Recorder", targets: ["Recorder"]),
        .executable(name: "RecorderVerify", targets: ["RecorderVerify"]),
    ],
    dependencies: [
        // scripts/build_metallib.sh compiles the Metal kernels from this exact mlx-swift checkout.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.2"),
        // mlx-swift-lm has no 0.32-compatible release tag yet, so it is pinned by revision.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "c043fb3b1ccf00f54ef8882a1e8da45c6e32e6f8"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(name: "Cwebrtcvad",
                path: "Sources/Cwebrtcvad",
                exclude: ["webrtc/common_audio/vad/include/webrtc_vad.h"],
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("."),
                            .define("WEBRTC_POSIX"),
                            .define("WEBRTC_MAC")]),
        .target(name: "RecorderBackend", dependencies: ["Cwebrtcvad"]),
        .target(name: "RecorderMLX", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .target(name: "RecorderEngines", dependencies: ["RecorderBackend", "RecorderMLX"]),
        .executableTarget(name: "Recorder", dependencies: ["RecorderBackend", "RecorderEngines", "RecorderMLX"]),
        .executableTarget(name: "RecorderVerify", dependencies: ["RecorderBackend", "RecorderEngines", "RecorderMLX"]),
    ]
)
