// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Recorder", platforms: [.macOS(.v14)], products: [.executable(name: "Recorder", targets: ["Recorder"])], targets: [.executableTarget(name: "Recorder")])
