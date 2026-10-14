// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "S3DSKit",
    platforms: [
        .visionOS(.v26)
    ],
    products: [
        .library(name: "S3DSKit", targets: ["S3DSKit"])
    ],
    targets: [
        .target(
            name: "S3DSKit",
            resources: [
                .process("Shaders")
            ]
        ),
        .testTarget(
            name: "S3DSKitTests",
            dependencies: ["S3DSKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
