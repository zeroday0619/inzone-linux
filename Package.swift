// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "inzone-linux",
    products: [
        .executable(name: "inzone-profile", targets: ["InzoneCLI"]),
        .executable(name: "inzone-tools", targets: ["InzoneTools"]),
        .library(name: "InzoneCore", targets: ["InzoneCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/minacle/swift-tui", exact: "0.12.0"),
        .package(path: "Vendor/swift-terminal"),
    ],
    targets: [
        .target(name: "InzoneCore"),
        .target(name: "InzoneToolsCore", dependencies: ["InzoneCore"]),
        .target(name: "InzoneDiagnostics", dependencies: ["InzoneCore", "CLADSPA"]),
        .executableTarget(name: "InzoneTools", dependencies: ["InzoneCore", "InzoneToolsCore", "InzoneDiagnostics"]),
        .target(
            name: "InzoneTUI",
            dependencies: ["InzoneCore", .product(name: "SwiftTUI", package: "swift-tui"),
                           .product(name: "Terminal", package: "swift-terminal")]
        ),
        .executableTarget(name: "InzoneCLI", dependencies: ["InzoneCore", "InzoneTUI"]),
        .systemLibrary(name: "CLADSPA"),
        .testTarget(name: "InzoneCoreTests", dependencies: ["InzoneCore", "CLADSPA"], resources: [.copy("Fixtures")]),
        .testTarget(name: "InzoneToolsTests", dependencies: ["InzoneCore", "InzoneToolsCore"]),
        .testTarget(name: "InzoneDiagnosticsTests", dependencies: ["InzoneCore", "InzoneDiagnostics"]),
        .testTarget(
            name: "InzoneTUITests",
            dependencies: ["InzoneTUI", "InzoneCore", .product(name: "SwiftTUI", package: "swift-tui")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
