import Foundation
import ImageServerAPI
import ImageServerCatalog
import ImageServerModels
@testable import MESConformance
import MESCore
import MESEngineCore
import MLXToolKit
@testable import PixelAgencyImageEngine
import Testing

// Adapters through MES 0.4's first-class fields (Base §6.3, Image §1.10; AB-D-0155, L4–L5): the runtime's adapter catalog
// listed on each model offer, `request.adapters` checked and the model chosen by MESEngineCore, the enabled set, IC slots,
// triggers and templates, and what ran in `provenance.adapters`.

@Suite("Adapters (L4–L5)", .serialized)
struct AdaptersTests {
    static let backgroundRemove = AdapterInfo(
        id: "flux2-klein:background-remove", title: "Background Remove", kind: "plain", baseModels: ["flux2-klein-4b"],
        capabilities: [.imageEdit], trigger: "Remove the background from the image",
        promptTemplate: "Remove the background from the image", license: "Apache-2.0", commercialUse: "allowed",
        notice: "Keep this repo's NOTICE file with any copy.", licenseURL: "https://huggingface.co/xocialize/bg/blob/abc/LICENSE",
        defaultStrength: 1.1, status: "verified", clearance: ["flux2-klein-4b": "mechanical"], bytes: 76_039_072)
    static let tryon = AdapterInfo(
        id: "flux2-klein:tryon", title: "Try-on", kind: "ic", baseModels: ["flux2-klein-4b"], capabilities: [.imageEdit],
        trigger: "TRYON", promptTemplate: "TRYON a full-body photo of a person in the reference outfit.", license: "Apache-2.0",
        commercialUse: "allowed", defaultStrength: 1, strengthMax: 1.5,
        conditioning: [.init(role: "person", media: "image", required: true, maxCount: 1),
                       .init(role: "top", media: "image", required: true, maxCount: 1),
                       .init(role: "bottom", media: "image", required: true, maxCount: 1)],
        status: "verified", clearance: ["flux2-klein-4b": "perceptual"], bytes: 92_426_760)
    /// Its terms don't allow commercial use: opt-in.
    static let noncommercial = AdapterInfo(
        id: "flux2-klein:sketch", title: "Sketch", kind: "plain", baseModels: ["flux2-klein-4b"], capabilities: [.imageEdit],
        license: "CC-BY-NC-4.0", commercialUse: "prohibited", defaultStrength: 1, status: "verified")
    /// Never offered.
    static let withdrawn = AdapterInfo(
        id: "flux2-klein:object-remove", title: "Object Removal", kind: "plain", baseModels: ["flux2-klein-4b"],
        capabilities: [.imageEdit], license: "Apache-2.0", commercialUse: "allowed", defaultStrength: 1.1, status: "withdrawn")
    /// OpenRAIL: commercial use on conditions.
    static let martha = AdapterInfo(
        id: "qwen-image:martha", title: "Martha", kind: "plain", baseModels: ["qwen-image"], capabilities: [.textToImage],
        trigger: "mrth", license: "CreativeML-OpenRAIL-M", commercialUse: "conditional", defaultStrength: 0.8,
        status: "verified", clearance: ["qwen-image": "perceptual"])
    /// Not yet judged here, and its licence doesn't say: opt-in.
    static let dott = AdapterInfo(
        id: "qwen-image:dott4k", title: "Day of the Tentacle", kind: "plain", baseModels: ["qwen-image"],
        capabilities: [.textToImage], license: "NOASSERTION", commercialUse: "unknown", defaultStrength: 1,
        status: "candidate", clearance: ["qwen-image": "declared"])
    /// A reference-conditioned text-to-image adapter (none is vendored yet): its slot fills from generate's `references`.
    static let pose = AdapterInfo(
        id: "qwen-image:pose", title: "Pose", kind: "ic", baseModels: ["qwen-image"], capabilities: [.textToImage],
        license: "Apache-2.0", commercialUse: "allowed", defaultStrength: 1,
        conditioning: [.init(role: "pose", media: "image", required: true, maxCount: 1, note: "An OpenPose skeleton.")],
        status: "verified")

