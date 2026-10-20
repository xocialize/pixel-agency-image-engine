import Foundation
import ImageServerModels
@testable import MESConformance
import MESCore
import MESEngineCore
import MLXToolKit
@testable import PixelAgencyImageEngine
import PromptEnhanceKit
import Testing

// Structured prompt enhancement (AB-D-0155, E3): SenseNova U1.5's Render JSON, prompt-enhance-kit's structured profile, on
// the large backbone (Qwen3.5-9B); the size the rewrite suggests, used when the request names none; the request's size
// told to the profile when it names one. Ming-Image's layers failed the gate, so it has no profile.

@Suite("Structured prompt enhancement (E3)", .serialized)
struct StructuredEnhanceTests {
    static func generate(_ prompt: String, model: String, size: (Int, Int)? = nil, mode: String? = nil) -> JobRequest {
        var params: [String: MESValue] = ["seed": 42]
        if let size { params["size"] = ["width": .number(Double(size.0)), "height": .number(Double(size.1))] }
        if let mode { params["prompt_enhance"] = .string(mode) }
        return JobRequest(operation: "image.generate", inputs: ["prompt": .text(prompt)], params: params, model: model)
    }

    static func size(_ job: Job) -> [Int]? {
        guard let size = job.result?.effective["size"] else { return nil }
        return [size["width"]?.intValue ?? 0, size["height"]?.intValue ?? 0]
    }

    /// The image model's last call.
    static func imageCall(_ runner: FakeRunner) -> RunWork? {
        runner.calls.withLock { $0 }.last { $0.route.capability == .textToImage }
    }

    @Test("Offers: SenseNova's notes name the 9B and the suggested size; each backbone's card names its models; the preview offers both")
    func descriptors() async throws {
        let normalizer = ImageNormalizer(directory: FakeModels(), runner: FakeRunner(), textRunner: FakeRunner())
        let ops = await normalizer.descriptors()
        let generate = try #require(ops.first { $0.operation == "image.generate" })
        let notes = try #require(generate.models.first { $0.id == "sensenova-u1" }?.notes)
        #expect(notes.contains("SenseNova U1.5 profile's JSON on qwen3.5-9b") && notes.contains("the aspect ratio it suggests"))
        #expect(PromptEnhance.backboneNote(PromptEnhance.largeBackboneID).contains("sensenova-u1, sensenova-u1-fast, sensenova-u1-fast-v1"))
        #expect(!PromptEnhance.backboneNote(PromptEnhance.backboneID).contains("sensenova"))
        #expect(PromptEnhance.backbone(forModel: "sensenova-u1-fast") == PromptEnhance.largeBackboneID)
        #expect(PromptEnhance.backbone(forModel: "klein-4b") == PromptEnhance.backboneID)
        #expect(ops.first { $0.operation == "image.enhance_prompt" }?.models.map(\.id) == PromptEnhance.backboneIDs)
    }

