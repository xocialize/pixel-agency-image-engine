import Foundation
import ImageServerAPI
import ImageServerModels
@testable import MESConformance
import MESCore
import MESEngineCore
import MESEngineKit
@testable import PixelAgencyImageEngine
import Testing

// ENG R1 exit (Engines-PRD §7): the Image Engine's normalizer passes MES conformance, offers research models only
// when the operator opts in (and then named-only), and applies the Image profile's rules whatever the models return.

func config() -> EngineConfiguration {
    let spool = FileManager.default.temporaryDirectory.appendingPathComponent("pa-image-engine-\(UUID().uuidString)")
    var c = EngineConfiguration(id: "eng_image_test", name: "Pixel Agency Image Engine (test)",
                                implementationName: "pixel-agency-image-engine", implementationVersion: "0.1.0", spoolDirectory: spool)
    c.advertise = false
    c.sweepInterval = .milliseconds(200)
    return c
}

/// Serves a normalizer over fakes on a free loopback port, connected with the conformance suite's probe.
func withEngine(research: Bool = false, residency: Residency.Policy = .init(), runner: FakeRunner = FakeRunner(),
                models: FakeModels = FakeModels(), sixteenBit: Set<String> = [], sixteenBitRestorers: Set<String> = [],
                tiled: Set<String> = [], creativeUnavailable: String? = nil, enablement: ModelEnablement? = nil,
                promptEnhanceTimeout: Duration = .seconds(60),
                _ body: (Probe, FakeRunner) async throws -> Void) async throws {
    let engine = ImageNormalizer(directory: models, runner: runner, textRunner: runner,
                                 options: .init(allowResearch: research, enablement: enablement, residency: residency,
                                                sixteenBitUpscalers: sixteenBit, sixteenBitRestorers: sixteenBitRestorers,
                                                tiledEditors: tiled, creativeUnavailable: creativeUnavailable,
                                                promptEnhanceTimeout: promptEnhanceTimeout))
    let server = MESEngineServer(engine: engine, configuration: config())
    let (ports, continuation) = AsyncStream<Int>.makeStream()
    let app = try await server.makeApplication { port in continuation.yield(port) }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await app.runService() }
        var it = ports.makeAsyncIterator()
        guard let port = await it.next() else { return }
        let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
        try await body(probe, runner)
        group.cancelAll()
    }
}

func image(_ data: Data = Fixtures.png()) -> RequestInput { .one(.inline(mediaType: "image/png", data: data)) }

extension DecodedImage {
    /// How many pixels match `test` (RGBA).
    func pixels(where test: ([UInt8]) -> Bool) -> Int {
        (0..<height).reduce(0) { n, y in n + (0..<width).filter { test(pixel($0, y)) }.count }
    }
}

@Suite("Pixel Agency Image Engine", .serialized)
struct ImageEngineTests {
    @Test("Conformance: every applicable BASE and IMAGE test passes against the normalizer")
    func conformance() async throws {
        try await withEngine { probe, _ in
            let report = await ConformanceRunner.run(probe)
            let failed = report.results.filter { $0.status == .fail }.map { "\($0.id): \($0.detail ?? "")" }
            #expect(failed.isEmpty, "\(failed.joined(separator: "\n"))")
            #expect(report.conformsToBase && report.conformsToImage == true)
            // The prompt enhancer's preview runs (AB-D-0155, E5), not skipped.
            #expect(report.results.first { $0.id == "IMAGE-011" }?.status == .pass)
        }
    }

