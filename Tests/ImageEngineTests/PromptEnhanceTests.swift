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

// Prompt enhancement (Image §1.9; AB-D-0155, E2; docs/PROMPTS-AND-ADAPTERS.md §1.5): the `prompt_enhance` vocabulary on
// generate and edit, the model's profile from prompt-enhance-kit, the backbone a model in the catalog and a helper in
// provenance, the rewrite in `effective.prompt`, the detail in `effective.model_params.prompt_enhancement`.

@Suite("Prompt enhancement (E2)", .serialized)
struct PromptEnhanceTests {
    static func generate(_ prompt: String, model: String? = nil, seed: Int? = 42, mode: String? = nil,
                         policy: Policy? = nil) -> JobRequest {
        var params: [String: MESValue] = ["size": ["width": 256, "height": 256]]
        if let seed { params["seed"] = .number(Double(seed)) }
        if let mode { params["prompt_enhance"] = .string(mode) }
        return JobRequest(operation: "image.generate", inputs: ["prompt": .text(prompt)], params: params, model: model, policy: policy)
    }

    /// Whether `operation` declares the `prompt_enhance` vocabulary.
    static func declares(_ ops: [Descriptor], _ operation: String) -> Bool {
        ops.first { $0.operation == operation }?.params["properties"]?["prompt_enhance"] != nil
    }

    static func enhancement(_ job: Job) -> MESValue? { job.result?.effective["model_params"]?["prompt_enhancement"] }

    /// The prompt the image model ran.
    static func ranPrompt(_ runner: FakeRunner) -> String? {
        runner.calls.withLock { $0 }.last { $0.route.capability == .textToImage || $0.route.capability == .imageEdit }?
            .spec.params["prompt"]?.stringValue
    }

    static let qwenSuffix = ImageModelProfiles.qwenImage.instructions[.textToImage]!.standard.suffix!

