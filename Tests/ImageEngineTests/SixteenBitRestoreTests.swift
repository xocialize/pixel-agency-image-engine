import CoreGraphics
import Foundation
import ImageServerCatalog
import ImageServerModels
@testable import MESConformance
import MESCore
import MESEngineCore
import MLXToolKit
@testable import PixelAgencyImageEngine
import Testing

// G-6 wave 3 (AB-T-0230): `image.restore` with `output: {bit_depth: 16}`. A kind runs at 16 bits where its own route keeps
// them — general on NAFNet, faces on GFPGAN (or a named RestoreFormer++), denoise at draft on NAFNet — and nowhere a
// 16-bit request would have to switch models: denoise at standard and best (SCUNet), deblur (Restormer) and scratches
// (defect detection, then LaMa) stay 8 bits, stated in the schema.

@Suite("16-bit restore (G-6 wave 3)", .serialized)
struct SixteenBitRestoreTests {
    static let deep: Set<String> = ["nafnet-restore", "gfpgan-face", "restoreformer-face"]
    static let models = FakeModels(FakeModels.catalog + [
        FakeModels.model("gfpgan-face", [.imageRestore]), FakeModels.model("restoreformer-face", [.imageRestore]),
        FakeModels.model("restormer-defocus", [.imageRestore]), FakeModels.model("restormer-motion", [.imageRestore]),
    ])

    static func restoreDescriptor(_ restorers: Set<String>) async throws -> Descriptor {
        let ops = await ImageNormalizer(directory: models, runner: FakeRunner(),
                                        options: .init(sixteenBitRestorers: restorers)).descriptors()
        return try #require(ops.first { $0.operation == "image.restore" })
    }