    @Test("Descriptors: all 13 operations, licences in MES terms, the PRD's tier defaults; research models hidden")
    func descriptors() async throws {
        let engine = ImageNormalizer(directory: FakeModels(), runner: FakeRunner())
        let ops = await engine.descriptors()
        #expect(ops.count == 13)
        let generate = try #require(ops.first { $0.operation == "image.generate" })
        #expect(generate.models.first?.id == "z-image-turbo" && generate.models.first?.isDefault == true)
        #expect(generate.models.map(\.id).contains("qwen-image-2.1") == false)
        #expect(generate.qualityTiers == [.draft, .standard, .best])
        let moss = try #require(generate.models.first { $0.id == "moss-image-sft" }, "MOSS-Image is offered (AB-T-0307)")
        #expect(moss.isDefault != true && moss.qualityTiers == [.best] && moss.speedClass == .slow)
        let klein = try #require(generate.models.first { $0.id == "klein-4b" })
        #expect(klein.qualityTiers == [.draft] && klein.license.commercialUse == .yes && klein.license.spdx == "Apache-2.0")
        let fill = try #require(ops.first { $0.operation == "image.fill" })
        #expect(fill.models.first?.id == "lama-inpaint" && fill.models.contains { $0.id == "klein-4b" })
        #expect(ops.first { $0.operation == "image.extend" }?.models.first?.id == "lama-inpaint")
        let edit = try #require(ops.first { $0.operation == "image.edit" })
        #expect(edit.models.map(\.id) == ["klein-4b", "mage-flow-edit-turbo"])            // boogu is work in progress
        #expect(edit.inputs.first { $0.name == "images" }?.max == 4)
        let upscale = try #require(ops.first { $0.operation == "image.upscale" })
        #expect(upscale.params["properties"]?["content"]?["enum"] == ["photo", "drawn"])
    }

    @Test("--allow-research offers research and WIP models named-only, with their terms; the default never picks them")
    func researchModels() async throws {
        try await withEngine(research: true) { probe, runner in
            let generate = try #require(probe.descriptor("image.generate"))
            let qwen = try #require(generate.models.first { $0.id == "qwen-image-2.1" })
            #expect(qwen.namedOnly == true && qwen.isDefault == nil)
            #expect(qwen.license.commercialUse == .no && qwen.license.acceptedRequired == true)
            #expect(qwen.license.spdx == "LicenseRef-Qwen-Research")
            #expect(qwen.license.notice == "Research licence (LicenseRef-Qwen-Research): not for commercial use. Read the terms before you use or share results.")
            let boogu = probe.descriptor("image.edit")?.models.first { $0.id == "boogu" }
            #expect(boogu?.namedOnly == true && boogu?.license.notice == "Work in progress: results may change between versions.")
            // FLUX 3 Klein (AB-D-0151): named-only on both operations, with its own notice (not "research licence").
            for operation in ["image.generate", "image.edit"] {
                let flux = try #require(probe.descriptor(operation)?.models.first { $0.id == "flux-3-klein" })
                #expect(flux.namedOnly == true && flux.isDefault == nil)
                #expect(flux.license.commercialUse == .no && flux.license.acceptedRequired == true)
                #expect(flux.license.spdx == "LicenseRef-FLUX-Kommunity-1.0")
                #expect(flux.license.notice?.hasPrefix("FLUX Kommunity licence: non-commercial use; commercial use of outputs only for businesses under US$5M revenue") == true)
                #expect(flux.license.notice?.hasSuffix("Work in progress: results may change between versions.") == true)
                // Its prompting guidance (AB-A-0186): short requests are fine, quoted text renders; no licence wording.
                let notes = try #require(flux.notes)
                #expect(notes.hasPrefix("Short requests are fine") && notes.contains("in quotes") && !notes.contains("licen"))
            }
            #expect(qwen.notes == nil, "a model without guidance offers no notes")
            #expect(probe.descriptor("image.edit")?.inputs.first { $0.name == "images" }?.max == 10)

            // Unnamed at best quality: the measured best (Z-Image Turbo), never the research model.
            let best = try await probe.succeed(JobRequest(operation: "image.generate", inputs: ["prompt": .text("a fox")],
                                                         params: ["quality": "best", "size": ["width": 256, "height": 256]]))
            #expect(best.plan?.model.id == "z-image-turbo")
            // Named: it runs, and the plan carries its licence.
            let named = try await probe.succeed(JobRequest(operation: "image.generate", inputs: ["prompt": .text("a fox")],
                                                          params: ["size": ["width": 256, "height": 256]], model: "qwen-image-2.1"))
            #expect(named.plan?.model.id == "qwen-image-2.1" && named.plan?.model.license.commercialUse == .no)
            #expect(runner.calls.withLock { $0.last?.route.id.rawValue } == "qwen-image-2.1")
            // A commercial-use policy refuses it.
            let refused = try await probe.wire.json("POST", "jobs", JobRequest(
                operation: "image.generate", inputs: ["prompt": .text("a fox")], model: "qwen-image-2.1",
                policy: Policy(license: .commercialUse)))
            #expect(refused.status == 422 && refused.json?["error"]?["code"] == "policy_unmet")
        }
    }

