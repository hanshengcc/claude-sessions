// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeSessions",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(name: "SessionCore", path: "Sources/SessionCore"),
        .executableTarget(
            name: "ClaudeSessions",
            dependencies: ["SessionCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/ClaudeSessions"
        ),
        .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore"], path: "Tests/SessionCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
