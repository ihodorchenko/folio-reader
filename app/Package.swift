// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS("14.0")],
    products: [
        .executable(name: "Folio", targets: ["Folio"])
    ],
    targets: [
        .executableTarget(
            name: "Folio",
            path: "Sources/Folio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
