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
        // ≥ 0.2.0: ModelOffer.notes, and MCP tool descriptions carry each offer's licence notice and notes (AB-A-0186).
        .package(url: "https://github.com/xocialize/media-engine-spec.git", from: "0.2.0"),
        // ≥ 0.3.9: CIDNet relights any image size, where 570×320 used to kill the engine (AB-T-0223); ≥ 0.3.8:
        // Z-Image, Klein and Qwen-Image report denoise step progress (AB-A-0139); ≥ 0.3.7: the restore
        // fleet reads the weights the engine downloaded instead of fetching a second copy (AB-A-0112); ≥ 0.3.4:
        // Mage-Flow Edit Turbo at int8, content filter off (AB-D-0122), erases by name (AB-T-0220); ≥ 0.3.3 made
        // every default offer's weights the engine's to download (AB-T-0221/0222).
        // ≥ 0.5.1: an enhancer result (VOSR2 behind the text guard) keeps a 16-bit request's depth (AB-T-0233).
        // ≥ 0.6.0: Anime4K VL (`anime4k-upscale`), Forge Optimizer's Instant tier, in the catalog by name (AB-A-0183).
        // ≥ 0.7.0: MOSS-Image SFT and Base (`moss-image-sft`, `moss-image-base`), best tier by name (AB-T-0307, in-app AB-R-0570).
        // ≥ 0.10.0: FLUX 3 Klein (`flux-3-klein`) on flux3-klein-swift 0.3.0, the row-band VAE decode: output up to
        // 2048², declared activation 12.0 GB, int4 admitted on a 24 GB Mac (AB-R-0579).
        .package(url: "https://github.com/xocialize/mlx-image-runtime.git", from: "0.13.0"),
        // ForgeCore's still enhancer: generative upscales behind the text-legibility guard (AB-D-0111). ≥ 0.35.0: the 16-bit
        // model boundary (AB-A-0158) — its graph brings mlx-engine-swift 0.67.0 (`.rawRGBA16`, contract 1.52.0) and
        // mlx-realplksr-swift 0.2.0, the first upscaler that keeps 16 bits. ≥ 0.36.0: mlx-nerve-swift and mlx-heart-swift
        // 0.2.0 keep 16 bits too (AB-T-0229), so draft, standard and best, and drawn content, all offer 16 bits. ≥ 0.37.0:
        // mlx-nafnet-swift 0.6.0 and mlx-gfpgan-swift / mlx-restoreformer-swift 0.3.0 keep 16 bits (AB-T-0230), so
        // image.restore offers 16 bits for general and faces. ≥ 0.38.0: mlx-vosr-swift 0.3.0 writes 16 bits and the text guard
        // sends each tier its own depth (MaskKit 0.4.1 composites at 16 bits), so VOSR2 runs at 16 bits by name (AB-T-0233).
        // ≥ 0.38.1: mlx-gfpgan-swift and mlx-restoreformer-swift 0.3.1 — no dark line along the image edge when a face's
        // crop extends past the frame, every close-up portrait (AB-T-0227). ≥ 0.41.1: `.upscaleInstant`, Anime4K VL as a
        // weightless imageUpscale registration that reads as nothing to download (AB-A-0183).
        .package(url: "https://github.com/xocialize/ForgeCore.git", from: "0.41.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // The CLI's quant-gate arms (`--quant-gate-arms`, AB-A-0178) configure these packages directly; all three are
        // already in the graph through mlx-image-runtime.
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.67.0"),
        .package(url: "https://github.com/xocialize/flux2-klein-swift.git", from: "0.8.1"),
        .package(url: "https://github.com/xocialize/sensenova-u1-swift.git", from: "0.5.1"),
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
            .product(name: "ImageServerAPI", package: "mlx-image-runtime"),
            .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            .product(name: "MLXKlein", package: "flux2-klein-swift"),
            .product(name: "MLXSenseNovaU1", package: "sensenova-u1-swift"),
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
