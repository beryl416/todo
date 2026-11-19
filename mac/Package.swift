// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Todo",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TodoCore"),
        .executableTarget(name: "Todo", dependencies: ["TodoCore"]),
        .testTarget(name: "TodoCoreTests", dependencies: ["TodoCore"]),
    ]
)
