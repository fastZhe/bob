// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Translate",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Translate", targets: ["Translate"])
    ],
    dependencies: [
        // 全局快捷键注册（基于 Carbon RegisterEventHotKey，不需辅助功能权限）
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Translate",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/Translate",
            linkerSettings: [
                // Carbon 用于 RegisterEventHotKey
                .linkedFramework("Carbon")
            ]
        )
    ]
)
