// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FullscreenGeometryProbe",
    platforms: [.macOS(.v13)],
    products: [
        .executable(
            name: "fullscreen-geometry-probe",
            targets: ["FullscreenGeometryProbe"]
        )
    ],
    targets: [
        .executableTarget(name: "FullscreenGeometryProbe")
    ]
)
