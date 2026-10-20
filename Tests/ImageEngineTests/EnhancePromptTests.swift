import Foundation
import ImageServerModels
@testable import MESConformance
import MESCore
import MESEngineCore
@testable import PixelAgencyImageEngine
import Testing

// The prompt enhancer's preview, `image.enhance_prompt` (Image §3.1; AB-D-0155, E5): the rewrite a target job would run
// with `prompt_enhance: on`, returned without running it, so a client can show it and let its user edit it first.

@Suite("Prompt enhancement preview (E5)", .serialized)
struct EnhancePromptTests {
    static func preview(_ prompt: String, target: String? = nil, seed: Int? = 7, operation: String? = nil,
                        policy: Policy? = nil) -> JobRequest {
        var params: [String: MESValue] = [:]
        if let seed { params["seed"] = .number(Double(seed)) }
        if let target { params["target_model"] = .string(target) }
        if let operation { params["target_operation"] = .string(operation) }
        return JobRequest(operation: "image.enhance_prompt", inputs: ["prompt": .text(prompt)], params: params, policy: policy)
    }

    /// The job's `enhanced` data.
    static func enhanced(_ probe: Probe, _ job: Job) async throws -> MESValue {
        let output = try #require(job.result?.outputs.first { $0.name == "enhanced" })
        #expect(output.kind == .data)
        if let inline = output.value { return inline }
        return try MESJSON.decoder.decode(MESValue.self, from: try await probe.output(job, output.index).1)
    }

    static let qwenSuffix = PromptEnhanceTests.qwenSuffix

