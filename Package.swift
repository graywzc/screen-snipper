// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GifSnip",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GifSnipCore", targets: ["GifSnipCore"]),
        .executable(name: "gif-snip", targets: ["GifSnip"]),
        .executable(name: "gif-snip-tests", targets: ["GifSnipTests"])
    ],
    targets: [
        .target(name: "GifSnipCore"),
        .executableTarget(
            name: "GifSnip",
            dependencies: ["GifSnipCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .executableTarget(
            name: "GifSnipTests",
            dependencies: ["GifSnipCore"]
        )
    ]
)
