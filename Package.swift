// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Recorder",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Recorder", targets: ["Recorder"])],
    targets: [
        .target(name: "Cwebrtcvad",
                path: "Sources/Cwebrtcvad",
                exclude: ["webrtc/common_audio/vad/include/webrtc_vad.h"],
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("."),
                            .define("WEBRTC_POSIX"),
                            .define("WEBRTC_MAC")]),
        .executableTarget(name: "Recorder", dependencies: ["Cwebrtcvad"])
    ]
)
