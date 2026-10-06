// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "ClaudeHUD",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "ClaudeHUD", path: "Sources/ClaudeHUD")
  ],
  swiftLanguageVersions: [.v5]
)
