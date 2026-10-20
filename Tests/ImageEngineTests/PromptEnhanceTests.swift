import Foundation
import ImageServerAPI
import ImageServerCatalog
import ImageServerModels
@testable import MESConformance
import MESCore
import MESEngineCore
import MLXToolKit
@testable import PixelAgencyImageEngine
import PromptEnhanceKit
import Testing

// Prompt enhancement (AB-D-0155, E2; docs/PROMPTS-AND-ADAPTERS.md §1.5): `x-pixelagency.prompt_enhance` on generate and
// edit, the model's profile from prompt-enhance-kit, the backbone a model in the catalog, provenance in
// `effective.model_params.prompt_enhancement`.

@Suite("Prompt enhancement (E2)", .serialized)
struct PromptEnhanceTests {
    static func generate(_ prompt: String, model: String? = nil, seed: Int? = 42,
                         _ ext: [String: MESValue]? = nil) -> JobRequest {
        var params: [String: MESValue] = ["size": ["width": 256, "height": 256]]
        if let seed { params["seed"] = .number(Double(seed)) }
        return JobRequest(operation: "image.generate", inputs: ["prompt": .text(prompt)], params: params, model: model,
                          extensions: ext.map { [PromptEnhance.name: .object($0)] })
    }

    static func enhancement(_ job: Job) -> MESValue? { job.result?.effective["model_params"]?["prompt_enhancement"] }

    /// The prompt the image model ran.
    static func ranPrompt(_ runner: FakeRunner) -> String? {
        runner.calls.withLock { $0 }.last { $0.route.capability == .textToImage || $0.route.capability == .imageEdit }?
            .spec.params["prompt"]?.stringValue
    }

    static let qwenSuffix = ImageModelProfiles.qwenImage.instructions[.textToImage]!.standard.suffix!

