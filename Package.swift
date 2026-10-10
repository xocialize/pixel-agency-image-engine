// swift-tools-version: 6.2
import PackageDescription

// Pixel Agency Image Engine: the reference engine for the MES Image profile (Engines-PRD). MESEngineKit serves
// Base 0.1 (routes, jobs, spool, pairing, Bonjour, MCP); the model runtime is ML[X] Image Server's engine half
// (ImageServerModels: the catalog, routing, and the runner over MLXEngine and ForgeCore). This package adds the
// normalizer between them: MES operations and vocabulary in, model runs out, the profile's rules enforced.
//
//   PixelAgencyImageEngine     the normalizer (a MediaEngine), media I/O, the runtime bootstrap
//   pixel-agency-image-engine  the headless engine
let package = Package(
    name: "PixelAgencyImageEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PixelAgencyImageEngine", targets: ["PixelAgencyImageEngine"]),
        .executable(name: "pixel-agency-image-engine", targets: ["ImageEngineCLI"]),
    ],
    dependencies: [
        // Local checkouts until media-engine-spec is published and ImageServerModels has a repo of its own.
        .package(path: "../media-engine-spec"),
        .package(path: "../ml(x)/ML[X]-Image-Server/Packages/ImageServerKit"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "PixelAgencyImageEngine", dependencies: [
            .product(name: "MESCore", package: "media-engine-spec"),
            .product(name: "MESEngineCore", package: "media-engine-spec"),
            .product(name: "ImageServerModels", package: "ImageServerKit"),
            .product(name: "ImageServerAPI", package: "ImageServerKit"),
        ]),
        .executableTarget(name: "ImageEngineCLI", dependencies: [
            "PixelAgencyImageEngine",
            .product(name: "MESEngineKit", package: "media-engine-spec"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "ImageEngineTests", dependencies: [
            "PixelAgencyImageEngine",
            .product(name: "MESEngineKit", package: "media-engine-spec"),
            .product(name: "MESConformance", package: "media-engine-spec"),
            .product(name: "ImageServerModels", package: "ImageServerKit"),
            .product(name: "ImageServerAPI", package: "ImageServerKit"),
        ]),
    ]
)