    @Test("generate: sizes snap to the model's envelope with size_snapped; negative prompts warn where unused")
    func generateRules() async throws {
        try await withEngine { probe, runner in
            let job = try await probe.succeed(JobRequest(
                operation: "image.generate", inputs: ["prompt": .text("a lighthouse")],
                params: ["size": ["width": 500, "height": 300], "negative_prompt": "blur", "count": 2, "seed": 7]))
            #expect(job.warnings.map(\.code).sorted() == ["negative_prompt_ignored", "size_snapped"])
            #expect(job.result?.effective["size"] == ["width": 496, "height": 288])
            #expect(job.result?.outputs.count == 2 && job.result?.outputs.allSatisfy { $0.width == 496 && $0.height == 288 } == true)
            #expect(job.result?.provenance.seed == 7)
            #expect(runner.calls.withLock { $0.suffix(2).map(\.seed) } == [7, 8])
            #expect(runner.calls.withLock { $0.last?.spec.params["negativePrompt"] } == nil)

            // Klein uses guidance, so the negative prompt reaches it; aspect + megapixels picks the size.
            let klein = try await probe.succeed(JobRequest(
                operation: "image.generate", inputs: ["prompt": .text("a lighthouse")],
                params: ["quality": "draft", "aspect": "16:9", "megapixels": 0.25, "negative_prompt": "blur"]))
            #expect(klein.plan?.model.id == "klein-4b")
            #expect(runner.calls.withLock { $0.last?.spec.params["negativePrompt"] } == "blur")
            let size = klein.result?.effective["size"]
            #expect(size?["width"]?.intValue == 656 && size?["height"]?.intValue == 368)
        }
    }

    @Test("edit takes the first image's size; upscale is exactly ×scale; restore keeps size and alpha")
    func sizes() async throws {
        try await withEngine { probe, _ in
            let edit = try await probe.succeed(JobRequest(operation: "image.edit",
                                                          inputs: ["images": image(Fixtures.png(width: 80, height: 48)),
                                                                   "instruction": .text("make it green")]))
            #expect(edit.result?.outputs.first?.width == 80 && edit.result?.outputs.first?.height == 48)
            for scale in [2, 4] {
                let up = try await probe.succeed(JobRequest(operation: "image.upscale", inputs: ["image": image(Fixtures.png(width: 30, height: 20))],
                                                            params: ["scale": .number(Double(scale))]))
                #expect(up.result?.outputs.first?.width == 30 * scale && up.result?.outputs.first?.height == 20 * scale)
            }
        }
    }

