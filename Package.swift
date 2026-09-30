// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Platter",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        // Turso's libSQL. A local file today; the same package does embedded-replica sync later.
        .package(url: "https://github.com/tursodatabase/libsql-swift", exact: "0.3.2"),
    ],
    targets: [
        .executableTarget(
            name: "Platter",
            dependencies: [.product(name: "Libsql", package: "libsql-swift")],
            path: "Sources/Platter"
        ),
        .testTarget(
            name: "PlatterTests",
            dependencies: ["Platter"],
            path: "Tests/PlatterTests"
        ),
    ]
)