    /// The fake catalog with Klein's and Qwen-Image Flash's adapters.
    /// With `pose`, Qwen-Image Flash's surface runs IC adapters too.
    static func models(pose: Bool = false) -> FakeModels {
        let infos = FakeModels.catalog.map { info -> ModelInfo in
            var info = info
            switch info.id.rawValue {
            case "klein-4b": info.adapters = [backgroundRemove, tryon, noncommercial, withdrawn]
            case "qwen-image-flash": info.adapters = [martha, dott] + (pose ? [Self.pose] : [])
            default: break
            }
            return info
        }
        return FakeModels(infos, supports: [
            "klein-4b": AdapterSupport(baseModel: "flux2-klein-4b", formats: [.bflFused], kinds: [.plain, .referenceConditioned],
                                       maxCount: 1, strengthRange: .init(min: 0, max: 2)),
            "qwen-image-flash": AdapterSupport(baseModel: "qwen-image", formats: [.bflFused],
                                               kinds: pose ? [.plain, .referenceConditioned] : [.plain], maxCount: 2,
                                               strengthRange: .init(min: 0, max: 1.5)),
        ])
    }

    static func engine(research: Bool = false, enablement: ModelEnablement? = nil) -> ImageNormalizer {
        ImageNormalizer(directory: models(), runner: FakeRunner(), options: .init(allowResearch: research, enablement: enablement))
    }

    static func adapters(_ items: [(String, Double?)]) -> [AdapterRequest]? {
        items.isEmpty ? nil : items.map { AdapterRequest(id: $0.0, strength: $0.1) }
    }

    static func edit(_ instruction: String, images count: Int = 1, model: String? = nil, policy: Policy? = nil,
                     params: [String: MESValue] = [:], _ items: (String, Double?)...) -> JobRequest {
        let images = (0..<count).map { _ in InputValue.inline(mediaType: "image/png", data: Fixtures.png()) }
        return JobRequest(operation: "image.edit", inputs: ["images": .many(images), "instruction": .text(instruction)],
                          params: params.merging(["seed": 3]) { a, _ in a }, model: model, policy: policy,
                          adapters: adapters(items))
    }

    static func generate(_ prompt: String, model: String? = nil, quality: String? = nil, policy: Policy? = nil,
                         references: Int = 0, _ items: (String, Double?)...) -> JobRequest {
        var params: [String: MESValue] = ["size": ["width": 256, "height": 256], "seed": 5]
        if let quality { params["quality"] = .string(quality) }
        var inputs: [String: RequestInput] = ["prompt": .text(prompt)]
        if references > 0 {
            inputs["references"] = .many((0..<references).map { _ in .inline(mediaType: "image/png", data: Fixtures.png()) })
        }
        return JobRequest(operation: "image.generate", inputs: inputs, params: params, model: model, policy: policy,
                          adapters: adapters(items))
    }

    /// The image model's last call.
    static func lastRun(_ runner: FakeRunner) -> RunWork? {
        runner.calls.withLock { $0 }.last { $0.route.capability == .textToImage || $0.route.capability == .imageEdit }
    }

    /// The adapters `model` offers on `operation`, by id.
    static func offered(_ ops: [Descriptor], _ operation: String, _ model: String) -> [String] {
        ops.first { $0.operation == operation }?.models.first { $0.id == model }?.adapters?.map(\.id) ?? []
    }

    static let revision = String(repeating: "ab", count: 20)

    @Test("Each generate and edit offer lists the adapters its model takes, with max_adapters, strengths, licence and notes")
    func descriptor() async throws {
        let ops = await Self.engine().descriptors()
        let edit = try #require(ops.first { $0.operation == "image.edit" })
        let klein = try #require(edit.models.first { $0.id == "klein-4b" })
        #expect(klein.adapters?.map(\.id) == ["flux2-klein:background-remove", "flux2-klein:tryon"],
                "opt-in and withdrawn adapters aren't offered")
        #expect(klein.maxAdapters == 1 && klein.adapterLimit == 1)
        #expect(edit.models.filter { $0.id != "klein-4b" }.allSatisfy { $0.adapters == nil && $0.maxAdapters == nil })