    @Test("restore picks its network by kind unless one is named; scratches detect, then inpaint only the defects")
    func restore() async throws {
        try await withEngine { probe, runner in
            let general = try await probe.succeed(JobRequest(operation: "image.restore", inputs: ["image": image()]))
            #expect(general.plan?.model.id == "nafnet-restore")
            let denoise = try await probe.succeed(JobRequest(operation: "image.restore", inputs: ["image": image()], params: ["kind": "denoise"]))
            #expect(denoise.plan?.model.id == "scunet-denoise" && denoise.result?.provenance.model.id == "scunet-denoise")
            let quick = try await probe.succeed(JobRequest(operation: "image.restore", inputs: ["image": image()],
                                                           params: ["kind": "denoise", "quality": "draft"]))
            #expect(quick.plan?.model.id == "nafnet-restore", "draft denoise is NAFNet: ~50× faster, 0.7 dB behind")
            let named = try await probe.succeed(JobRequest(operation: "image.restore", inputs: ["image": image()],
                                                           params: ["kind": "denoise"], model: "nafnet-restore"))
            #expect(named.plan?.model.id == "nafnet-restore")

            let scratches = try await probe.succeed(JobRequest(operation: "image.restore", inputs: ["image": image()], params: ["kind": "scratches"]))
            let steps = runner.calls.withLock { $0.suffix(2).map(\.route.capability) }
            #expect(steps == [.defectDetect, .imageInpaint])
            #expect(scratches.result?.effective["model_params"]?["detector"] == "defect-detect")
            // Pixels the detector didn't flag are the input's exactly (the matte's centre half is the defect).
            let out = try DecodedImage(try await probe.output(scratches).1), src = try DecodedImage(Fixtures.png())
            #expect(out.pixel(0, 0) == src.pixel(0, 0) && out.pixel(63, 47) == src.pixel(63, 47))
        }
    }

    @Test("extend: LaMa continues the picture by default; with a prompt an edit model paints the border; the original is kept exactly")
    func extend() async throws {
        try await withEngine { probe, runner in
            let canvas: MESValue = ["left": 16, "top": 0, "right": 16, "bottom": 8]
            let src = try DecodedImage(Fixtures.png())
            let plain = try await probe.succeed(JobRequest(operation: "image.extend", inputs: ["image": image()], params: ["canvas": canvas]))
            #expect(plain.plan?.model.id == "lama-inpaint" && plain.warnings.isEmpty)
            #expect(plain.result?.effective["model_params"]?["variant"] == "lama")
            let lama = try DecodedImage(try await probe.output(plain).1)
            #expect(lama.width == 96 && lama.height == 56 && lama.pixel(0, 0) == [255, 0, 255, 255] && lama.pixel(16 + 10, 5) == src.pixel(10, 5))

            let painted = try await probe.succeed(JobRequest(operation: "image.extend", inputs: ["image": image(), "prompt": .text("more forest")],
                                                             params: ["canvas": canvas, "seed": 5]))
            #expect(painted.plan?.model.id == "klein-4b" && painted.result?.provenance.seed == 5)
            let (shown, seam) = runner.calls.withLock { ($0[$0.count - 2], $0[$0.count - 1]) }
            #expect(seam.route.capability == .imageInpaint && painted.result?.effective["model_params"]?["seam"] == "lama-inpaint")
            #expect(shown.route.capability == .imageEdit && shown.width == 96 && shown.height == 48)   // 96×56 fitted to ×16
            #expect(shown.spec.params["prompt"]?.stringValue?.hasPrefix("Replace the bright magenta areas at the left, right and bottom edges") == true)
            #expect(shown.spec.params["prompt"]?.stringValue?.contains("showing more forest") == true)
            let marked = try DecodedImage(shown.inputs["images"]![0].data)
            #expect(marked.pixel(0, 0) == [255, 0, 255, 255] && marked.pixel(16 + 10, 5) == src.pixel(10, 5))
            let band = try DecodedImage(seam.inputs["mask"]![0].data)
            #expect(band.pixel(15, 20)[0] == 255 && band.pixel(16, 20)[0] == 0 && band.pixel(0, 20)[0] == 0)   // 8 px wide, new side only
            let out = try DecodedImage(try await probe.output(painted).1)
            #expect(out.width == 96 && out.height == 56 && out.pixel(16 + 63, 47) == src.pixel(63, 47))
            #expect(out.pixel(0, 0) == [51, 204, 51, 255])                       // the new area is the model's
            #expect(out.pixel(12, 20) == [255, 0, 255, 255])                     // the seam band is LaMa's (the fake's magenta)

            let draft = try await probe.succeed(JobRequest(operation: "image.extend", inputs: ["image": image()],
                                                           params: ["canvas": canvas, "quality": "draft"]))
            #expect(draft.plan?.model.id == "lama-inpaint" && draft.result?.effective["model_params"]?["variant"] == "mi-gan")
        }
    }

