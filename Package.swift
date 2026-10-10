// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MicMonitor",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MicMonitor",
            path: "Sources/MicMonitor"
        ),
        .testTarget(
            name: "MicMonitorTests",
            dependencies: ["MicMonitor"],
            path: "Tests/MicMonitorTests"
        ),
    ],
    // 保持 Swift 5 语言模式:菜单栏小工具无需 strict concurrency,降低编译风险
    swiftLanguageModes: [.v5]
)
