// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MusicPlayer",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "MusicPlayerKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/MusicPlayerKit"
        ),
        .executableTarget(
            name: "MusicPlayer",
            dependencies: ["MusicPlayerKit"],
            path: "Sources/MusicPlayer",
            resources: [.copy("Resources/OSMDAssets")]
        ),
        .executableTarget(
            name: "ScanTest",
            dependencies: ["MusicPlayerKit"],
            path: "Sources/ScanTest"
        )
    ]
)