    @Test("fill with a prompt paints with an edit model; without one LaMa fills; models see a hard hole, the composite blends")
    func fill() async throws {
        try await withEngine { probe, runner in
            let soft = Fixtures.mask()
            let painted = try await probe.succeed(JobRequest(operation: "image.fill",
                                                             inputs: ["image": image(), "mask": .one(.inline(mediaType: "image/png", data: soft)),
                                                                      "prompt": .text("a snowy owl")]))
            #expect(painted.plan?.model.id == "klein-4b")
            let instruction = runner.calls.withLock { $0.last!.spec.params["prompt"]?.stringValue } ?? ""
            #expect(instruction.contains("magenta area with a snowy owl"))
            let best = try await probe.succeed(JobRequest(operation: "image.fill", inputs: ["image": image(), "mask": .one(.inline(mediaType: "image/png", data: soft)),
                                                                                         "prompt": .text("a snowy owl")], params: ["quality": "best"]))
            #expect(best.plan?.model.id == "klein-4b", "Klein paints at every tier (R1b)")

            let plain = try await probe.succeed(JobRequest(operation: "image.fill", inputs: ["image": image(), "mask": .one(.inline(mediaType: "image/png", data: soft))],
                                                           params: ["quality": "best"]))
            #expect(plain.plan?.model.id == "lama-inpaint" && plain.result?.effective["model_params"]?["variant"] == "lama")
            #expect(runner.calls.withLock { $0.last!.spec.mode } == nil)
            let erase = try await probe.succeed(JobRequest(operation: "image.erase", inputs: ["image": image(), "mask": .one(.inline(mediaType: "image/png", data: soft))],
                                                           params: ["quality": "standard"]))
            #expect(erase.result?.effective["model_params"]?["variant"] == "lama")       // LaMa-fp32 since 0.3.1 (AB-R-0451)
            #expect(runner.calls.withLock { $0.last!.spec.mode } == nil)
            let quick = try await probe.succeed(JobRequest(operation: "image.erase", inputs: ["image": image(), "mask": .one(.inline(mediaType: "image/png", data: soft))],
                                                           params: ["quality": "draft"]))
            #expect(quick.result?.effective["model_params"]?["variant"] == "mi-gan")
            let work = runner.calls.withLock { $0.last! }
            #expect(work.spec.mode == "fast")
            let hole = try DecodedImage(work.inputs["mask"]![0].data)
            #expect(Set(stride(from: 0, to: hole.rgba.count, by: 4).map { hole.rgba[$0] }).isSubset(of: [0, 255]))
        }
    }

    @Test("segment points arrive at the model in pixels")
    func segment() async throws {
        try await withEngine { probe, runner in
            let segment = try await probe.succeed(JobRequest(operation: "image.segment", inputs: [
                "image": image(), "points": .one(.data([["x": 0.5, "y": 0.25, "label": "include"], ["x": 0.1, "y": 0.1, "label": "exclude"]])),
            ]))
            #expect(segment.result?.outputs.first?.kind == .mask && segment.result?.outputs.first?.width == 64)
            let params = runner.calls.withLock { $0.last!.spec.params }
            let points = params["points"]?.arrayValue?.map { $0.arrayValue?.compactMap(\.doubleValue) ?? [] } ?? []
            let expected: [[Double]] = [[32, 12], [6.4, 4.8]]
            #expect(points.count == 2 && zip(points, expected).allSatisfy { a, b in zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 } })
            #expect(params["pointLabels"] == [1, 0])
        }
    }

