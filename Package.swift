// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScreenSnipper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ScreenSnipperCore", targets: ["ScreenSnipperCore"]),
        .executable(name: "screen-snipper", targets: ["ScreenSnipper"]),
        .executable(name: "screen-snipper-tests", targets: ["ScreenSnipperTests"])
    ],
    targets: [
        .target(name: "ScreenSnipperCore"),
        .executableTarget(
            name: "ScreenSnipper",
            dependencies: ["ScreenSnipperCore"],
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
            name: "ScreenSnipperTests",
            dependencies: ["ScreenSnipperCore"]
        )
    ]
)
