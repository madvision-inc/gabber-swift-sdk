// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Gabber",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .macCatalyst(.v14),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Gabber",
            targets: ["Gabber"]),
    ],
    dependencies: [
        .package(name:"LiveKit", url: "https://github.com/livekit/client-sdk-swift.git", from: "2.0.14"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Gabber", dependencies: ["LiveKit"]),
        .testTarget(
            name: "GabberTests",
            dependencies: ["Gabber"]),
    ]
)