    @Test("describe and score: the profile's data shapes from a chatty model and an out-of-range score")
    func analysis() async throws {
        try await withEngine { probe, _ in
            let describe = try await probe.succeed(JobRequest(operation: "image.describe", inputs: ["image": image()]))
            let value = describe.result?.outputs.first?.value
            #expect(value?["caption"] == "A test card." && value?["tags"] == ["test", "card"] && value?["language"] == "en")
            let score = try await probe.succeed(JobRequest(operation: "image.score", inputs: ["image": image()]))
            #expect(score.result?.outputs.first?.value?["score"] == 1 && score.result?.outputs.first?.value?["raw"]?.numberValue == 1.4)
        }
    }

    @Test("Harmonize: a model's tone shift is corrected at the seam, fades with distance, and never touches the original")
    func harmonize() {
        let (w, h) = (256, 64)
        let original = Pixels(width: w, height: h, rgba: Array(repeating: [100, 100, 100, 255], count: w * h).flatMap { $0 })
        let shifted = Pixels(width: w, height: h, rgba: Array(repeating: [140, 140, 140, 255], count: w * h).flatMap { $0 })
        let region = Mask(width: w, height: h, values: (0..<(w * h)).map { $0 % w >= 128 ? 255 : 0 })
        let out = Media.harmonize(shifted, toward: original, region: region)
        func grey(_ x: Int) -> Int { Int(out.rgba[(32 * w + x) * 4]) }
        #expect(abs(grey(128) - 100) <= 3, "at the seam: \(grey(128))")
        #expect(grey(160) > grey(130) && abs(grey(255) - 140) <= 3, "fades: \(grey(160)), far: \(grey(255))")
        #expect(grey(10) == 140, "outside the region the result is left as it was (the composite takes the original)")
    }

    @Test("Each tier runs its measured default, whatever the catalog order; drawn content upscales with NERVE, HEART at best")
    func tierDefaults() async throws {
        try await withEngine { probe, _ in
            func model(_ op: String, _ inputs: [String: RequestInput], _ params: [String: MESValue]) async throws -> String? {
                try await probe.succeed(JobRequest(operation: op, inputs: inputs, params: params)).plan?.model.id
            }
            let small = image(Fixtures.png(width: 32, height: 24))
            let upscale = [try await model("image.upscale", ["image": small], ["quality": "draft"]),
                           try await model("image.upscale", ["image": small], [:]),
                           try await model("image.upscale", ["image": small], ["quality": "best"])]
            #expect(upscale == ["nerve-upscale", "realplksr-upscale", "heart-upscale"])
            let drawn = [try await model("image.upscale", ["image": small], ["quality": "draft", "content": "drawn"]),
                         try await model("image.upscale", ["image": small], ["content": "drawn"]),
                         try await model("image.upscale", ["image": small], ["quality": "best", "content": "drawn"])]
            #expect(drawn == ["nerve-upscale", "nerve-upscale", "heart-upscale"], "the G-4 drawn ladder (AB-R-0486)")
            // Anime4K VL (AB-A-0183): never a default, run when named at every quality, drawn or not.
            for quality: MESValue in ["draft", "standard", "best"] {
                let named = try await probe.succeed(JobRequest(operation: "image.upscale", inputs: ["image": small],
                                                               params: ["quality": quality, "content": "drawn"],
                                                               model: "anime4k-upscale"))
                #expect(named.plan?.model.id == "anime4k-upscale")
            }
            let points: RequestInput = .one(.data([["x": 0.5, "y": 0.5, "label": "include"]]))
            // Segment's vocabulary has no `quality` (Image §5): its default is the standard tier's model.
            #expect(try await model("image.segment", ["image": image(), "points": points], [:]) == "sam21-segment")
            let generate = [try await model("image.generate", ["prompt": .text("x")], ["quality": "draft", "size": ["width": 64, "height": 64]]),
                            try await model("image.generate", ["prompt": .text("x")], ["size": ["width": 64, "height": 64]]),
                            try await model("image.generate", ["prompt": .text("x")], ["quality": "best", "size": ["width": 64, "height": 64]])]
            #expect(generate == ["klein-4b", "z-image-turbo", "z-image-turbo"], "Z-Image measured below Turbo (R1b)")
            let masked: [String: RequestInput] = ["image": image(), "mask": .one(.inline(mediaType: "image/png", data: Fixtures.mask()))]
            let erase = [try await model("image.erase", masked, ["quality": "draft"]), try await model("image.erase", masked, [:]),
                         try await model("image.erase", masked, ["quality": "best"])]
            #expect(erase == ["lama-inpaint", "lama-inpaint", "mage-flow-edit-turbo"], "Mage erases by name at best (R2)")
        }
    }

