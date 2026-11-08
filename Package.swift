// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SocialKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SocialKit", targets: ["SocialKit"]),
        .library(name: "SocialKitUI", targets: ["SocialKitUI"]),
        .executable(name: "SocialKitMetaValidation", targets: ["SocialKitMetaValidation"])
    ],
    targets: [
        .target(name: "SocialKit"),
        .target(name: "SocialKitUI", dependencies: ["SocialKit"]),
        .executableTarget(name: "SocialKitExample", dependencies: ["SocialKit"]),
        .target(name: "MetaValidationOAuth", dependencies: ["SocialKit"]),
        .target(name: "MetaValidationStorage", dependencies: ["SocialKit"]),
        .executableTarget(name: "SocialKitMetaValidation", dependencies: ["SocialKit", "MetaValidationOAuth", "MetaValidationStorage"]),
        .testTarget(name: "MetaValidationOAuthTests", dependencies: ["MetaValidationOAuth", "SocialKit"]),
        .testTarget(name: "MetaValidationStorageTests", dependencies: ["MetaValidationStorage", "SocialKit"]),
        .testTarget(name: "SocialKitTests", dependencies: ["SocialKit"])
    ]
)
