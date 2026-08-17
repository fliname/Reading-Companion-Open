// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadingCompanion",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ReadingCompanion", targets: ["ReadingCompanion"])
    ],
    targets: [
        .executableTarget(
            name: "ReadingCompanion",
            path: "Sources/ReadingCompanion"
        ),
        .testTarget(
            name: "ReadingCompanionTests",
            dependencies: ["ReadingCompanion"],
            path: "Tests/ReadingCompanionTests"
        )
    ]
)

