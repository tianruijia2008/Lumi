// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lumi",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Lumi",
            path: "Sources/Lumi",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
