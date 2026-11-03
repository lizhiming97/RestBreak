// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FridayMouse",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FridayMouse", targets: ["FridayMouse"])],
    targets: [
        .target(name: "MosScrollCore"),
        .executableTarget(name: "FridayMouse", dependencies: ["MosScrollCore"]),
        .testTarget(name: "MosScrollCoreTests", dependencies: ["MosScrollCore"])
    ],
    swiftLanguageModes: [.v5]
)
