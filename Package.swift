// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalModelManager",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalModelManager", targets: ["ModelManager"])],
    targets: [
        .executableTarget(name: "ModelManager"),
        .testTarget(name: "ModelManagerTests", dependencies: ["ModelManager"])
    ]
)