    @Test("SenseNova, no size named: the brief becomes compact Render JSON on the 9B, constrained, and the job runs at its canvas's aspect near 1 MP")
    func senseNova() async throws {
        try await withEngine { probe, runner in
            let job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "sensenova-u1"))
            // The 9B rewrote it, before the image model loaded; the 4B didn't run.
            #expect(runner.textRoutes.withLock { $0 } == [PromptEnhance.largeBackboneID])
            #expect(runner.prepared.withLock { $0 } == [PromptEnhance.largeBackboneID, "sensenova-u1"])
            let request = try #require(runner.textCalls.withLock { $0.first })
            #expect(request.responseFormat == .json(container: .object) && request.parameters.maxTokens == 4096)
            #expect(request.messages.last?.content == "a lighthouse at dusk", "no size named: no target resolution")
            // The JSON the model received, compact and in the backbone's order; the canvas's size.
            #expect(Self.imageCall(runner)?.spec.params["prompt"]?.stringValue == FakeRunner.renderJSONCompact)
            #expect(job.result?.effective["prompt"] == .string(FakeRunner.renderJSONCompact))
            // The canvas is 2:3 at 1664×2496; the job runs at 2:3 over the model's default 1024² area, snapped to 16.
            #expect(Self.size(job) == [832, 1248] && Self.imageCall(runner)?.width == 832 && Self.imageCall(runner)?.height == 1248)
            #expect(!job.warnings.contains { $0.code == "size_snapped" })
            let record = try #require(job.result?.effective["model_params"]?["prompt_enhancement"])
            #expect(record["profile"] == "sensenova-u1.5" && record["backbone"] == .string(PromptEnhance.largeBackboneID))
            #expect(record["suggested_size"] == ["width": 1664, "height": 2496, "aspect": "2:3"])
            #expect(job.result?.provenance.helpers?.map(\.id) == [PromptEnhance.largeBackboneID])
            #expect(job.warnings.contains { $0.code == "prompt_rewritten" && $0.param == "prompt" })
        }
    }

    @Test("A size named wins over the suggestion, and the structured profile is told it; a prose profile's rewrite isn't")
    func namedSize() async throws {
        try await withEngine { probe, runner in
            let job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "sensenova-u1", size: (1000, 1000)))
            // Snapped to the envelope (multiples of 16) before the profile is told.
            #expect(runner.textCalls.withLock { $0.last?.messages.last?.content } == "a lighthouse at dusk\n\nTarget resolution: 992x992.")
            #expect(Self.size(job) == [992, 992] && job.warnings.contains { $0.code == "size_snapped" })

            _ = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "klein-4b", size: (512, 512)))
            #expect(runner.textCalls.withLock { $0.last?.messages.last?.content } == "a lighthouse at dusk")
            #expect(runner.textRoutes.withLock { $0.last } == PromptEnhance.backboneID)
        }
    }

    @Test("prompt_enhance off: Render JSON isn't written, the size is the model's default; a JSON brief goes as typed under auto")
    func asTyped() async throws {
        try await withEngine { probe, runner in
            let off = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "sensenova-u1", mode: "off"))
            #expect(Self.size(off) == [1024, 1024] && runner.textCalls.withLock { $0.isEmpty })
            let json = #"{"subjects": [{"description": "a fox"}], "canvas": {"aspect_ratio": "16:9"}}"#
            let typed = try await probe.succeed(Self.generate(json, model: "sensenova-u1"))
            #expect(Self.imageCall(runner)?.spec.params["prompt"]?.stringValue == json && runner.textCalls.withLock { $0.isEmpty })
            #expect(typed.result?.effective["model_params"]?["prompt_enhancement"]?["outcome"] == "passed_through")
        }
    }

    @Test("The 9B switched off: structured profiles report unavailable (no fallback to the 4B); prose profiles still rewrite")
    func largeBackboneOff() async throws {
        let enablement = ModelEnablement(file: nil)
        try enablement.set(PromptEnhance.largeBackboneID, enabled: false, optIn: false)
        try await withEngine(enablement: enablement) { probe, runner in
            let job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "sensenova-u1"))
            #expect(job.result?.effective["model_params"]?["prompt_enhancement"]?["outcome"] == "unavailable")
            #expect(Self.imageCall(runner)?.spec.params["prompt"]?.stringValue == "a lighthouse at dusk" && Self.size(job) == [1024, 1024])
            #expect(runner.textCalls.withLock { $0.isEmpty })
            #expect(probe.descriptor("image.generate")?.models.first { $0.id == "sensenova-u1" }?.notes == nil)
            _ = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "qwen-image-flash"))
            #expect(runner.textRoutes.withLock { $0 } == [PromptEnhance.backboneID])
            #expect(probe.descriptor("image.enhance_prompt")?.models.map(\.id) == [PromptEnhance.backboneID])
        }
    }

    @Test("A slow 9B times out on the structured timeout, not the prose one")
    func structuredTimeout() async throws {
        try await withEngine(runner: FakeRunner(textDelay: .seconds(2)), structuredPromptEnhanceTimeout: .milliseconds(100)) { probe, runner in
            let job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "sensenova-u1"))
            #expect(job.result?.effective["model_params"]?["prompt_enhancement"]?["outcome"] == "timed_out")
            #expect(job.warnings.contains { $0.code == "prompt_enhance_failed" })
        }
    }

    @Test("Ming-Image has no profile (its layers failed the E3 gate on the 9B): prompt_enhance on is ignored, the prompt goes as typed")
    func ming() async throws {
        try await withEngine(research: true) { probe, runner in
            let job = try await probe.succeed(Self.generate("a cozy cabin", model: "ming-image", mode: "on"))
            #expect(Self.imageCall(runner)?.spec.params["prompt"]?.stringValue == "a cozy cabin" && runner.textCalls.withLock { $0.isEmpty })
            #expect(job.result?.effective["model_params"]?["prompt_enhancement"]?["outcome"] == "no_profile")
            #expect(job.warnings.contains { $0.code == "prompt_enhance_ignored" })
        }
    }

    @Test("The preview for SenseNova runs on the 9B, returns its Render JSON and size; naming the 4B for it is refused")
    func preview() async throws {
        try await withEngine { probe, runner in
            let job = try await probe.succeed(JobRequest(operation: "image.enhance_prompt", inputs: ["prompt": .text("a lighthouse at dusk")],
                                                         params: ["target_model": "sensenova-u1", "seed": 42]))
            #expect(job.plan?.model.id == PromptEnhance.largeBackboneID)
            let value = try await EnhancePromptTests.enhanced(probe, job)
            #expect(value["prompt"] == .string(FakeRunner.renderJSONCompact) && value["applied"] == true)
            #expect(value["size"] == ["width": 832, "height": 1248])
            #expect(runner.textRoutes.withLock { $0 } == [PromptEnhance.largeBackboneID])

            // The client's run: the text, the size, the model, prompt_enhance off.
            let run = try await probe.succeed(JobRequest(
                operation: "image.generate", inputs: ["prompt": .text(FakeRunner.renderJSONCompact)],
                params: ["size": ["width": 832, "height": 1248], "prompt_enhance": "off", "seed": 42], model: "sensenova-u1"))
            #expect(Self.size(run) == [832, 1248] && Self.imageCall(runner)?.spec.params["prompt"]?.stringValue == FakeRunner.renderJSONCompact)

            let named = JobRequest(operation: "image.enhance_prompt", inputs: ["prompt": .text("a fox")],
                                   params: ["target_model": "sensenova-u1"], model: PromptEnhance.backboneID)
            let reply = try await probe.wire.json("POST", "jobs", named)
            #expect(reply.status == 422 && reply.json?["error"]?["code"] == "unsupported_parameter")
            // A prose target on its own backbone: no size.
            let klein = try await probe.succeed(JobRequest(operation: "image.enhance_prompt", inputs: ["prompt": .text("a fox")],
                                                           params: ["target_model": "klein-4b"]))
            let kleinValue = try await EnhancePromptTests.enhanced(probe, klein)
            #expect(klein.plan?.model.id == PromptEnhance.backboneID && kleinValue["size"] == nil)
        }
    }
}