    @Test("Residency (ENG-3): one heavy model at a time, small ones stay, idle ones are released")
    func residency() async throws {
        try await withEngine { probe, runner in
            let size: MESValue = ["width": 64, "height": 64]
            _ = try await probe.succeed(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")], params: ["size": size]))
            _ = try await probe.succeed(JobRequest(operation: "image.erase", inputs: ["image": image(), "mask": .one(.inline(mediaType: "image/png", data: Fixtures.mask()))]))
            #expect(runner.resident.withLock { $0 } == ["fake.z-image-turbo", "fake.lama-inpaint"])
            // Z-Image (12 GB, heavy) evicts Z-Image Turbo (heavy); LaMa (small) stays.
            _ = try await probe.succeed(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")], params: ["size": size], model: "z-image"))
            #expect(runner.resident.withLock { $0 } == ["fake.z-image", "fake.lama-inpaint"])
        }
        var quick = Residency.Policy()
        (quick.keepWarm, quick.bigKeepWarm, quick.sweepInterval) = (.milliseconds(150), .milliseconds(150), .milliseconds(50))
        try await withEngine(residency: quick) { probe, runner in
            _ = try await probe.succeed(JobRequest(operation: "image.score", inputs: ["image": image()]))
            #expect(runner.resident.withLock { $0 } == ["fake.siglip2-quality"])
            try await Task.sleep(for: .milliseconds(600))
            #expect(runner.resident.withLock { $0 }.isEmpty, "released after keep-warm")
        }
    }

    @Test("An edit model that leaves the marker is retried once, then LaMa fills: magenta never reaches the output")
    func markerFallback() async throws {
        try await withEngine(runner: FakeRunner(editKeepsMarker: true)) { probe, runner in
            let job = try await probe.succeed(JobRequest(operation: "image.extend", inputs: ["image": image(), "prompt": .text("more of the scene")],
                                                         params: ["canvas": ["left": 16, "top": 0, "right": 16, "bottom": 0]]))
            let steps = runner.calls.withLock { $0.suffix(3).map(\.route.capability) }
            #expect(steps == [.imageEdit, .imageEdit, .imageInpaint])
            #expect(job.warnings.map(\.code).contains("model_fallback"))
            #expect(job.result?.effective["model_params"]?["fallback"] == "lama-inpaint")
            let seeds = runner.calls.withLock { $0.suffix(3).prefix(2).map(\.seed) }
            #expect(seeds[1] == seeds[0] + 1, "the retry uses the next seed")
        }
    }

    @Test("erase by name (AB-T-0220): Mage-VL names what's in the red box, the editor removes it by name, black-mask pixels stay exact")
    func eraseByName() async throws {
        try await withEngine { probe, runner in
            let erase = try #require(probe.descriptor("image.erase"))
            #expect(erase.models.map(\.id) == ["lama-inpaint", "mage-flow-edit-turbo"])     // only named removers, not Klein
            #expect(erase.models.first?.isDefault == true)
            let src = try DecodedImage(Fixtures.png())
            let job = try await probe.succeed(JobRequest(operation: "image.erase",
                                                         inputs: ["image": image(), "mask": .one(.inline(mediaType: "image/png", data: Fixtures.mask()))],
                                                         model: "mage-flow-edit-turbo"))
            let (named, removed) = runner.calls.withLock { ($0[$0.count - 2], $0[$0.count - 1]) }
            #expect(named.route.capability == .imageAnalysis && named.route.id == "mage-vl")
            let boxed = try DecodedImage(named.inputs["image"]![0].data)
            #expect(boxed.width == 512 && boxed.height == 512)                 // 48² square, up to Mage's 512 floor
            #expect(boxed.pixels(where: { $0 == [255, 0, 0, 255] }) > 0, "a red box shows the namer the region")
            #expect(removed.route.id == "mage-flow-edit-turbo" && removed.width == 512 && removed.height == 512)
            #expect(job.result?.provenance.seed == Int(removed.seed))                  // erase takes no seed; the job reports it
            #expect(removed.spec.params["prompt"]?.stringValue == "Remove the red mug and its shadow and reflection. Keep everything else unchanged.")
            let unmarked = try DecodedImage(removed.inputs["images"]![0].data)
            #expect(unmarked.pixels(where: { $0 == [255, 0, 0, 255] }) == 0, "the editor sees the picture unmarked")
            #expect(job.result?.effective["model_params"]?["named"] == "red mug")
            #expect(job.result?.effective["model_params"]?["namer"] == "mage-vl")
            let out = try DecodedImage(try await probe.output(job).1)
            #expect(out.width == 64 && out.height == 48)
            #expect((0..<48).allSatisfy { y in (0..<32).allSatisfy { x in out.pixel(x, y) == src.pixel(x, y) } }, "Image §1.7")
            #expect(out.pixel(48, 24) != src.pixel(48, 24))                     // the masked half is the editor's
        }
    }

    @Test("erase by name: an object handed back is retried with the next seed, then LaMa erases it")
    func eraseHandedBack() async throws {
        try await withEngine(runner: FakeRunner(editKeepsMarker: true)) { probe, runner in
            let job = try await probe.succeed(JobRequest(operation: "image.erase",
                                                         inputs: ["image": image(), "mask": .one(.inline(mediaType: "image/png", data: Fixtures.mask()))],
                                                         model: "mage-flow-edit-turbo"))
            let steps = runner.calls.withLock { $0.suffix(4).map(\.route.capability) }
            #expect(steps == [.imageAnalysis, .imageEdit, .imageEdit, .imageInpaint])
            let seeds = runner.calls.withLock { $0.suffix(3).prefix(2).map(\.seed) }
            #expect(seeds[1] == seeds[0] + 1)
            #expect(job.warnings.contains { $0.code == "model_fallback" && $0.message.contains("handed the object back twice") })
            #expect(job.result?.effective["model_params"]?["fallback"] == "lama-inpaint")
            #expect(job.result?.effective["model_params"]?["rejected"] == "object left")
        }
    }

    @Test("Runtime failures arrive as MES errors")
    func errors() {
        #expect((ImageNormalizer.mesError(APIError.conflict("license_not_allowed", "no")) as? MESError)?.code == MESErrorCode.policyUnmet.rawValue)
        #expect((ImageNormalizer.mesError(APIError.unavailable("down")) as? MESError)?.code == MESErrorCode.noCapacity.rawValue)
        #expect((ImageNormalizer.mesError(NormalizerError.input("bad")) as? MESError)?.code == MESErrorCode.inputInvalid.rawValue)
        // A download failure keeps the repo it failed on (AB-T-0221).
        let download = WeightDownloadError(model: "z-image-turbo",
                                           sources: [.init(role: "snapshot", repo: "mlx-community/Z-Image-Turbo-4bit", bytes: nil)],
                                           underlying: URLError(.notConnectedToInternet))
        let mapped = ImageNormalizer.mesError(download) as? MESError
        #expect(mapped?.code == MESErrorCode.engineError.rawValue && mapped?.message.contains("mlx-community/Z-Image-Turbo-4bit") == true)
    }
}
