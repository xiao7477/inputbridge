// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InputBridge",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "InputBridge", targets: ["InputBridge"])],
    targets: [.executableTarget(name: "InputBridge")]
)
