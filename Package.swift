// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PasteBox",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PasteBox",
            path: "Sources/PasteBox",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
