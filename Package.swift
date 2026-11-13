// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PCBAssemblyGuide",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PCBAssemblyGuide", path: "Sources/PCBAssemblyGuide")
    ]
)
