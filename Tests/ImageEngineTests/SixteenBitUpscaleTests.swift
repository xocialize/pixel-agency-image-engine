import CoreGraphics
import Foundation
import ImageIO
import ImageServerCatalog
import ImageServerModels
@testable import MESConformance
import MESCore
import MESEngineCore
import MLXToolKit
@testable import PixelAgencyImageEngine
import Testing
import UniformTypeIdentifiers

// G-6 (AB-A-0158): `image.upscale` with `output: {bit_depth: 16}`. Offered only when a model keeps 16 bits, honoured as
// PNG or TIFF on that model, refused at submit (422 unsupported_parameter, Image §1.2) everywhere else, so a client can
// fall back to its own restore around an 8-bit step.

/// A 16-bit sRGB PNG or TIFF: a red ramp finer than 8 bits, opaque.
func deepFile(width w: Int, height h: Int, type: UTType = .png) -> Data {
    var words = [UInt16](repeating: UInt16.max, count: w * h * 4)
    for y in 0..<h { for x in 0..<w { words[(y * w + x) * 4] = UInt16(10_000 + x * 13); words[(y * w + x) * 4 + 1] = 20_000 } }
    let cg = words.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!.makeImage()!
    }
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
    return out as Data
}

func decode(_ data: Data) throws -> CGImage {
    try #require(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
}

@Suite("16-bit upscale (G-6)", .serialized)
struct SixteenBitUpscaleTests {
    static let deep: Set<String> = ["realplksr-upscale"]

    @Test("16 is offered on upscale only when a model keeps 16 bits, and never on other operations")
    func descriptors() async throws {
        let plain = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner()).descriptors()
        let up8 = try #require(plain.first { $0.operation == "image.upscale" })
        #expect(up8.params["properties"]?["output"]?["properties"]?["bit_depth"]?["enum"] == [8])

