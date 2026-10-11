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
        // ≥ 0.3.9: CIDNet relights any image size, where 570×320 used to kill the engine (AB-T-0223); ≥ 0.3.8:
        // Z-Image, Klein and Qwen-Image report denoise step progress (AB-A-0139); ≥ 0.3.7: the restore
        // fleet reads the weights the engine downloaded instead of fetching a second copy (AB-A-0112); ≥ 0.3.4:
        // Mage-Flow Edit Turbo at int8, content filter off (AB-D-0122), erases by name (AB-T-0220); ≥ 0.3.3 made
        // every default offer's weights the engine's to download (AB-T-0221/0222).
        .package(url: "https://github.com/xocialize/mlx-image-runtime.git", from: "0.3.9"),
        // ForgeCore's still enhancer: generative upscales behind the text-legibility guard (AB-D-0111). ≥ 0.35.0: the 16-bit
        // model boundary (AB-A-0158) — its graph brings mlx-engine-swift 0.67.0 (`.rawRGBA16`, contract 1.52.0) and
        // mlx-realplksr-swift 0.2.0, the first upscaler that keeps 16 bits.
        .package(url: "https://github.com/xocialize/ForgeCore.git", from: "0.35.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "PixelAgencyImageEngine", dependencies: [
            .product(name: "ForgeCore", package: "ForgeCore"),
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
            // The real catalog, for the hub check of every default offer's first download.
            .product(name: "ImageServerCatalog", package: "mlx-image-runtime"),
        ]),
    ]
)
