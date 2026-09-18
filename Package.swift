// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexIdeaDock",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexIdeaDock", targets: ["CodexIdeaDockApp"]),
        .executable(
            name: "CodexIdeaDockProcessLauncher",
            targets: ["CodexIdeaDockProcessLauncher"]
        )
    ],
    targets: [
        .target(
            name: "CodexIdeaDockCore"
        ),
        .executableTarget(
            name: "CodexIdeaDockApp",
            dependencies: ["CodexIdeaDockCore"]
        ),
        .executableTarget(
            name: "CodexIdeaDockProcessLauncher"
        ),
        .testTarget(
            name: "CodexIdeaDockCoreTests",
            dependencies: ["CodexIdeaDockCore"]
        )
    ]
)