        let bg = try #require(klein.adapter("flux2-klein:background-remove"))
        #expect(bg.kind == .plain && bg.slots == nil && bg.title == "Background Remove")
        #expect(bg.strength == .init(min: 0, max: 2, defaultValue: 1.1))
        #expect(bg.license.spdx == "Apache-2.0" && bg.license.commercialUse == .yes && bg.license.acceptedRequired == nil)
        #expect(bg.license.notice?.contains("NOTICE") == true)
        #expect(bg.notes?.contains("Without a prompt it runs \"Remove the background from the image\".") == true)
        // Try-on: its own narrower range, and its slots fill from the edit's images.
        let tryon = try #require(klein.adapter("flux2-klein:tryon"))
        #expect(tryon.kind == .ic && tryon.slots?.map(\.role) == ["person", "top", "bottom"] && tryon.requiredSlots == 3)
        #expect(tryon.slots?.allSatisfy { $0.kind == .image && $0.isRequired } == true)
        #expect(tryon.strength.max == 1.5 && tryon.strength.defaultValue == 1)
        #expect(tryon.notes?.contains("from images, in this order: person, top, bottom") == true)
        #expect(klein.notes?.contains("Adapters") != true, "offers list adapters themselves now, not in their notes")
        #expect(edit.params["properties"]?["prompt_enhance"]?["enum"] == ["auto", "on", "off"],
                "background-remove's template may rewrite an instruction, so edit declares prompt_enhance")

        // Generate: Qwen-Image Flash's adapter (OpenRAIL, conditional), two at a time; the candidate is opt-in.
        let generate = try #require(ops.first { $0.operation == "image.generate" })
        let flash = try #require(generate.models.first { $0.id == "qwen-image-flash" })
        #expect(flash.adapters?.map(\.id) == ["qwen-image:martha"] && flash.maxAdapters == 2)
        let martha = try #require(flash.adapter("qwen-image:martha"))
        #expect(martha.license.commercialUse == .yes && martha.license.notice?.contains("on the conditions of its licence") == true)
        #expect(martha.strength == .init(min: 0, max: 1.5, defaultValue: 0.8))
        #expect(martha.notes?.contains("adds its trigger, \"mrth\"") == true)
        #expect(generate.inputs.allSatisfy { $0.name != "references" }, "no IC adapter on generate, so no references")
        // The old extension is gone, and so is its annotation.
        #expect(ops.allSatisfy { $0.extensions?.contains { $0.name.hasPrefix("x-pixelagency.adapters") } != true })
        #expect(ops.filter { Adapters.operations[$0.operation] == nil }.allSatisfy { $0.models.allSatisfy { $0.adapters == nil } })

        // A catalog without adapters lists none, and an edit nothing rewrites declares no prompt_enhance.
        let bare = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner()).descriptors()
        #expect(bare.allSatisfy { $0.models.allSatisfy { $0.adapters == nil } })
        #expect(bare.first { $0.operation == "image.edit" }?.params["properties"]?["prompt_enhance"] == nil)
    }

    @Test("Conformance with adapters on offer: BASE-013, BASE-029, IMAGE-012 and IMAGE-013 run and pass")
    func conformance() async throws {
        try await withEngine(research: true, models: Self.models()) { probe, _ in
            let report = await ConformanceRunner.run(probe)
            let failed = report.results.filter { $0.status == .fail }.map { "\($0.id): \($0.detail ?? "")" }
            #expect(failed.isEmpty, "\(failed.joined(separator: "\n"))")
            #expect(report.conformsToBase && report.conformsToImage == true)
            for id in ["BASE-013", "BASE-029", "IMAGE-012", "IMAGE-013"] {
                #expect(report.results.first { $0.id == id }?.status == .pass, "\(id) didn't run")
            }
        }
    }

    @Test("The enabled set: adapter:<id> switches an adapter; opt-in ones start off and need --allow-research headless; withdrawn never")
    func enabledSet() async throws {
        #expect(Self.offered(await Self.engine(research: true).descriptors(), "image.edit", "klein-4b")
            == ["flux2-klein:background-remove", "flux2-klein:tryon", "flux2-klein:sketch"])
        #expect(Self.offered(await Self.engine(research: true).descriptors(), "image.generate", "qwen-image-flash")
            == ["qwen-image:martha", "qwen-image:dott4k"])

        let enablement = ModelEnablement(file: nil)
        let engine = Self.engine(enablement: enablement)
        #expect(Self.offered(await engine.descriptors(), "image.edit", "klein-4b") == ["flux2-klein:background-remove", "flux2-klein:tryon"])
        try enablement.set(Adapters.key("flux2-klein:background-remove"), enabled: false, optIn: false)
        try enablement.set(Adapters.key("qwen-image:dott4k"), enabled: true, optIn: true)
        let ops = await engine.descriptors()
        #expect(Self.offered(ops, "image.edit", "klein-4b") == ["flux2-klein:tryon"])
        #expect(Self.offered(ops, "image.generate", "qwen-image-flash") == ["qwen-image:martha", "qwen-image:dott4k"])
        let dott = try #require(ops.first { $0.operation == "image.generate" }?.models.first { $0.id == "qwen-image-flash" }?
            .adapter("qwen-image:dott4k"))
        #expect(dott.license.commercialUse == .unknown && dott.license.acceptedRequired == true)
        #expect(dott.notes?.contains("A candidate") == true)

        // The model cards' view: every adapter that isn't withdrawn, on or off.
        let catalog = await engine.catalogDescriptors()
        #expect(Self.offered(catalog, "image.edit", "klein-4b")
            == ["flux2-klein:background-remove", "flux2-klein:tryon", "flux2-klein:sketch"])
        #expect(Adapters.models(taking: "flux2-klein:sketch", in: catalog.first { $0.operation == "image.edit" }!) == ["klein-4b"])
        #expect(Adapters.isOptIn(Self.dott) && Adapters.isOptIn(Self.noncommercial) && !Adapters.isOptIn(Self.martha))
        #expect(Adapters.adapterID(fromKey: "adapter:qwen-image:martha") == "qwen-image:martha"
            && Adapters.adapterID(fromKey: "klein-4b") == nil)
    }

    @Test("background-remove on an edit: the template stands in for an empty instruction; strength and pinned commit in provenance")
    func backgroundRemove() async throws {
        try await withEngine(models: Self.models()) { probe, runner in
            let job = try await probe.succeed(Self.edit("", ("flux2-klein:background-remove", 0.9)))
            let work = try #require(Self.lastRun(runner))
            #expect(work.route.id == "klein-4b")
            #expect(work.spec.adapters == [JobAdapter(id: "flux2-klein:background-remove", strength: 0.9)])
            #expect(work.spec.params["prompt"] == .string("Remove the background from the image"))
            #expect(work.inputs["images"]?.count == 1 && work.inputs.count == 1)
            #expect(job.warnings.contains { $0.code == "prompt_rewritten" && $0.param == "instruction" })
            #expect(job.result?.effective["instruction"] == "Remove the background from the image")
            #expect(job.result?.effective["prompt_enhance"] == "auto")

            let applied = try #require(job.result?.provenance.adapters)
            #expect(applied == [AdapterRef(id: "flux2-klein:background-remove", title: "Background Remove", revision: Self.revision,
                                           license: Adapters.license(Self.backgroundRemove), strength: 0.9)])
            #expect(job.result?.provenance.model.id == "klein-4b")
            #expect(job.result?.effective["model_params"]?["adapters"] == nil && job.result?.effective["model_params"]?["adapter_prompt"] == nil)

            // An instruction that already carries the trigger goes as typed; no strength: the adapter's default.
            let typed = try await probe.succeed(Self.edit("Remove the background from the image, keep the shadow",
                                                          ("flux2-klein:background-remove", nil)))
            #expect(Self.lastRun(runner)?.spec.params["prompt"] == "Remove the background from the image, keep the shadow")
            #expect(Self.lastRun(runner)?.spec.adapters == [JobAdapter(id: "flux2-klein:background-remove", strength: 1.1)])
            #expect(typed.result?.provenance.adapters?.first?.strength == 1.1)
            #expect(!typed.warnings.contains { $0.code == "prompt_rewritten" } && typed.result?.effective["instruction"] == nil)

            // prompt_enhance off: the adapter still runs, the instruction goes as typed.
            let off = try await probe.succeed(Self.edit("make it a cutout", params: ["prompt_enhance": "off"],
                                                        ("flux2-klein:background-remove", nil)))
            #expect(Self.lastRun(runner)?.spec.params["prompt"] == "make it a cutout")
            #expect(Self.lastRun(runner)?.spec.adapters?.first?.id == "flux2-klein:background-remove")
            #expect(!off.warnings.contains { $0.code == "prompt_rewritten" } && off.result?.effective["prompt_enhance"] == "off")

            // Without adapters, nothing about them reaches the model or the result.
            let plain = try await probe.succeed(JobRequest(operation: "image.edit",
                                                           inputs: ["images": image(), "instruction": .text("make it night")]))
            #expect(Self.lastRun(runner)?.spec.adapters == nil && plain.result?.provenance.adapters == nil)
        }
    }

    @Test("An adapter implies its model: Qwen-Image Flash's adapter routes a generate that names no model there, its trigger after the enhancer's rewrite")
    func impliesModel() async throws {
        try await withEngine(models: Self.models()) { probe, runner in
            let job = try await probe.succeed(Self.generate("a fox in the snow", ("qwen-image:martha", nil)))
            let work = try #require(Self.lastRun(runner))
            #expect(work.route.id == "qwen-image-flash" && job.result?.provenance.model.id == "qwen-image-flash")
            #expect(work.spec.adapters == [JobAdapter(id: "qwen-image:martha", strength: 0.8)])
            let expected = "mrth " + FakeRunner.lighthouse + " " + PromptEnhanceTests.qwenSuffix
            #expect(work.spec.params["prompt"] == .string(expected))
            #expect(job.result?.effective["prompt"] == .string(expected))
            #expect(job.warnings.filter { $0.code == "prompt_rewritten" && $0.param == "prompt" }.count == 2, "the enhancer, then the trigger")
            #expect(job.result?.provenance.adapters?.map(\.strength) == [0.8])
            #expect(job.result?.provenance.helpers?.map(\.id) == [PromptEnhance.backboneID])

            // Without adapters the default stays the default.
            _ = try await probe.succeed(Self.generate("a fox in the snow"))
            #expect(Self.lastRun(runner)?.route.id == "z-image-turbo" && Self.lastRun(runner)?.spec.adapters == nil)
        }
    }

    @Test("Try-on (IC): its slots take the edit's images in order, each in an input of its own; too few is 400")
    func referenceConditioned() async throws {
        try await withEngine(models: Self.models()) { probe, runner in
            let job = try await probe.succeed(Self.edit("in a red jacket", images: 3, ("flux2-klein:tryon", nil)))
            let work = try #require(Self.lastRun(runner))
            let adapter = try #require(work.spec.adapters?.first)
            #expect(adapter.id == "flux2-klein:tryon"
                && adapter.conditioning == ["person": "adapter0.person", "top": "adapter0.top", "bottom": "adapter0.bottom"])
            #expect(["adapter0.person", "adapter0.top", "adapter0.bottom"].allSatisfy { work.inputs[$0]?.count == 1 })
            #expect(work.inputs["images"]?.isEmpty == true, "every image went to a slot")
            #expect(work.spec.params["prompt"] == "TRYON in a red jacket")
            #expect(job.result?.outputs.first?.width == 64, "the first image still sets the size")

            // Too few images for its slots: 400 (Image §1.10).
            let reply = try await probe.wire.json("POST", "jobs", Self.edit("in a red jacket", images: 2, ("flux2-klein:tryon", nil)))
            #expect(reply.status == 400 && reply.errorCode == "invalid_request")
        }
    }

    @Test("An IC adapter on generate: references are declared, and fill its slots (Image §1.10)")
    func references() async throws {
        let ops = await ImageNormalizer(directory: Self.models(pose: true), runner: FakeRunner()).descriptors()
        let references = try #require(ops.first { $0.operation == "image.generate" }?.inputs.first { $0.name == "references" })
        #expect(references.kind == .image && !references.required && references.min == 0 && references.max == 1)
        #expect(ops.first { $0.operation == "image.generate" }?.models.first { $0.id == "qwen-image-flash" }?
            .adapter("qwen-image:pose")?.notes?.contains("from references") == true)

        try await withEngine(models: Self.models(pose: true)) { probe, runner in
            let job = try await probe.succeed(Self.generate("a dancer", model: "qwen-image-flash", references: 1, ("qwen-image:pose", nil)))
            let work = try #require(Self.lastRun(runner))
            #expect(work.spec.adapters?.first?.conditioning == ["pose": "adapter0.pose"] && work.inputs["adapter0.pose"]?.count == 1)
            #expect(job.result?.provenance.adapters?.map(\.id) == ["qwen-image:pose"])
            let reply = try await probe.wire.json("POST", "jobs", Self.generate("a dancer", model: "qwen-image-flash", ("qwen-image:pose", nil)))
            #expect(reply.status == 400 && reply.errorCode == "invalid_request")
        }
    }

    @Test("Refused at submit by MESEngineCore, in Base §6.3's terms: unknown, repeated, the wrong model, too many, out of range, no model the engine may pick")
    func refusals() async throws {
        try await withEngine(research: true, models: Self.models()) { probe, _ in
            func submit(_ request: JobRequest) async throws -> (Int, String?) {
                let reply = try await probe.wire.json("POST", "jobs", request)
                return (reply.status, reply.errorCode)
            }
            // Not on offer (withdrawn adapters never are).
            #expect(try await submit(Self.edit("x", ("flux2-klein:object-remove", nil))) == (422, "unsupported_parameter"))
            #expect(try await submit(Self.edit("x", ("nobody:nothing", nil))) == (422, "unsupported_parameter"))
            // Listed twice.
            #expect(try await submit(Self.generate("x", ("qwen-image:martha", nil), ("qwen-image:martha", nil))) == (400, "invalid_request"))
            // A named model that doesn't take it.
            #expect(try await submit(Self.generate("x", model: "z-image-turbo", ("qwen-image:martha", nil))) == (422, "unsupported_parameter"))
            #expect(try await submit(Self.edit("x", model: "mage-flow-edit-turbo", ("flux2-klein:background-remove", nil)))
                == (422, "unsupported_parameter"))
            // More than the model stacks.
            #expect(try await submit(Self.edit("x", ("flux2-klein:background-remove", nil), ("flux2-klein:sketch", nil)))
                == (422, "out_of_limits"))
            // A strength outside the adapter's range (try-on's own, narrower than Klein's).
            #expect(try await submit(Self.edit("x", images: 3, ("flux2-klein:tryon", 1.8))) == (422, "out_of_limits"))
            #expect(try await submit(Self.edit("x", ("flux2-klein:background-remove", 2.5))) == (422, "out_of_limits"))
            // Flash doesn't serve draft: nothing the engine may pick by itself takes the adapter, so the client names it.
            #expect(try await submit(Self.generate("x", quality: "draft", ("qwen-image:martha", nil))) == (422, "unsupported_parameter"))
            _ = try await probe.succeed(Self.generate("x", model: "qwen-image-flash", quality: "draft", ("qwen-image:martha", nil)))
            // The old extension is no longer declared.
            var old = Self.edit("x")
            old.extensions = ["x-pixelagency.adapters": [["id": "flux2-klein:background-remove"]]]
            #expect(try await submit(old) == (422, "unsupported_parameter"))
        }
    }

    @Test("policy.license commercial-use: refused (policy_unmet) for adapters whose terms don't allow it; conditional terms pass")
    func licencePolicy() async throws {
        try await withEngine(research: true, models: Self.models()) { probe, runner in
            let commercial = Policy(license: .commercialUse)
            for request in [Self.edit("x", policy: commercial, ("flux2-klein:sketch", nil)),
                            Self.generate("x", model: "qwen-image-flash", policy: commercial, ("qwen-image:dott4k", nil))] {
                let reply = try await probe.wire.json("POST", "jobs", request)
                #expect(reply.status == 422 && reply.errorCode == "policy_unmet")
            }
            let job = try await probe.succeed(Self.generate("x", policy: commercial, ("qwen-image:martha", nil)))
            #expect(Self.lastRun(runner)?.spec.adapters?.first?.id == "qwen-image:martha")
            let license = job.result?.provenance.adapters?.first?.license
            #expect(license?.spdx == "CreativeML-OpenRAIL-M" && license?.commercialUse == .yes)
            // Under license: any, the same adapters run.
            _ = try await probe.succeed(Self.edit("x", ("flux2-klein:sketch", nil)))
        }
    }

    @Test("Model choice with adapters prefers an offer that stacks as many as asked")
    func stacking() {
        let license = MESCore.License(spdx: "Apache-2.0", commercialUse: .yes)
        let a = AdapterOffer(id: "x:a", title: "A", strength: .init(min: 0, max: 2, defaultValue: 1), license: license)
        let b = AdapterOffer(id: "x:b", title: "B", strength: .init(min: 0, max: 2, defaultValue: 1), license: license)
        let one = ModelOffer(id: "klein-4b", title: "Klein", license: license, qualityTiers: [.standard], adapters: [a, b], maxAdapters: 1)
        let two = ModelOffer(id: "qwen-image-flash", title: "Flash", license: license, qualityTiers: [.standard], adapters: [a, b],
                             maxAdapters: 2)
        let engine = Self.engine()
        let descriptor = Descriptor(operation: "image.generate", profile: ImageProfile.id, profileVersion: ImageProfile.version,
                                    title: "Generate", inputs: [], params: ["type": "object"], outputs: [], qualityTiers: [.standard],
                                    models: [one, two])
        var request = Self.generate("x", ("x:a", nil), ("x:b", nil))
        #expect(engine.defaultModel(for: request, descriptor: descriptor, kitChoice: one, candidates: [one, two])?.id == "qwen-image-flash")
        request.adapters = [AdapterRequest(id: "x:a")]
        #expect(engine.defaultModel(for: request, descriptor: descriptor, kitChoice: one, candidates: [one, two]) == nil,
                "one adapter: the kit's choice stands")
    }

    @Test("Prompts: a template wraps the prompt, a trigger word or sentence is added once, an empty prompt takes the template")
    func prompts() {
        func info(trigger: String? = nil, template: String? = nil) -> AdapterInfo {
            AdapterInfo(id: "x:y", title: "Y", kind: "plain", baseModels: [], capabilities: [], trigger: trigger,
                        promptTemplate: template, license: "Apache-2.0", commercialUse: "allowed", defaultStrength: 1, status: "verified")
        }
        #expect(Adapters.prompt("a fox", for: [info(trigger: "mrth")]) == ("mrth a fox", ["x:y"]))
        #expect(Adapters.prompt("MRTH, a fox", for: [info(trigger: "mrth")]) == ("MRTH, a fox", []))
        #expect(Adapters.prompt("keep the shadow", for: [info(trigger: "Remove the background")]).prompt
            == "Remove the background. keep the shadow")
        #expect(Adapters.prompt("a fox", for: [info(trigger: "sks", template: "sks style, {prompt}, high detail")]).prompt
            == "sks style, a fox, high detail")
        #expect(Adapters.prompt("  ", for: [info(template: "2x2 sprite sheet")]) == ("2x2 sprite sheet", ["x:y"]))
        #expect(Adapters.prompt("a fox", for: []) == ("a fox", []))
        #expect(Adapters.rewrites(info(trigger: "mrth")) && Adapters.rewrites(info(template: "x")) && !Adapters.rewrites(info()))
    }

    @Test("The runtime's own catalog: Klein's background-remove is offered on edit and what the engine sends passes the runtime's check")
    @MainActor
    func runtimeCatalog() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("pa-adapters-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let runtime = await ImageRuntime.start(modelStore: store, catalog: ModelCatalog.all(environment: [:]),
                                               adapters: ModelCatalog.adapters())
        let ops = await runtime.normalizer.descriptors()
        let ids = Self.offered(ops, "image.edit", "klein-4b")
        #expect(ids.contains("flux2-klein:background-remove") && ids.contains("flux2-klein:tryon"))
        #expect(!ids.contains("flux2-klein:object-remove"), "withdrawn in the registry")
        // Qwen-Image Flash's 27 are all candidates: opt-in, so headless only with --allow-research.
        #expect(ops.first { $0.operation == "image.generate" }?.models.allSatisfy { $0.adapters == nil } == true)

        let route = try await runtime.service.route(.imageEdit, model: "klein-4b")
        let spec = JobSpec(capability: .imageEdit, model: route.id, params: ["prompt": "Remove the background from the image"],
                           inputs: ["images": [AssetID(rawValue: "ast_1")]], count: 1,
                           adapters: [JobAdapter(id: "flux2-klein:background-remove", strength: 1.1)])
        #expect(SubmitValidation.adapterProblem(spec, route: route) == nil)
        #expect(RunPlan.pinned(route.adapters.first { $0.id == "flux2-klein:background-remove" }?.source.revision ?? "") != nil)
    }
}