    @Test("Declared while the backbone is on: its offer, prompt in, enhanced out, target_operation and target_model narrowed to what it enhances")
    func descriptor() async throws {
        let ops = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner(), textRunner: FakeRunner()).descriptors()
        let d = try #require(ops.first { $0.operation == "image.enhance_prompt" })
        #expect(d.title == "Enhance prompt" && d.models.map(\.id) == PromptEnhance.backboneIDs)
        let offer = try #require(d.models.first)
        #expect(offer.isDefault == true && offer.license.spdx == "Apache-2.0" && offer.license.commercialUse == .yes)
        #expect(offer.notes == PromptEnhance.previewNote(PromptEnhance.backboneID) && offer.memoryClass == .small)
        #expect(d.models.last?.notes?.contains("sensenova-u1") == true, "the 9B previews the structured profiles")
        #expect(d.inputs.map(\.name) == ["prompt"] && d.inputs.first?.required == true, "the enhancer reads no image")
        #expect(d.outputs.map(\.name) == ["enhanced"] && d.outputs.first?.kind == .data && d.limits == nil)
        let properties = try #require(d.params["properties"]?.objectValue)
        #expect(Set(properties.keys) == ["target_operation", "target_model", "seed"])
        #expect(properties["target_operation"]?["enum"] == ["image.generate"] && properties["target_operation"]?["default"] == "image.generate")
        // target_model: generate's offers, in its order (the default first); a research model only once it's offered.
        let generate = try #require(ops.first { $0.operation == "image.generate" })
        #expect(properties["target_model"]?["enum"] == .array(generate.models.map { .string($0.id) }))
        #expect(properties["target_model"]?["pattern"] == nil && properties["target_model"]?["x-mes-ui"]?["widget"] == "picker")
        #expect(generate.models.first?.id == "z-image-turbo" && !generate.models.contains { $0.id == PromptEnhance.flux3 })
        let research = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner(), textRunner: FakeRunner(),
                                             options: .init(allowResearch: true)).descriptors()
        let targets = research.first { $0.operation == "image.enhance_prompt" }?.params["properties"]?["target_model"]?["enum"]
        #expect(targets?.arrayValue?.contains(.string(PromptEnhance.flux3)) == true)

        // No text runner, or the backbone switched off: no preview.
        let bare = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner()).descriptors()
        #expect(!bare.contains { $0.operation == "image.enhance_prompt" })
        let enablement = ModelEnablement(file: nil)
        for id in PromptEnhance.backboneIDs { try enablement.set(id, enabled: false, optIn: false) }
        let off = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner(), textRunner: FakeRunner(),
                                        options: .init(enablement: enablement)).descriptors()
        #expect(!off.contains { $0.operation == "image.enhance_prompt" })
    }

    @Test("The preview is what the job runs: the same profile, seed and backbone request as generate with prompt_enhance on; run with off, the model gets exactly it")
    func sameAsTheJob() async throws {
        try await withEngine { probe, runner in
            let job = try await probe.succeed(Self.preview("a lighthouse at dusk", target: "qwen-image-flash"))
            let value = try await Self.enhanced(probe, job)
            let expected = FakeRunner.lighthouse + " " + Self.qwenSuffix
            #expect(value == ["prompt": .string(expected), "applied": true])
            // The model the rewrite was made for, and the preview's own: the backbone, also its prompt_enhance helper.
            #expect(job.result?.effective["target_operation"] == "image.generate")
            #expect(job.result?.effective["target_model"] == "qwen-image-flash" && job.plan?.model.id == PromptEnhance.backboneID)
            let helper = try #require(job.result?.provenance.helpers?.first)
            #expect(helper.id == PromptEnhance.backboneID && helper.role == "prompt_enhance" && job.result?.provenance.seed == 7)
            let record = try #require(job.result?.effective["model_params"]?["prompt_enhancement"])
            #expect(record["outcome"] == "enhanced" && record["profile"] == "qwen-image" && record["seed"] == 7)
            // Nothing was generated, and no model received the rewrite.
            #expect(job.warnings.isEmpty && runner.calls.withLock { $0.isEmpty })
            #expect(runner.prepared.withLock { $0 } == [PromptEnhance.backboneID])

            // generate with prompt_enhance on and the same seed sends the backbone the same request, and runs the same text.
            _ = try await probe.succeed(PromptEnhanceTests.generate("a lighthouse at dusk", model: "qwen-image-flash", seed: 7, mode: "on"))
            let requests = runner.textCalls.withLock { $0 }
            #expect(requests.count == 2 && requests[0].messages.map(\.content) == requests[1].messages.map(\.content))
            #expect(requests.map(\.parameters.seed) == [7, 7] && PromptEnhanceTests.ranPrompt(runner) == expected)

            // The client's run: the text (edited or not), the same model, prompt_enhance off.
            let edited = expected + " Mist rolls over the rocks."
            let run = try await probe.succeed(PromptEnhanceTests.generate(edited, model: "qwen-image-flash", mode: "off"))
            #expect(PromptEnhanceTests.ranPrompt(runner) == edited && runner.textCalls.withLock { $0.count } == 2)
            #expect(!run.warnings.contains { $0.code == "prompt_rewritten" })
        }
    }

    @Test("No target_model: the model image.generate runs for a request naming none; prompt_enhance on, so an optional profile rewrites")
    func defaultTarget() async throws {
        try await withEngine { probe, runner in
            let job = try await probe.succeed(Self.preview("a fox", seed: nil))
            #expect(job.result?.effective["target_model"] == "z-image-turbo")
            #expect(try await Self.enhanced(probe, job) == ["prompt": .string(FakeRunner.lighthouse), "applied": true])
            // Without a seed the engine picks one and reports it; the backbone ran with it.
            let seed = try #require(job.result?.provenance.seed)
            #expect(runner.textCalls.withLock { $0.map(\.parameters.seed) } == [UInt64(seed)])
        }
    }

    @Test("Nothing to rewrite: the prompt as typed, applied false, prompt_enhance_ignored saying why; the backbone loads only when it would run")
    func asTyped() async throws {
        // (Under on, a long prompt is still rewritten; only a structured one goes as typed.)
        let cases: [(JobRequest, outcome: String, loads: Bool)] = [
            (Self.preview("a fox", target: "ming-image"), "no_profile", false),                     // no profile
            (Self.preview(#"{"caption": "a fox", "items": []}"#, target: "qwen-image-flash"), "passed_through", false),
            (Self.preview("a fox", target: PromptEnhance.flux3), "built_in", false),                // its own upsampler
        ]
        for (request, outcome, loads) in cases {
            try await withEngine(research: true) { probe, runner in
                let job = try await probe.succeed(request)
                let typed = request.inputs?["prompt"].flatMap { if case .text(let t) = $0 { t } else { nil } }
                #expect(try await Self.enhanced(probe, job) == ["prompt": .string(typed ?? ""), "applied": false], "\(outcome)")
                let ignored = job.warnings.filter { $0.code == "prompt_enhance_ignored" }
                #expect(ignored.count == 1 && ignored.first?.param == "target_model", "\(outcome)")
                #expect(job.result?.effective["model_params"]?["prompt_enhancement"]?["outcome"] == .string(outcome))
                #expect(job.result?.provenance.helpers == nil && !job.warnings.contains { $0.code == "prompt_rewritten" })
                #expect(runner.prepared.withLock { $0 }.contains(PromptEnhance.backboneID) == loads && runner.calls.withLock { $0.isEmpty })
            }
        }
        let flux = try await withPreview(Self.preview("a fox", target: PromptEnhance.flux3), research: true)
        #expect(flux.warnings.first?.message.contains("can't be previewed") == true)
    }

    @Test("A failing backbone: the prompt as typed, prompt_enhance_failed and prompt_enhance_ignored, and the job still succeeds")
    func failure() async throws {
        try await withEngine(runner: FakeRunner(rewrite: nil)) { probe, _ in
            let job = try await probe.succeed(Self.preview("a lighthouse at dusk", target: "qwen-image-flash"))
            #expect(try await Self.enhanced(probe, job) == ["prompt": "a lighthouse at dusk", "applied": false])
            #expect(Set(job.warnings.map(\.code)) == ["prompt_enhance_failed", "prompt_enhance_ignored"])
            #expect(job.warnings.allSatisfy { $0.param == "target_model" })
        }
    }

    @Test("Refused at submit: a target_model the target doesn't offer, a target_operation it doesn't enhance, a backbone the policy doesn't allow")
    func refusals() async throws {
        try await withEngine { probe, _ in
            for request in [Self.preview("a fox", target: "qwen-image-2.1"),       // research, not offered here
                            Self.preview("a fox", target: "lama-inpaint"),         // not a generate model
                            Self.preview("a fox", operation: "image.edit")] {      // edits need vision (E4)
                let reply = try await probe.wire.json("POST", "jobs", request)
                #expect(reply.status == 422 && reply.json?["error"]?["code"] == "out_of_limits", "\(request.params ?? [:])")
            }
        }
        // The backbone is the preview's own model, so the request's licence policy holds it at submit (Base §10.3), where a
        // generate job would skip it as a helper (helper_skipped_by_policy).
        let research = FakeModels(FakeModels.catalog.map { info in
            guard info.id.rawValue == PromptEnhance.backboneID else { return info }
            var info = info
            info.license = FakeModels.research
            return info
        })
        try await withEngine(research: true, models: research) { probe, _ in
            var request = Self.preview("a fox", policy: Policy(license: .commercialUse))
            request.model = PromptEnhance.backboneID                              // opt-in now, so named-only
            let reply = try await probe.wire.json("POST", "jobs", request)
            #expect(reply.status == 422 && reply.json?["error"]?["code"] == "policy_unmet")
            request.policy = nil
            let job = try await probe.succeed(request)
            #expect(job.result?.provenance.helpers?.first?.license.commercialUse == .no)
        }
    }

    /// One preview on a fresh engine.
    func withPreview(_ request: JobRequest, research: Bool = false) async throws -> Job {
        var job: Job?
        try await withEngine(research: research) { probe, _ in job = try await probe.succeed(request) }
        return try #require(job)
    }
}
