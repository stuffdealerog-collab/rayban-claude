// swift-tools-version: 6.0

import PackageDescription

// Платформенно-независимое ядро: клиент Claude API (SSE-стриминг), агентный цикл с tools,
// разбиение текста на фразы для озвучки. Собирается и тестируется на macOS без Xcode.
let package = Package(
    name: "ClaudeKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ClaudeKit", targets: ["ClaudeKit"]),
    ],
    targets: [
        .target(name: "ClaudeKit"),
        .testTarget(name: "ClaudeKitTests", dependencies: ["ClaudeKit"]),
    ]
)
