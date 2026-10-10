// swift-tools-version: 6.2
import PackageDescription

// tier-bench: measures the Image Engine's quality tiers end to end (ENG R1b, Engines-PRD OQ-5). It drives a running
// engine through MESClientKit, exactly as a client does, and scores what comes back against ground truth where the
// corpus has it (DIV2K for upscale and restore, GrabCut for segment). Measurement only: the corpora are research
// sets and nothing here ships.
let package = Package(
    name: "TierBench",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/xocialize/media-engine-spec.git", from: "0.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(name: "TierBench", dependencies: [
            .product(name: "MESCore", package: "media-engine-spec"),
            .product(name: "MESClientKit", package: "media-engine-spec"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
    ]
)
