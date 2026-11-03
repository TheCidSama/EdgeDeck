// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EdgeDeck",
    platforms: [.macOS(.v13)],
    targets: [
        // Raw trackpad touches, trackpad haptics and display brightness via private Apple frameworks (loaded at runtime).
        .target(name: "CTouch", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics")]),
        // The menu bar app: AppKit only (no SwiftUI) to keep memory low.
        .executableTarget(
            name: "EdgeDeck",
            dependencies: ["CTouch"],
            swiftSettings: [.unsafeFlags(["-Osize"])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