    @Test("Generate and edit declare the extension while the backbone is on; offers say how each model's prompts are treated")
    func descriptor() async throws {
        let ops = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner(), textRunner: FakeRunner()).descriptors()
        for operation in ["image.generate", "image.edit"] {
            let ext = try #require(ops.first { $0.operation == operation }?.extensions?.first { $0.name == PromptEnhance.name })
            #expect(ext.schema["properties"]?["mode"]?["enum"] == ["auto", "on", "off"] && ext.schema["additionalProperties"] == false)
        }
        #expect(ops.filter { !PromptEnhance.operations.contains($0.operation) }
            .allSatisfy { $0.extensions?.contains { $0.name == PromptEnhance.name } != true })
        let generate = try #require(ops.first { $0.operation == "image.generate" })
        let qwen = try #require(generate.models.first { $0.id == "qwen-image-flash" })
        #expect(qwen.notes?.contains("rewrites a short prompt with the Qwen-Image profile") == true)
        #expect(generate.models.first { $0.id == "z-image-turbo" }?.notes?.contains("mode on rewrites") == true, "optional")
        #expect(generate.models.first { $0.id == "moss-image-sft" }?.notes == nil, "no profile")
        #expect(ops.first { $0.operation == "image.edit" }?.models.allSatisfy { $0.notes == nil } == true, "generate's notes only")
        #expect(!ops.flatMap(\.models).contains { $0.id == PromptEnhance.backboneID }, "the backbone serves no operation")

        // No text runner, or the backbone switched off: no extension, and offers say nothing about prompts.
        let bare = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner()).descriptors()
        #expect(bare.allSatisfy { $0.extensions?.contains { $0.name == PromptEnhance.name } != true })
        let enablement = ModelEnablement(file: nil)
        try enablement.set(PromptEnhance.backboneID, enabled: false, optIn: false)
        let off = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner(), textRunner: FakeRunner(),
                                        options: .init(enablement: enablement)).descriptors()
        #expect(off.allSatisfy { $0.extensions?.contains { $0.name == PromptEnhance.name } != true })
        #expect(off.first { $0.operation == "image.generate" }?.models.first { $0.id == "qwen-image-flash" }?.notes == nil)
    }

    @Test("\"a lighthouse at dusk\" on Qwen-Image Flash: rewritten before the model loads, seeded from the job, reported with a warning")
    func lighthouse() async throws {
        try await withEngine { probe, runner in
            let job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "qwen-image-flash"))
            let expected = FakeRunner.lighthouse + " " + Self.qwenSuffix
            #expect(Self.ranPrompt(runner) == expected)
            let record = try #require(Self.enhancement(job))
            #expect(record["applied"] == true && record["outcome"] == "enhanced" && record["profile"] == "qwen-image")
            #expect(record["version"] == 1 && record["backbone"] == .string(PromptEnhance.backboneID) && record["seed"] == 42)
            #expect(record["prompt"] == .string(expected))
            #expect(job.warnings.contains { $0.code == "prompt_rewritten" && $0.param == "prompt" })
            // The kit's request: Qwen's own rewriter around the brief, the enhancer's mode, the job's seed.
            let request = try #require(runner.textCalls.withLock { $0.first })
            #expect(request.mode == .promptEnhance && request.parameters.seed == 42)
            #expect(request.messages.last?.content.contains("User Input: a lighthouse at dusk") == true)
            // One heavy model at a time: the backbone ran before the image model loaded.
            #expect(runner.prepared.withLock { $0 } == [PromptEnhance.backboneID, "qwen-image-flash"])
            #expect(job.result?.provenance.seed == 42)
        }
    }

    @Test("The enhancer's seed is the job's unless the extension pins one; mode on rewrites for an optional profile")
    func seeds() async throws {
        try await withEngine { probe, runner in
            _ = try await probe.succeed(Self.generate("a fox", model: "z-image-turbo", seed: 7, ["mode": "on"]))
            _ = try await probe.succeed(Self.generate("a fox", model: "z-image-turbo", seed: 7, ["mode": "on", "seed": 1234]))
            #expect(runner.textCalls.withLock { $0.map(\.parameters.seed) } == [7, 1234])
            #expect(Self.ranPrompt(runner) == FakeRunner.lighthouse, "Z-Image's profile has no suffix")
        }
    }

    @Test("Prompts that go as typed never load the backbone: auto on an optional profile, a detailed or JSON prompt, off, no profile")
    func asTyped() async throws {
        let detailed = Array(repeating: "word", count: 70).joined(separator: " ")
        let cases: [(JobRequest, String, warned: Bool)] = [
            (Self.generate("a fox"), "not_recommended", false),                                           // z-image-turbo, optional
            (Self.generate(detailed, model: "qwen-image-flash"), "passed_through", false),
            (Self.generate(#"{"caption": "a fox", "items": []}"#, model: "qwen-image-flash", ["mode": "on"]), "passed_through", false),
            (Self.generate("a fox", model: "qwen-image-flash", ["mode": "off"]), "off", false),
            (Self.generate("a fox", model: "moss-image-sft"), "no_profile", false),
            (Self.generate("a fox", model: "moss-image-sft", ["mode": "on"]), "no_profile", true),
        ]
        for (request, outcome, warned) in cases {
            try await withEngine { probe, runner in
                let job = try await probe.succeed(request)
                let record = try #require(Self.enhancement(job))
                #expect(record["outcome"] == .string(outcome) && record["applied"] == false, "\(outcome)")
                #expect(record["prompt"] == nil)
                #expect(Self.ranPrompt(runner) == request.inputs?["prompt"].flatMap { if case .text(let t) = $0 { t } else { nil } })
                #expect(runner.textCalls.withLock { $0.isEmpty } && !runner.prepared.withLock { $0 }.contains(PromptEnhance.backboneID))
                #expect(job.warnings.contains { $0.code == "prompt_enhance_ignored" } == warned, "\(outcome)")
                #expect(!job.warnings.contains { $0.code == "prompt_rewritten" })
            }
        }
    }

    @Test("Edits keep their instruction (the rewriter would need to see the image): needs_vision")
    func edit() async throws {
        try await withEngine { probe, runner in
            let job = try await probe.succeed(JobRequest(
                operation: "image.edit", inputs: ["images": image(), "instruction": .text("make it night")],
                extensions: [PromptEnhance.name: ["mode": "on"]]))
            #expect(Self.ranPrompt(runner) == "make it night")
            #expect(Self.enhancement(job)?["outcome"] == "needs_vision" && runner.textCalls.withLock { $0.isEmpty })
            #expect(job.warnings.contains { $0.code == "prompt_enhance_ignored" })
        }
    }

    @Test("Engine-written instructions never pass through the enhancer: generative fill's marker instruction")
    func engineWritten() async throws {
        try await withEngine { probe, runner in
            let job = try await probe.succeed(JobRequest(
                operation: "image.fill",
                inputs: ["image": image(Fixtures.png(width: 64, height: 64)),
                         "mask": .one(.inline(mediaType: "image/png", data: Fixtures.mask(width: 64, height: 64))),
                         "prompt": .text("a red ball")],
                model: "klein-4b"))
            #expect(Self.ranPrompt(runner)?.hasPrefix("Replace the bright magenta area with a red ball.") == true)
            #expect(runner.textCalls.withLock { $0.isEmpty } && Self.enhancement(job) == nil)
        }
    }

    @Test("A failing or slow backbone leaves the prompt as typed, says so, and never fails the job")
    func failures() async throws {
        for (runner, timeout, outcome) in [(FakeRunner(rewrite: nil), Duration.seconds(60), "failed"),
                                           (FakeRunner(textDelay: .seconds(2)), .milliseconds(100), "timed_out")] {
            try await withEngine(runner: runner, promptEnhanceTimeout: timeout) { probe, runner in
                let job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "qwen-image-flash"))
                #expect(Self.ranPrompt(runner) == "a lighthouse at dusk")
                let record = try #require(Self.enhancement(job))
                #expect(record["outcome"] == .string(outcome) && record["applied"] == false && record["backbone"] != nil)
                #expect(job.warnings.contains { $0.code == "prompt_enhance_failed" })
            }
        }
    }

    @Test("Backbone switched off: auto reports unavailable and uses the prompt as typed; the extension is refused")
    func backboneOff() async throws {
        let enablement = ModelEnablement(file: nil)
        try enablement.set(PromptEnhance.backboneID, enabled: false, optIn: false)
        try await withEngine(enablement: enablement) { probe, runner in
            let job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "qwen-image-flash"))
            #expect(Self.enhancement(job)?["outcome"] == "unavailable" && Self.ranPrompt(runner) == "a lighthouse at dusk")
            #expect(runner.textCalls.withLock { $0.isEmpty })
            let reply = try await probe.wire.json("POST", "jobs", Self.generate("a fox", model: "qwen-image-flash", ["mode": "on"]))
            #expect(reply.status == 422)
        }
    }

    @Test("Residency: a small backbone stays warm beside the image model; a large one is released as soon as it's done")
    func residency() async throws {
        try await withEngine { probe, runner in
            _ = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "qwen-image-flash"))
            #expect(await runner.residentPackages().contains("fake.\(PromptEnhance.backboneID)"), "2 GB stays warm")
        }
        var policy = Residency.Policy()
        policy.warmHelperBytes = 1 << 30
        try await withEngine(residency: policy) { probe, runner in
            _ = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "qwen-image-flash"))
            #expect(await !runner.residentPackages().contains("fake.\(PromptEnhance.backboneID)"), "over the warm size: released")
            #expect(await runner.residentPackages().contains("fake.qwen-image-flash"))
        }
    }

    @Test("Cancelling during enhancement cancels the job before the image model loads")
    func cancel() async throws {
        try await withEngine(runner: FakeRunner(textDelay: .seconds(5))) { probe, runner in
            let reply = try await probe.wire.json("POST", "jobs", Self.generate("a lighthouse at dusk", model: "qwen-image-flash"))
            let job = try reply.decode(Job.self)
            for _ in 0..<100 where runner.textCalls.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(20)) }
            #expect(runner.textCalls.withLock { $0.count } == 1, "cancelled while the backbone answers")
            _ = try await probe.wire.send("DELETE", "jobs/\(job.id)")
            let settled = try await probe.settle(job, timeout: 10)
            #expect(settled.outcome == .cancelled)
            #expect(!runner.prepared.withLock { $0 }.contains("qwen-image-flash") && Self.ranPrompt(runner) == nil)
        }
    }

    @Test("FLUX 3 Klein: its own upsampler, switched per request through the package's upsample key (AB-T-0336)")
    func flux3() async throws {
        try await withEngine(research: true) { probe, runner in
            /// The `upsample` key the image model's last call carried.
            func upsample() -> ISValue? {
                runner.calls.withLock { $0 }.last { $0.route.capability == .textToImage || $0.route.capability == .imageEdit }?
                    .spec.metaData?[PromptEnhance.upsampleKey]
            }
            // auto: no key, so the configured upsampler runs; reported as built in.
            var job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "flux-3-klein"))
            var record = try #require(Self.enhancement(job))
            #expect(record["outcome"] == "built_in" && record["profile"] == "flux3-upsampler" && record["applied"] == true)
            #expect(job.warnings.contains { $0.code == "prompt_rewritten" } && upsample() == nil)
            #expect(Self.ranPrompt(runner) == "a lighthouse at dusk" && runner.textCalls.withLock { $0.isEmpty })

            // off: upsample false, not applied, and a warning that its makers require it.
            job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "flux-3-klein", ["mode": "off"]))
            record = try #require(Self.enhancement(job))
            #expect(record["outcome"] == "off" && record["applied"] == false && upsample() == .bool(false))
            #expect(job.warnings.contains { $0.code == "prompt_upsampler_off" } && !job.warnings.contains { $0.code == "prompt_rewritten" })

            // on: upsample true.
            job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "flux-3-klein", ["mode": "on"]))
            #expect(Self.enhancement(job)?["applied"] == true && upsample() == .bool(true))

            // An edit's own instruction follows the mode too.
            job = try await probe.succeed(JobRequest(
                operation: "image.edit", inputs: ["images": image(), "instruction": .text("make it night")], model: "flux-3-klein",
                extensions: [PromptEnhance.name: ["mode": "off"]]))
            #expect(Self.ranPrompt(runner) == "make it night" && upsample() == .bool(false))
            #expect(Self.enhancement(job)?["outcome"] == "off")

            // A prompt the engine wrote (fill's marker instruction; fill takes no extension) is never upsampled.
            _ = try await probe.succeed(JobRequest(
                operation: "image.fill", inputs: ["image": image(), "mask": .one(.inline(mediaType: "image/png", data: Fixtures.mask())),
                                                  "prompt": .text("a snowy owl")], model: "flux-3-klein"))
            #expect(Self.ranPrompt(runner)?.contains("magenta area with a snowy owl") == true && upsample() == .bool(false))

            // Another model declares no such key, so none is sent.
            _ = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "klein-4b", ["mode": "off"]))
            #expect(runner.calls.withLock { $0.last?.spec.metaData } == nil)
        }
    }

    @Test("The runtime's own FLUX 3 Klein takes upsample on generate and edit, so what the engine sends passes its check")
    @MainActor
    func flux3RuntimeKeys() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("pa-flux3-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let runtime = await ImageRuntime.start(modelStore: store, catalog: ModelCatalog.all(environment: [:]))
        for capability in [Capability.textToImage, .imageEdit] {
            let route = try await runtime.service.route(capability, model: ModelID(PromptEnhance.flux3))
            #expect(route.takes(PromptEnhance.upsampleKey), "\(capability.rawValue)")
            for value in [false, true] {
                let spec = JobSpec(capability: capability, model: route.id, count: 1,
                                   metaData: [PromptEnhance.upsampleKey: .bool(value)])
                #expect(SubmitValidation.metaDataProblem(spec, route: route) == nil)
            }
        }
        let klein = try await runtime.service.route(.textToImage, model: "klein-4b")
        #expect(!klein.takes(PromptEnhance.upsampleKey))
    }
}
