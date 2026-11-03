// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuBarShelf",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MenuBarShelf", targets: ["MenuBarShelf"]),
        .executable(name: "ShelfLab", targets: ["ShelfLab"]),
    ],
    targets: [
        .target(name: "MenuBarShelf", linkerSettings: [.linkedFramework("ApplicationServices")]),
        .executableTarget(name: "ShelfLab", dependencies: ["MenuBarShelf"]),
        .testTarget(name: "MenuBarShelfTests", dependencies: ["MenuBarShelf"]),
    ],
    // Ice uses Swift 5 mode; a Swift 6 host can import this independent module.
    swiftLanguageModes: [.v5]
)
