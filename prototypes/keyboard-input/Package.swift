// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KeyboardInputProbe",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "keyboard-input-probe", targets: ["KeyboardInputProbe"])
    ],
    targets: [
        .executableTarget(name: "KeyboardInputProbe")
    ]
)