        let ops = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner(),
                                        options: .init(sixteenBitUpscalers: Self.deep)).descriptors()
        let up = try #require(ops.first { $0.operation == "image.upscale" })
        let output = try #require(up.params["properties"]?["output"]?["properties"])
        #expect(output["bit_depth"]?["enum"] == [8, 16])
        #expect(output["bit_depth"]?["description"]?.stringValue?.contains("realplksr-upscale") == true)
        #expect(output["media_type"]?["enum"] == ["image/png", "image/jpeg", "image/tiff"])
        #expect(up.outputs.first?.mediaTypes?.contains("image/tiff") == true)
        for op in ops where op.operation != "image.upscale" {
            let depth = op.params["properties"]?["output"]?["properties"]?["bit_depth"]?["enum"]
            #expect(depth == nil || depth == [8], "\(op.operation)")
        }

        // Where 16 can't run is in the schema (Base §6 rule 4), so a client can check a request before sending it.
        func allows(_ params: [String: MESValue]) -> Bool {
            SchemaValidator().validate(.object(params), against: up.params).isEmpty
        }
        let sixteen: MESValue = ["bit_depth": 16]
        #expect(allows(["quality": "standard", "output": sixteen]) && allows(["output": sixteen]), "standard has RealPLKSR")
        #expect(!allows(["quality": "draft", "output": sixteen]) && !allows(["quality": "best", "output": sixteen]))
        #expect(!allows(["content": "drawn", "output": sixteen]) && !allows(["content": "drawn", "quality": "standard", "output": sixteen]),
                "drawn content keeps its NERVE route, which runs at 8 bits")
        #expect(allows(["quality": "draft", "output": ["bit_depth": 8]]) && allows(["content": "drawn", "quality": "best"]))
        let issue = try #require(SchemaValidator().validate(.object(["quality": "draft", "output": sixteen]), against: up.params).first)
        #expect(issue.path == "$.output.bit_depth", "so the refusal is about output: \(issue.path)")
        #expect(up8.params["allOf"] == nil, "no rule without a 16-bit model")
    }

    @Test("bit_depth 16 runs the 16-bit model end to end: raw 16 bits in, a 16-bit PNG or TIFF out at exactly ×scale")
    func runsAtSixteenBits() async throws {
        try await withEngine(sixteenBit: Self.deep) { probe, runner in
            for type in ["image/png", "image/tiff"] {
                let job = try await probe.succeed(JobRequest(
                    operation: "image.upscale", inputs: ["image": image(deepFile(width: 30, height: 20))],
                    params: ["scale": 4, "output": ["media_type": .string(type), "bit_depth": 16]]))
                #expect(job.plan?.model.id == "realplksr-upscale")
                let sent = try #require(runner.calls.withLock { $0.last }?.inputs["image"]?.first)
                #expect(sent.format == .rawRGBA16 && sent.width == 30 && sent.height == 20)
                let (output, data) = try await probe.output(job)
                #expect(output.mediaType == type)
                let cg = try decode(data)
                #expect(cg.bitsPerComponent == 16 && cg.width == 120 && cg.height == 80)
                // The fake's ramp (7 levels per pixel) survives: values off the 8-bit grid.
                let px = DeepPixels(cg)
                #expect(px.carriesMoreThanEightBits)
                #expect(job.warnings.contains { $0.code == "bit_depth_reduced" } == false)
            }
        }
    }

    @Test("bit_depth 16 is refused at submit where it can't be honoured: JPEG, an 8-bit model, a tier without one, other operations")
    func refusals() async throws {
        try await withEngine(sixteenBit: Self.deep) { probe, _ in
            func submit(_ op: String, _ params: [String: MESValue], model: String? = nil) async throws -> (Int, String?) {
                var request = JobRequest(operation: op, inputs: ["image": image(deepFile(width: 16, height: 16))], params: params)
                request.model = model
                let reply = try await probe.wire.json("POST", "jobs", request)
                return (reply.status, reply.errorCode)
            }
            let sixteen: MESValue = ["bit_depth": 16]
            let jpeg = try await submit("image.upscale", ["output": ["media_type": "image/jpeg", "bit_depth": 16]])
            #expect(jpeg.0 == 422 && jpeg.1 == "unsupported_parameter")
            let eightBitModel = try await submit("image.upscale", ["output": sixteen], model: "nerve-upscale")
            #expect(eightBitModel.0 == 422 && eightBitModel.1 == "unsupported_parameter")
            let draft = try await submit("image.upscale", ["quality": "draft", "output": sixteen])
            #expect(draft.0 == 422 && draft.1 == "unsupported_parameter")
            let best = try await submit("image.upscale", ["quality": "best", "output": sixteen])
            #expect(best.0 == 422 && best.1 == "unsupported_parameter")
            // Drawn content keeps its route: NERVE at standard, which runs at 8 bits (no switch to RealPLKSR).
            let drawn = try await submit("image.upscale", ["content": "drawn", "quality": "standard", "output": sixteen])
            #expect(drawn.0 == 422 && drawn.1 == "unsupported_parameter")
            // Other operations don't offer 16 at all: the descriptor's schema refuses it (MES 0.1.3, AB-T-0231).
            let restore = try await submit("image.restore", ["output": sixteen])
            #expect(restore.0 == 422 && restore.1 == "unsupported_parameter")
            // And 8 bits is untouched.
            let eight = try await submit("image.upscale", ["output": ["bit_depth": 8]])
            #expect(eight.0 == 201)
        }
    }

    @Test("without a 16-bit model, upscale refuses bit_depth 16 too")
    func noSixteenBitModel() async throws {
        try await withEngine { probe, _ in
            let request = JobRequest(operation: "image.upscale", inputs: ["image": image(deepFile(width: 16, height: 16))],
                                     params: ["output": ["bit_depth": 16]])
            let reply = try await probe.wire.json("POST", "jobs", request)
            #expect(reply.status == 422)
        }
    }

    /// Wave 2 (AB-T-0229, ForgeCore 0.36.0): NERVE and HEART keep 16 bits too.
    static let wave2: Set<String> = ["realplksr-upscale", "nerve-upscale", "heart-upscale"]

    /// Every quality and drawn route, by the descriptor's schema alone (what Pixel Agency Desktop checks before sending).
    static func expectSixteenBitsEverywhere(_ up: Descriptor, sourceLocation: SourceLocation = #_sourceLocation) {
        func allows(_ params: [String: MESValue]) -> Bool {
            SchemaValidator().validate(.object(params), against: up.params).isEmpty
        }
        let sixteen: MESValue = ["media_type": "image/tiff", "bit_depth": 16]
        #expect(allows(["output": sixteen]) && allows(["content": "drawn", "output": sixteen]), sourceLocation: sourceLocation)
        for quality: MESValue in ["draft", "standard", "best"] {
            #expect(allows(["quality": quality, "output": sixteen]), "\(quality)", sourceLocation: sourceLocation)
            #expect(allows(["content": "drawn", "quality": quality, "output": sixteen]), "drawn \(quality)",
                    sourceLocation: sourceLocation)
        }
        // JSON Schema's allOf must be non-empty: with nothing pinned to 8 bits there are no rules at all.
        #expect(up.params["allOf"] == nil, sourceLocation: sourceLocation)
    }

    @Test("with NERVE, RealPLKSR and HEART at 16 bits, every quality and drawn content allow bit_depth 16 and no allOf is left")
    func everyTierAtSixteenBits() async throws {
        let ops = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner(),
                                        options: .init(sixteenBitUpscalers: Self.wave2)).descriptors()
        let up = try #require(ops.first { $0.operation == "image.upscale" })
        let description = try #require(up.params["properties"]?["output"]?["properties"]?["bit_depth"]?["description"]?.stringValue)
        #expect(Self.wave2.allSatisfy(description.contains), "\(description)")
        Self.expectSixteenBitsEverywhere(up)
    }

    @Test("at 16 bits each quality runs its own model — NERVE at draft, RealPLKSR at standard, HEART at best — and drawn content keeps its route")
    func eachTierRunsItsOwnModelAtSixteenBits() async throws {
        try await withEngine(sixteenBit: Self.wave2) { probe, runner in
            let cases: [(MESValue?, MESValue, String)] = [
                (nil, "draft", "nerve-upscale"), (nil, "standard", "realplksr-upscale"), (nil, "best", "heart-upscale"),
                ("drawn", "draft", "nerve-upscale"), ("drawn", "standard", "nerve-upscale"), ("drawn", "best", "heart-upscale"),
            ]
            for (content, quality, model) in cases {
                var params: [String: MESValue] = ["scale": 4, "quality": quality,
                                                  "output": ["media_type": "image/png", "bit_depth": 16]]
                if let content { params["content"] = content }
                let job = try await probe.succeed(JobRequest(
                    operation: "image.upscale", inputs: ["image": image(deepFile(width: 24, height: 16))], params: params))
                #expect(job.plan?.model.id == model, "\(content ?? "photo") \(quality)")
                let sent = try #require(runner.calls.withLock { $0.last }?.inputs["image"]?.first)
                #expect(sent.format == .rawRGBA16)
                let (_, data) = try await probe.output(job)
                let cg = try decode(data)
                #expect(cg.bitsPerComponent == 16 && cg.width == 96 && cg.height == 64)
                #expect(job.warnings.contains { $0.code == "bit_depth_reduced" } == false)
            }
        }
    }

    /// The real catalog, registered as the engine starts (no weights load): the manifests of mlx-nerve-swift,
    /// mlx-realplksr-swift and mlx-heart-swift ≥ 0.2.0 declare `.rawRGBA16`, and the live descriptor follows.
    @Test("the real catalog's NERVE, RealPLKSR and HEART keep 16 bits, so the live descriptor offers it everywhere")
    @MainActor
    func realCatalogKeepsSixteenBits() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("pa-16-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let runtime = await ImageRuntime.start(modelStore: store, catalog: ModelCatalog.all(environment: [:]))
        #expect(runtime.normalizer.options.sixteenBitUpscalers.isSuperset(of: Self.wave2),
                "\(runtime.normalizer.options.sixteenBitUpscalers.sorted())")
        let up = try #require(await runtime.normalizer.descriptors().first { $0.operation == "image.upscale" })
        Self.expectSixteenBitsEverywhere(up)
    }

    @Test("16-bit pixels: load keeps 16 bits, and alpha is re-applied at 16 bits")
    func deepMedia() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deep-\(UUID().uuidString).tiff")
        try deepFile(width: 40, height: 10, type: .tiff).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try Media.loadDeep(url)
        #expect(loaded.pixels.width == 40 && loaded.pixels.carriesMoreThanEightBits)
        #expect(try Media.deepPixels(Media.modelImage(loaded.pixels)).rgba == loaded.pixels.rgba)

        var input = DeepPixels(width: 2, height: 1, rgba: [100, 100, 100, 65535, 400, 400, 400, 32768])
        input.rgba[7] = 32768
        let opaque = DeepPixels(width: 2, height: 1, rgba: [1000, 2000, 3000, 65535, 1000, 2000, 3000, 65535])
        let out = Media.reapplyAlpha(opaque, from: input)
        #expect(Array(out.rgba[0..<4]) == [1000, 2000, 3000, 65535])
        #expect(out.rgba[7] == 32768 && out.rgba[4] == 500)
    }
}
