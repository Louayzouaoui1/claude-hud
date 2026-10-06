// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "ClaudeHUD",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "HUDCore", path: "Sources/HUDCore"),
    .executableTarget(name: "ClaudeHUD", dependencies: ["HUDCore"], path: "Sources/ClaudeHUD"),
    .testTarget(name: "ClaudeHUDTests", dependencies: ["HUDCore"])
  ],
  swiftLanguageVersions: [.v5]
)
