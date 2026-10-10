// swift-tools-version: 6.2
import PackageDescription

// Pixel Agency Image Engine: the reference engine for the MES Image profile (Engines-PRD). MESEngineKit serves
// Base 0.1 (routes, jobs, spool, pairing, Bonjour, MCP); the model runtime is mlx-image-runtime, ML[X] Image Server's
// engine half (ImageServerModels: the catalog, routing, and the runner over MLXEngine and ForgeCore). This package adds the
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
        .package(url: "https://github.com/xocialize/media-engine-spec.git", from: "0.1.0"),
        .package(url: "https://github.com/xocialize/mlx-image-runtime.git", from: "0.1.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "PixelAgencyImageEngine", dependencies: [
            .product(name: "MESCore", package: "media-engine-spec"),
            .product(name: "MESEngineCore", package: "media-engine-spec"),
            .product(name: "ImageServerModels", package: "mlx-image-runtime"),
            .product(name: "ImageServerAPI", package: "mlx-image-runtime"),
        ]),
        .executableTarget(name: "ImageEngineCLI", dependencies: [
            "PixelAgencyImageEngine",
            .product(name: "ImageServerCatalog", package: "mlx-image-runtime"),
            .product(name: "ImageServerModels", package: "mlx-image-runtime"),
            .product(name: "MESEngineKit", package: "media-engine-spec"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "ImageEngineTests", dependencies: [
            "PixelAgencyImageEngine",
            .product(name: "MESEngineKit", package: "media-engine-spec"),
            .product(name: "MESConformance", package: "media-engine-spec"),
            .product(name: "ImageServerModels", package: "mlx-image-runtime"),
            .product(name: "ImageServerAPI", package: "mlx-image-runtime"),
        ]),
    ]
)
