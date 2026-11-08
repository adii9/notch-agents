// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchAgents",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchAgents", path: "Sources/NotchAgents")
    ]
)
