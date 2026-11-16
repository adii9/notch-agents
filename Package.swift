// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchAgents",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "NotchAgents",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/NotchAgents",
            // Find Sparkle.framework next to the binary (swift build/run) and in the app bundle.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path",
                                           "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
