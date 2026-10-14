// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LocalBot",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-app updates, verified with our EdDSA key (see scripts/publish-release.sh).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "LocalBot",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/LocalBot",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
