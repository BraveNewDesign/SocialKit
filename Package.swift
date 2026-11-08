// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SocialKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SocialKit", targets: ["SocialKit"]),
        .library(name: "SocialKitUI", targets: ["SocialKitUI"])
    ],
    targets: [
        .target(name: "SocialKit"),
        .target(name: "SocialKitUI", dependencies: ["SocialKit"]),
        .executableTarget(name: "SocialKitExample", dependencies: ["SocialKit"]),
        .testTarget(name: "SocialKitTests", dependencies: ["SocialKit"])
    ]
)
