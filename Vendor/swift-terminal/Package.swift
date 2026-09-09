// swift-tools-version: 6.3

import PackageDescription

let dependencies: [Package.Dependency] = {
    [
        .package(
            url: "https://github.com/apple/swift-numerics",
            from: "1.0.0",
        ),
        .package(
            url: "https://github.com/apple/swift-system",
            from: "1.7.2",
        ),
    ]
}()

let terminalDependencies: [Target.Dependency] = {
    var dependencies = [
        .product(
            name: "Numerics",
            package: "swift-numerics",
        ),
    ] as [Target.Dependency]
#if !canImport(System)
    dependencies.append(
        .product(
            name: "SystemPackage",
            package: "swift-system",
        ),
    )
#endif
    return dependencies
}()

let swiftSettings: [SwiftSetting] = [
    .defaultIsolation(nil),
    .strictMemorySafety(),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "swift-terminal",
    platforms: [
        .macOS(.v11),
    ],
    products: [
        .library(
            name: "Terminal",
            targets: ["Terminal"],
        ),
    ],
    dependencies: dependencies,
    targets: [
        .target(
            name: "Terminal",
            dependencies: terminalDependencies,
            swiftSettings: swiftSettings,
        ),
    ],
    swiftLanguageModes: [.v6],
)
