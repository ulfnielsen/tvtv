// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TVTVCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TVTVCore",
            targets: ["TVTVCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/duckdb/duckdb-swift.git", exact: "1.1.3")
    ],
    targets: [
        // C declarations for the tvtv-vortex Rust staticlib (symbols resolved
        // at the final app/extension link step — see project.yml linker flags).
        .target(name: "CTvtvVortex"),
        .target(
            name: "TVTVCore",
            dependencies: [
                "CTvtvVortex",
                .product(name: "DuckDB", package: "duckdb-swift")
            ],
            // TVTVCore is built as a dynamic framework by Xcode but the
            // tvtv-vortex staticlib is linked only by the final app/extension
            // executables. Defer the tvtv_vortex_* symbols to load-time lookup
            // in the host process (where the staticlib IS linked) so the
            // framework — and `swift test` — build without them resolved.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])
            ]
        ),
        .testTarget(
            name: "TVTVCoreTests",
            dependencies: ["TVTVCore"]
        )
    ]
)
