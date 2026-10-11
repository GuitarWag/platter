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
        // The shared engine, library, store, and analysis. Both apps use it.
        .target(
            name: "PlatterCore",
            dependencies: [.product(name: "Libsql", package: "libsql-swift")],
            path: "Sources/PlatterCore"
        ),
        // The DJ rig.
        .executableTarget(
            name: "Platter",
            dependencies: ["PlatterCore"],
            path: "Sources/Platter"
        ),
        // The music player.
        .executableTarget(
            name: "PlatterPlayer",
            dependencies: ["PlatterCore"],
            path: "Sources/PlatterPlayer"
        ),
        .testTarget(
            name: "PlatterTests",
            dependencies: ["PlatterCore", "Platter", "PlatterPlayer"],
            path: "Tests/PlatterTests"
        ),
    ]
)
