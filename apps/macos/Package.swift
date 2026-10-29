// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MultiSync",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MultiSync", targets: ["MultiSync"])],
    targets: [
        .target(name: "MultiSyncKit"),
        .executableTarget(name: "MultiSync", dependencies: ["MultiSyncKit"]),
        .testTarget(name: "MultiSyncKitTests", dependencies: ["MultiSyncKit"])
    ]
)
