// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LectorMD",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LectorMD", targets: ["LectorMD"])
    ],
    targets: [
        .executableTarget(name: "LectorMD", path: "Sources/LectorMD")
    ]
)
