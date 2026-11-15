// swift-tools-version: 6.0
// Логика ассистента без UIKit: память (заметки Markdown) и почта (IMAP + MIME).
// Собирается и тестируется на macOS: `swift test` (на Mac без Xcode — с путями к Testing.framework, см. README).
import PackageDescription

let package = Package(
    name: "AssistantCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
    ],
    targets: [
        .target(name: "AssistantCore"),
        .testTarget(name: "AssistantCoreTests", dependencies: ["AssistantCore"]),
    ]
)