    @Test("Generate declares prompt_enhance while the backbone is on, edit where something may rewrite it; offers say how each model's prompts are treated")
    func descriptor() async throws {
        let ops = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner(), textRunner: FakeRunner()).descriptors()
        let schema = try #require(ops.first { $0.operation == "image.generate" }?.params["properties"]?["prompt_enhance"])
        #expect(schema["enum"] == ["auto", "on", "off"] && schema["default"] == "auto")
        #expect(schema["x-mes-ui"]?["widget"] == "picker" && schema["description"]?.stringValue?.contains("effective.prompt") == true)
        #expect(!Self.declares(ops, "image.edit"), "no edit model here rewrites an instruction")
        #expect(ops.filter { !PromptEnhance.operations.contains($0.operation) }.allSatisfy { !Self.declares(ops, $0.operation) })
        #expect(ops.allSatisfy { $0.extensions?.contains { $0.name == "x-pixelagency.prompt_enhance" } != true })
        let generate = try #require(ops.first { $0.operation == "image.generate" })
        let qwen = try #require(generate.models.first { $0.id == "qwen-image-flash" })
        #expect(qwen.notes?.contains("rewrites a short prompt with the Qwen-Image profile") == true)
        #expect(generate.models.first { $0.id == "z-image-turbo" }?.notes?.contains("prompt_enhance on rewrites") == true, "optional")
        #expect(generate.models.first { $0.id == "moss-image-sft" }?.notes?.contains("prompt_enhance on lays them out") == true,
                "optional, structured")
        #expect(ops.first { $0.operation == "image.edit" }?.models.allSatisfy { $0.notes == nil } == true, "generate's notes only")
        #expect(ops.filter { $0.models.contains { $0.id == PromptEnhance.backboneID } }.map(\.operation) == ["image.enhance_prompt"],
                "the backbone serves only the preview")

        // No text runner, or the backbone switched off: nothing rewrites, so nothing declares it, and offers say nothing
        // about prompts.
        let bare = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner()).descriptors()
        #expect(bare.allSatisfy { !Self.declares(bare, $0.operation) })
        let enablement = ModelEnablement(file: nil)
        for id in PromptEnhance.backboneIDs { try enablement.set(id, enabled: false, optIn: false) }
        let off = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner(), textRunner: FakeRunner(),
                                        options: .init(enablement: enablement)).descriptors()
        #expect(off.allSatisfy { !Self.declares(off, $0.operation) })
        #expect(off.first { $0.operation == "image.generate" }?.models.first { $0.id == "qwen-image-flash" }?.notes == nil)

        // FLUX 3 Klein's own upsampler rewrites on generate and edit, backbone or not.
        let research = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner(), options: .init(allowResearch: true))
            .descriptors()
        #expect(Self.declares(research, "image.generate") && Self.declares(research, "image.edit"))
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
            #expect(record["prompt"] == nil, "the text is effective.prompt now")
            // Image §1.9: the text the model received, the mode that applied, the warning, and the backbone as a helper.
            #expect(job.result?.effective["prompt"] == .string(expected) && job.result?.effective["prompt_enhance"] == "auto")
            #expect(job.warnings.contains { $0.code == "prompt_rewritten" && $0.param == "prompt" })
            let helper = try #require(job.result?.provenance.helpers?.first)
            #expect(job.result?.provenance.helpers?.count == 1 && helper.id == PromptEnhance.backboneID && helper.role == "prompt_enhance")
            #expect(helper.license.spdx == "Apache-2.0" && helper.license.commercialUse == .yes && helper.revision == nil)
            // The kit's request: Qwen's own rewriter around the brief, the enhancer's mode, the job's seed.
            let request = try #require(runner.textCalls.withLock { $0.first })
            #expect(request.mode == .promptEnhance && request.parameters.seed == 42)
            #expect(request.messages.last?.content.contains("User Input: a lighthouse at dusk") == true)
            // One heavy model at a time: the backbone ran before the image model loaded.
            #expect(runner.prepared.withLock { $0 } == [PromptEnhance.backboneID, "qwen-image-flash"])
            #expect(job.result?.provenance.seed == 42)
        }
    }

    @Test("The enhancer's seed is the job's; prompt_enhance on rewrites for an optional profile")
    func seeds() async throws {
        try await withEngine { probe, runner in
            _ = try await probe.succeed(Self.generate("a fox", model: "z-image-turbo", seed: 7, mode: "on"))
            let job = try await probe.succeed(Self.generate("a fox", model: "z-image-turbo", seed: 1234, mode: "on"))
            #expect(runner.textCalls.withLock { $0.map(\.parameters.seed) } == [7, 1234])
            #expect(Self.ranPrompt(runner) == FakeRunner.lighthouse, "Z-Image's profile has no suffix")
            #expect(job.result?.effective["prompt_enhance"] == "on")
        }
    }

    @Test("Prompts that go as typed never load the backbone: auto on an optional profile (prose or structured), a detailed or JSON prompt, off")
    func asTyped() async throws {
        let detailed = Array(repeating: "word", count: 70).joined(separator: " ")
        let cases: [(JobRequest, String, warned: Bool)] = [
            (Self.generate("a fox"), "not_recommended", false),                                           // z-image-turbo, optional
            (Self.generate(detailed, model: "qwen-image-flash"), "passed_through", false),
            (Self.generate(#"{"caption": "a fox", "items": []}"#, model: "qwen-image-flash", mode: "on"), "passed_through", false),
            (Self.generate("a fox", model: "qwen-image-flash", mode: "off"), "off", false),
            (Self.generate("a fox", model: "moss-image-sft"), "not_recommended", false),                  // optional, structured
        ]
        for (request, outcome, warned) in cases {
            try await withEngine { probe, runner in
                let job = try await probe.succeed(request)
                let record = try #require(Self.enhancement(job))
                #expect(record["outcome"] == .string(outcome) && record["applied"] == false, "\(outcome)")
                #expect(record["prompt"] == nil && job.result?.effective["prompt"] == nil && job.result?.provenance.helpers == nil)
                #expect(Self.ranPrompt(runner) == request.inputs?["prompt"].flatMap { if case .text(let t) = $0 { t } else { nil } })
                #expect(runner.textCalls.withLock { $0.isEmpty } && !runner.prepared.withLock { $0 }.contains(PromptEnhance.backboneID))
                #expect(job.warnings.contains { $0.code == "prompt_enhance_ignored" } == warned, "\(outcome)")
                #expect(!job.warnings.contains { $0.code == "prompt_rewritten" })
            }
        }
    }

    @Test("Edits keep their instruction (the rewriter would need to see the image): needs_vision")
    func edit() async throws {
        // Edit declares prompt_enhance here because FLUX 3 Klein's upsampler may rewrite an instruction; Klein 4B's doesn't.
        try await withEngine(research: true) { probe, runner in
            let job = try await probe.succeed(JobRequest(
                operation: "image.edit", inputs: ["images": image(), "instruction": .text("make it night")],
                params: ["prompt_enhance": "on"], model: "klein-4b"))
            #expect(Self.ranPrompt(runner) == "make it night")
            #expect(Self.enhancement(job)?["outcome"] == "needs_vision" && runner.textCalls.withLock { $0.isEmpty })
            #expect(job.warnings.contains { $0.code == "prompt_enhance_ignored" && $0.param == "prompt_enhance" })
            #expect(job.result?.effective["prompt_enhance"] == "on" && job.result?.effective["instruction"] == nil)
        }
    }

    @Test("Under policy.license commercial-use a backbone whose terms don't allow it is skipped: helper_skipped_by_policy, the prompt as typed")
    func helperPolicy() async throws {
        let models = FakeModels(FakeModels.catalog.map { info in
            guard info.id.rawValue == PromptEnhance.backboneID else { return info }
            var info = info
            info.license = FakeModels.research
            return info
        })
        try await withEngine(research: true, models: models) { probe, runner in
            let job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "qwen-image-flash",
                                                            policy: Policy(license: .commercialUse)))
            #expect(Self.ranPrompt(runner) == "a lighthouse at dusk" && runner.textCalls.withLock { $0.isEmpty })
            #expect(job.warnings.contains { $0.code == "helper_skipped_by_policy" && $0.param == "prompt_enhance" })
            #expect(job.result?.provenance.helpers == nil && Self.enhancement(job)?["outcome"] == "policy")
            // Without the policy the same backbone rewrites, and is listed.
            let any = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "qwen-image-flash"))
            #expect(any.result?.provenance.helpers?.first?.license.commercialUse == .no)
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

    @Test("Backbone switched off: auto reports unavailable and uses the prompt as typed; prompt_enhance isn't declared, so it's refused")
    func backboneOff() async throws {
        let enablement = ModelEnablement(file: nil)
        for id in PromptEnhance.backboneIDs { try enablement.set(id, enabled: false, optIn: false) }
        try await withEngine(enablement: enablement) { probe, runner in
            let job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "qwen-image-flash"))
            #expect(Self.enhancement(job)?["outcome"] == "unavailable" && Self.ranPrompt(runner) == "a lighthouse at dusk")
            #expect(runner.textCalls.withLock { $0.isEmpty })
            #expect(Self.declares(probe.operations, "image.generate") == false && job.result?.effective["prompt_enhance"] == nil)
            let reply = try await probe.wire.json("POST", "jobs", Self.generate("a fox", model: "qwen-image-flash", mode: "on"))
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
            #expect(job.warnings.contains { $0.code == "prompt_rewritten" && $0.param == "prompt" } && upsample() == nil)
            #expect(Self.ranPrompt(runner) == "a lighthouse at dusk" && runner.textCalls.withLock { $0.isEmpty })
            // Part of the model, not a helper, and its rewrite isn't handed back (Image §1.9 allows that).
            #expect(job.result?.provenance.helpers == nil && job.result?.effective["prompt"] == nil)

            // off: upsample false, not applied, and a warning that its makers require it.
            job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "flux-3-klein", mode: "off"))
            record = try #require(Self.enhancement(job))
            #expect(record["outcome"] == "off" && record["applied"] == false && upsample() == .bool(false))
            #expect(job.warnings.contains { $0.code == "prompt_upsampler_off" } && !job.warnings.contains { $0.code == "prompt_rewritten" })

            // on: upsample true.
            job = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "flux-3-klein", mode: "on"))
            #expect(Self.enhancement(job)?["applied"] == true && upsample() == .bool(true))

            // An edit's own instruction follows the mode too.
            job = try await probe.succeed(JobRequest(
                operation: "image.edit", inputs: ["images": image(), "instruction": .text("make it night")],
                params: ["prompt_enhance": "off"], model: "flux-3-klein"))
            #expect(Self.ranPrompt(runner) == "make it night" && upsample() == .bool(false))
            #expect(Self.enhancement(job)?["outcome"] == "off")

            // A prompt the engine wrote (fill's marker instruction; fill declares no prompt_enhance) is never upsampled.
            _ = try await probe.succeed(JobRequest(
                operation: "image.fill", inputs: ["image": image(), "mask": .one(.inline(mediaType: "image/png", data: Fixtures.mask())),
                                                  "prompt": .text("a snowy owl")], model: "flux-3-klein"))
            #expect(Self.ranPrompt(runner)?.contains("magenta area with a snowy owl") == true && upsample() == .bool(false))

            // Another model declares no such key, so none is sent.
            _ = try await probe.succeed(Self.generate("a lighthouse at dusk", model: "klein-4b", mode: "off"))
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