    @Test("16 is offered on restore when a restorer keeps 16 bits; the schema states which kinds and qualities can't")
    func descriptor() async throws {
        let plain = try await Self.restoreDescriptor([])
        #expect(plain.params["properties"]?["output"]?["properties"]?["bit_depth"]?["enum"] == [8])
        #expect(plain.params["allOf"] == nil)

        let restore = try await Self.restoreDescriptor(Self.deep)
        let output = try #require(restore.params["properties"]?["output"]?["properties"])
        #expect(output["bit_depth"]?["enum"] == [8, 16])
        let description = try #require(output["bit_depth"]?["description"]?.stringValue)
        #expect(Self.deep.allSatisfy(description.contains), "\(description)")
        #expect(output["media_type"]?["enum"] == ["image/png", "image/jpeg", "image/tiff"])
        #expect(restore.outputs.first?.mediaTypes?.contains("image/tiff") == true)

        func allows(_ params: [String: MESValue]) -> Bool {
            SchemaValidator().validate(.object(params), against: restore.params).isEmpty
        }
        let sixteen: MESValue = ["media_type": "image/tiff", "bit_depth": 16]
        #expect(allows(["output": sixteen]), "no kind is general: NAFNet")
        for quality: MESValue in ["draft", "standard", "best"] {
            #expect(allows(["quality": quality, "output": sixteen]), "general \(quality)")
            #expect(allows(["kind": "general", "quality": quality, "output": sixteen]), "general \(quality)")
            #expect(allows(["kind": "faces", "quality": quality, "output": sixteen]), "faces \(quality)")
            #expect(!allows(["kind": "deblur", "quality": quality, "output": sixteen]), "deblur \(quality): Restormer")
            #expect(!allows(["kind": "scratches", "quality": quality, "output": sixteen]), "scratches \(quality)")
        }
        #expect(allows(["kind": "faces", "output": sixteen]) && allows(["kind": "general", "output": sixteen]))
        #expect(allows(["kind": "denoise", "quality": "draft", "output": sixteen]), "draft denoise is NAFNet")
        #expect(!allows(["kind": "denoise", "output": sixteen]) && !allows(["kind": "denoise", "quality": "standard", "output": sixteen])
                && !allows(["kind": "denoise", "quality": "best", "output": sixteen]), "standard and best denoise is SCUNet")
        #expect(!allows(["kind": "scratches", "output": sixteen]) && !allows(["kind": "deblur", "output": sixteen]))
        #expect(allows(["kind": "scratches", "output": ["bit_depth": 8]]) && allows(["kind": "deblur"]))
        let issue = try #require(SchemaValidator().validate(.object(["kind": "scratches", "output": sixteen]), against: restore.params).first)
        #expect(issue.path == "$.output.bit_depth", "so the refusal is about output: \(issue.path)")
    }

    @Test("bit_depth 16 runs each kind's own restorer end to end: raw 16 bits in, a 16-bit PNG or TIFF out at the same size")
    func runsAtSixteenBits() async throws {
        try await withEngine(models: Self.models, sixteenBitRestorers: Self.deep) { probe, runner in
            let cases: [(MESValue?, MESValue?, String?, String)] = [
                (nil, nil, nil, "nafnet-restore"), ("general", "best", nil, "nafnet-restore"),
                ("faces", nil, nil, "gfpgan-face"), ("faces", "best", "restoreformer-face", "restoreformer-face"),
                ("denoise", "draft", nil, "nafnet-restore"),
            ]
            for (kind, quality, model, expected) in cases {
                for type in ["image/png", "image/tiff"] {
                    var params: [String: MESValue] = ["output": ["media_type": .string(type), "bit_depth": 16]]
                    if let kind { params["kind"] = kind }
                    if let quality { params["quality"] = quality }
                    let job = try await probe.succeed(JobRequest(
                        operation: "image.restore", inputs: ["image": image(deepFile(width: 30, height: 20))], params: params,
                        model: model))
                    #expect(job.plan?.model.id == expected, "\(kind ?? "-") \(quality ?? "-")")
                    let sent = try #require(runner.calls.withLock { $0.last }?.inputs["image"]?.first)
                    #expect(sent.format == .rawRGBA16 && sent.width == 30 && sent.height == 20)
                    let (output, data) = try await probe.output(job)
                    #expect(output.mediaType == type)
                    let cg = try decode(data)
                    #expect(cg.bitsPerComponent == 16 && cg.width == 30 && cg.height == 20)
                    #expect(DeepPixels(cg).carriesMoreThanEightBits)
                    #expect(job.warnings.contains { $0.code == "bit_depth_reduced" } == false)
                }
            }
        }
    }

    @Test("bit_depth 16 on restore is refused at submit where the route is 8-bit: SCUNet, Restormer, scratches, a named 8-bit model, JPEG")
    func refusals() async throws {
        try await withEngine(models: Self.models, sixteenBitRestorers: Self.deep) { probe, _ in
            func submit(_ params: [String: MESValue], model: String? = nil) async throws -> (Int, String?) {
                var request = JobRequest(operation: "image.restore", inputs: ["image": image(deepFile(width: 16, height: 16))], params: params)
                request.model = model
                let reply = try await probe.wire.json("POST", "jobs", request)
                return (reply.status, reply.errorCode)
            }
            let sixteen: MESValue = ["bit_depth": 16]
            for params: [String: MESValue] in [
                ["kind": "denoise", "output": sixteen], ["kind": "denoise", "quality": "best", "output": sixteen],
                ["kind": "deblur", "output": sixteen], ["kind": "scratches", "output": sixteen],
                ["output": ["media_type": "image/jpeg", "bit_depth": 16]],
            ] {
                let reply = try await submit(params)
                #expect(reply.0 == 422 && reply.1 == "unsupported_parameter", "\(params)")
            }
            let named = try await submit(["kind": "denoise", "output": sixteen], model: "scunet-denoise")
            #expect(named.0 == 422 && named.1 == "unsupported_parameter")
            let scratchesNamed = try await submit(["kind": "scratches", "output": sixteen], model: "nafnet-restore")
            #expect(scratchesNamed.0 == 422 && scratchesNamed.1 == "unsupported_parameter")
            // The schema sees params, not the model: a named 16-bit restorer doesn't lift its kind's rule (denoise at
            // standard pins 8 even for NAFNet), and runs at 16 bits where the kind allows it. 8 bits is untouched.
            let namedDeep = try await submit(["kind": "denoise", "output": sixteen], model: "nafnet-restore")
            #expect(namedDeep.0 == 422 && namedDeep.1 == "unsupported_parameter")
            #expect(try await submit(["kind": "faces", "output": sixteen], model: "restoreformer-face").0 == 201)
            #expect(try await submit(["kind": "denoise", "output": ["bit_depth": 8]]).0 == 201)
        }
    }

    /// The real catalog, registered as the engine starts (no weights load): mlx-nafnet-swift ≥ 0.6.0 and mlx-gfpgan-swift /
    /// mlx-restoreformer-swift ≥ 0.3.0 declare `.rawRGBA16`, and the live descriptor follows.
    @Test("the real catalog's NAFNet, GFPGAN and RestoreFormer++ keep 16 bits, so restore offers it for general and faces")
    @MainActor
    func realCatalogKeepsSixteenBits() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("pa-16r-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let runtime = await ImageRuntime.start(modelStore: store, catalog: ModelCatalog.all(environment: [:]))
        #expect(runtime.normalizer.options.sixteenBitRestorers.isSuperset(of: Self.deep),
                "\(runtime.normalizer.options.sixteenBitRestorers.sorted())")
        let restore = try #require(await runtime.normalizer.descriptors().first { $0.operation == "image.restore" })
        func allows(_ params: [String: MESValue]) -> Bool {
            SchemaValidator().validate(.object(params), against: restore.params).isEmpty
        }
        let sixteen: MESValue = ["media_type": "image/png", "bit_depth": 16]
        #expect(allows(["output": sixteen]) && allows(["kind": "faces", "output": sixteen]))
        #expect(!allows(["kind": "scratches", "output": sixteen]))
    }
}
