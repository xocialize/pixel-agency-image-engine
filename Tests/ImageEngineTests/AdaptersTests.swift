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

// Adapters through MES (AB-D-0155, L4; docs/PROMPTS-AND-ADAPTERS.md §2.2): the runtime's adapter catalog offered as
// `x-pixelagency.adapters` on generate and edit, an adapter implying its model, licence policy, the enabled set, and what
// ran in `effective.model_params.adapters`.

@Suite("Adapters (L4)", .serialized)
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

    /// The fake catalog with Klein's and Qwen-Image Flash's adapters.
    static func models() -> FakeModels {
        let infos = FakeModels.catalog.map { info -> ModelInfo in
            var info = info
            switch info.id.rawValue {
            case "klein-4b": info.adapters = [backgroundRemove, tryon, noncommercial, withdrawn]
            case "qwen-image-flash": info.adapters = [martha, dott]
            default: break
            }
            return info
        }
        return FakeModels(infos, supports: [
            "klein-4b": AdapterSupport(baseModel: "flux2-klein-4b", formats: [.bflFused], kinds: [.plain, .referenceConditioned],
                                       maxCount: 1, strengthRange: .init(min: 0, max: 2)),
            "qwen-image-flash": AdapterSupport(baseModel: "qwen-image", formats: [.bflFused], maxCount: 2,
                                               strengthRange: .init(min: 0, max: 1.5)),
        ])
    }

    static func engine(research: Bool = false, enablement: ModelEnablement? = nil) -> ImageNormalizer {
        ImageNormalizer(directory: models(), runner: FakeRunner(), options: .init(allowResearch: research, enablement: enablement))
    }

    static func adapters(_ items: MESValue...) -> [String: MESValue] { [Adapters.name: .array(items)] }

    static func edit(_ instruction: String, images count: Int = 1, model: String? = nil, policy: Policy? = nil,
                     _ items: MESValue...) -> JobRequest {
        let images = (0..<count).map { _ in InputValue.inline(mediaType: "image/png", data: Fixtures.png()) }
        return JobRequest(operation: "image.edit", inputs: ["images": .many(images), "instruction": .text(instruction)],
                          params: ["seed": 3], model: model, policy: policy, extensions: [Adapters.name: .array(items)])
    }

    static func generate(_ prompt: String, model: String? = nil, quality: String? = nil, policy: Policy? = nil,
                         _ items: MESValue...) -> JobRequest {
        var params: [String: MESValue] = ["size": ["width": 256, "height": 256], "seed": 5]
        if let quality { params["quality"] = .string(quality) }
        return JobRequest(operation: "image.generate", inputs: ["prompt": .text(prompt)], params: params, model: model,
                          policy: policy, extensions: [Adapters.name: .array(items),
                                                       PromptEnhance.name: ["mode": "off"]])
    }

    /// The image model's last call.
    static func lastRun(_ runner: FakeRunner) -> RunWork? {
        runner.calls.withLock { $0 }.last { $0.route.capability == .textToImage || $0.route.capability == .imageEdit }
    }

    static func ext(_ descriptor: Descriptor?) -> ExtensionSpec? { descriptor?.extensions?.first { $0.name == Adapters.name } }

    @Test("Generate and edit offer the adapters their models take; each offer names its own; the schema carries their metadata")
    func descriptor() async throws {
        let ops = await Self.engine().descriptors()
        let edit = try #require(Self.ext(ops.first { $0.operation == "image.edit" }))
        #expect(edit.schema["type"] == "array" && edit.schema["maxItems"] == 1)
        #expect(edit.schema["items"]?["properties"]?["id"]?["enum"] == ["flux2-klein:background-remove", "flux2-klein:tryon"],
                "opt-in and withdrawn adapters aren't offered")
        #expect(edit.schema["items"]?["additionalProperties"] == false && edit.schema["items"]?["required"] == ["id"])
        // Strength: the union, and try-on's narrower range by id.
        #expect(edit.schema["items"]?["properties"]?["strength"]?["maximum"] == 2)
        #expect(edit.schema["items"]?["allOf"]?.arrayValue?.first?["then"]?["properties"]?["strength"]?["maximum"] == 1.5)

        let offers = try #require(edit.schema["x-pixelagency-adapters"]?.arrayValue)
        let bg = try #require(offers.first { $0["id"] == "flux2-klein:background-remove" })
        #expect(bg["models"] == ["klein-4b"] && bg["kind"] == "plain" && bg["strength"]?["default"] == 1.1)
        #expect(bg["license"]?["spdx"] == "Apache-2.0" && bg["license"]?["commercial_use"] == true)
        #expect(bg["license"]?["notice"]?.stringValue?.contains("NOTICE") == true && bg["license"]?["accepted_required"] == nil)
        #expect(bg["prompt_template"] == "Remove the background from the image" && bg["clearance"]?["flux2-klein-4b"] == "mechanical")
        #expect(bg["bytes"] == 76_039_072 && bg["status"] == "verified")
        let tryon = try #require(offers.first { $0["id"] == "flux2-klein:tryon" })
        #expect(tryon["kind"] == "ic" && tryon["slots"]?.arrayValue?.compactMap { $0["role"]?.stringValue } == ["person", "top", "bottom"])
        #expect(tryon["notes"]?.stringValue?.contains("in this order: person, top, bottom") == true)

        let klein = try #require(ops.first { $0.operation == "image.edit" }?.models.first { $0.id == "klein-4b" })
        #expect(klein.notes?.contains("Adapters (x-pixelagency.adapters, at most 1 per request): flux2-klein:background-remove, flux2-klein:tryon.") == true)

        // Generate: Qwen-Image Flash's adapter (OpenRAIL, conditional); the candidate is opt-in.
        let generate = try #require(Self.ext(ops.first { $0.operation == "image.generate" }))
        #expect(generate.schema["items"]?["properties"]?["id"]?["enum"] == ["qwen-image:martha"] && generate.schema["maxItems"] == 2)
        let martha = try #require(generate.schema["x-pixelagency-adapters"]?.arrayValue?.first)
        #expect(martha["license"]?["commercial_use"] == true)
        #expect(martha["license"]?["notice"]?.stringValue?.contains("on the conditions of its licence") == true)
        #expect(ops.filter { Adapters.operations[$0.operation] == nil }.allSatisfy { Self.ext($0) == nil })

        // A catalog without adapters declares no extension.
        let bare = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner()).descriptors()
        #expect(bare.allSatisfy { Self.ext($0) == nil })
    }

    @Test("Conformance holds with the extension declared on generate and edit")
    func conformance() async throws {
        try await withEngine(research: true, models: Self.models()) { probe, _ in
            let report = await ConformanceRunner.run(probe)
            let failed = report.results.filter { $0.status == .fail }.map { "\($0.id): \($0.detail ?? "")" }
            #expect(failed.isEmpty, "\(failed.joined(separator: "\n"))")
            #expect(report.conformsToBase && report.conformsToImage == true)
        }
    }

    @Test("The enabled set: adapter:<id> switches an adapter; opt-in ones start off and need --allow-research headless; withdrawn never")
    func enabledSet() async throws {
        func ids(_ engine: ImageNormalizer, _ operation: String) async -> [String] {
            let d = await engine.descriptors().first { $0.operation == operation }
            return Self.ext(d)?.schema["items"]?["properties"]?["id"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }
        #expect(await ids(Self.engine(research: true), "image.edit")
            == ["flux2-klein:background-remove", "flux2-klein:tryon", "flux2-klein:sketch"])
        #expect(await ids(Self.engine(research: true), "image.generate") == ["qwen-image:martha", "qwen-image:dott4k"])

        let enablement = ModelEnablement(file: nil)
        let engine = Self.engine(enablement: enablement)
        #expect(await ids(engine, "image.edit") == ["flux2-klein:background-remove", "flux2-klein:tryon"])
        try enablement.set(Adapters.key("flux2-klein:background-remove"), enabled: false, optIn: false)
        try enablement.set(Adapters.key("qwen-image:dott4k"), enabled: true, optIn: true)
        #expect(await ids(engine, "image.edit") == ["flux2-klein:tryon"])
        #expect(await ids(engine, "image.generate") == ["qwen-image:martha", "qwen-image:dott4k"])
        let dott = try #require(await engine.descriptors().first { $0.operation == "image.generate" }
            .flatMap { Self.ext($0)?.schema["x-pixelagency-adapters"]?.arrayValue?.first { $0["id"] == "qwen-image:dott4k" } })
        #expect(dott["license"]?["commercial_use"] == "unknown" && dott["license"]?["accepted_required"] == true)

        // The model cards' view: every adapter that isn't withdrawn, on or off.
        let catalog = await engine.catalogDescriptors().first { $0.operation == "image.edit" }
        #expect(Self.ext(catalog)?.schema["items"]?["properties"]?["id"]?["enum"]
            == ["flux2-klein:background-remove", "flux2-klein:tryon", "flux2-klein:sketch"])
        #expect(Adapters.isOptIn(Self.dott) && Adapters.isOptIn(Self.noncommercial) && !Adapters.isOptIn(Self.martha))
        #expect(Adapters.adapterID(fromKey: "adapter:qwen-image:martha") == "qwen-image:martha"
            && Adapters.adapterID(fromKey: "klein-4b") == nil)
    }

    @Test("background-remove on an edit: the template stands in for an empty instruction; the strength and the pinned file are reported")
    func backgroundRemove() async throws {
        try await withEngine(models: Self.models()) { probe, runner in
            let job = try await probe.succeed(Self.edit("", ["id": "flux2-klein:background-remove", "strength": 0.9]))
            let work = try #require(Self.lastRun(runner))
            #expect(work.route.id == "klein-4b")
            #expect(work.spec.adapters == [JobAdapter(id: "flux2-klein:background-remove", strength: 0.9)])
            #expect(work.spec.params["prompt"] == .string("Remove the background from the image"))
            #expect(work.inputs["images"]?.count == 1 && work.inputs.count == 1)
            #expect(job.warnings.contains { $0.code == "prompt_rewritten" && $0.param == "instruction" })

            let params = try #require(job.result?.effective["model_params"])
            let record = try #require(params["adapters"]?.arrayValue?.first)
            #expect(record["id"] == "flux2-klein:background-remove" && record["title"] == "Background Remove" && record["strength"] == 0.9)
            #expect(record["revision"] == .string(String(repeating: "ab", count: 20)))
            #expect(record["sha256"] == .string(String(repeating: "cd", count: 32)))
            #expect(record["source"] == "xocialize/background-remove-lora")
            #expect(record["license"]?["spdx"] == "Apache-2.0" && record["license"]?["commercial_use"] == true)
            #expect(params["adapter_prompt"] == "Remove the background from the image")
            #expect(job.result?.provenance.model.id == "klein-4b")

            // An instruction that already carries the trigger goes as typed; no strength: the adapter's default.
            let typed = try await probe.succeed(Self.edit("Remove the background from the image, keep the shadow",
                                                          ["id": "flux2-klein:background-remove"]))
            #expect(Self.lastRun(runner)?.spec.params["prompt"] == "Remove the background from the image, keep the shadow")
            #expect(Self.lastRun(runner)?.spec.adapters == [JobAdapter(id: "flux2-klein:background-remove")])
            #expect(typed.result?.effective["model_params"]?["adapters"]?.arrayValue?.first?["strength"] == 1.1)
            #expect(!typed.warnings.contains { $0.code == "prompt_rewritten" })

            // Without the extension, nothing about adapters reaches the model or the result.
            let plain = try await probe.succeed(JobRequest(operation: "image.edit",
                                                           inputs: ["images": image(), "instruction": .text("make it night")]))
            #expect(Self.lastRun(runner)?.spec.adapters == nil && plain.result?.effective["model_params"]?["adapters"] == nil)
        }
    }

    @Test("An adapter implies its model: Qwen-Image Flash's adapter routes a generate that names no model there, its trigger added")
    func impliesModel() async throws {
        try await withEngine(models: Self.models()) { probe, runner in
            let job = try await probe.succeed(Self.generate("a fox in the snow", ["id": "qwen-image:martha"]))
            let work = try #require(Self.lastRun(runner))
            #expect(work.route.id == "qwen-image-flash" && job.result?.provenance.model.id == "qwen-image-flash")
            #expect(work.spec.adapters == [JobAdapter(id: "qwen-image:martha")])
            #expect(work.spec.params["prompt"] == "mrth a fox in the snow")
            #expect(job.warnings.contains { $0.code == "prompt_rewritten" && $0.param == "prompt" })
            #expect(job.result?.effective["model_params"]?["adapters"]?.arrayValue?.first?["strength"] == 0.8)

            // Without adapters the default stays the default.
            _ = try await probe.succeed(Self.generate("a fox in the snow"))
            #expect(Self.lastRun(runner)?.route.id == "z-image-turbo" && Self.lastRun(runner)?.spec.adapters == nil)
        }
    }

    @Test("Try-on (IC): its slots take the edit's images in order, each in an input of its own")
    func referenceConditioned() async throws {
        try await withEngine(models: Self.models()) { probe, runner in
            let job = try await probe.succeed(Self.edit("in a red jacket", images: 3, ["id": "flux2-klein:tryon"]))
            let work = try #require(Self.lastRun(runner))
            let adapter = try #require(work.spec.adapters?.first)
            #expect(adapter.id == "flux2-klein:tryon"
                && adapter.conditioning == ["person": "adapter0.person", "top": "adapter0.top", "bottom": "adapter0.bottom"])
            #expect(["adapter0.person", "adapter0.top", "adapter0.bottom"].allSatisfy { work.inputs[$0]?.count == 1 })
            #expect(work.inputs["images"]?.isEmpty == true, "every image went to a slot")
            #expect(work.spec.params["prompt"] == "TRYON in a red jacket")
            #expect(job.result?.outputs.first?.width == 64, "the first image still sets the size")

            // Too few images for its slots: 400, naming them.
            let reply = try await probe.wire.json("POST", "jobs", Self.edit("in a red jacket", images: 2, ["id": "flux2-klein:tryon"]))
            #expect(reply.status == 400 && reply.errorCode == "invalid_request")
        }
    }

    @Test("Refused at submit, in MES 0.4's terms: unknown, repeated, the wrong model, too many, out of range, no model the engine may pick")
    func refusals() async throws {
        try await withEngine(research: true, models: Self.models()) { probe, _ in
            func submit(_ request: JobRequest) async throws -> (Int, String?) {
                let reply = try await probe.wire.json("POST", "jobs", request)
                return (reply.status, reply.errorCode)
            }
            let bg: MESValue = ["id": "flux2-klein:background-remove"]
            // Not on offer (withdrawn adapters never are): the schema's enum.
            #expect(try await submit(Self.edit("x", ["id": "flux2-klein:object-remove"])) == (422, "out_of_limits"))
            #expect(try await submit(Self.edit("x", ["id": "nobody:nothing"])).0 == 422)
            // Listed twice (Klein stacks one, Flash two: Flash shows the duplicate rule).
            #expect(try await submit(Self.generate("x", ["id": "qwen-image:martha"], ["id": "qwen-image:martha"]))
                == (400, "invalid_request"))
            // A named model that doesn't take it.
            #expect(try await submit(Self.generate("x", model: "z-image-turbo", ["id": "qwen-image:martha"]))
                == (422, "unsupported_parameter"))
            #expect(try await submit(Self.edit("x", model: "mage-flow-edit-turbo", bg)) == (422, "unsupported_parameter"))
            // More than the model stacks.
            #expect(try await submit(Self.edit("x", bg, ["id": "flux2-klein:sketch"])) == (422, "out_of_limits"))
            // A strength outside the adapter's range (try-on's own, narrower than Klein's).
            #expect(try await submit(Self.edit("x", images: 3, ["id": "flux2-klein:tryon", "strength": 1.8])) == (422, "out_of_limits"))
            #expect(try await submit(Self.edit("x", ["id": "flux2-klein:background-remove", "strength": 2.5])) == (422, "out_of_limits"))
            // Flash doesn't serve draft: nothing the engine may pick by itself takes the adapter, so the client names it.
            #expect(try await submit(Self.generate("x", quality: "draft", ["id": "qwen-image:martha"])) == (422, "unsupported_parameter"))
            _ = try await probe.succeed(Self.generate("x", model: "qwen-image-flash", quality: "draft", ["id": "qwen-image:martha"]))
        }
    }

    @Test("policy.license commercial-use: refused (policy_unmet) for adapters whose terms don't allow it; conditional terms pass")
    func licencePolicy() async throws {
        try await withEngine(research: true, models: Self.models()) { probe, runner in
            let commercial = Policy(license: .commercialUse)
            for request in [Self.edit("x", policy: commercial, ["id": "flux2-klein:sketch"]),
                            Self.generate("x", model: "qwen-image-flash", policy: commercial, ["id": "qwen-image:dott4k"])] {
                let reply = try await probe.wire.json("POST", "jobs", request)
                #expect(reply.status == 422 && reply.errorCode == "policy_unmet")
            }
            let job = try await probe.succeed(Self.generate("x", policy: commercial, ["id": "qwen-image:martha"]))
            #expect(Self.lastRun(runner)?.spec.adapters?.first?.id == "qwen-image:martha")
            let license = job.result?.effective["model_params"]?["adapters"]?.arrayValue?.first?["license"]
            #expect(license?["spdx"] == "CreativeML-OpenRAIL-M" && license?["commercial_use"] == true)
            // Under license: any, the same adapters run.
            _ = try await probe.succeed(Self.edit("x", ["id": "flux2-klein:sketch"]))
        }
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
    }

    @Test("The runtime's own catalog: Klein's background-remove is offered on edit and what the engine sends passes the runtime's check")
    @MainActor
    func runtimeCatalog() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("pa-adapters-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let runtime = await ImageRuntime.start(modelStore: store, catalog: ModelCatalog.all(environment: [:]),
                                               adapters: ModelCatalog.adapters())
        let ops = await runtime.normalizer.descriptors()
        let edit = try #require(Self.ext(ops.first { $0.operation == "image.edit" }))
        let ids = edit.schema["items"]?["properties"]?["id"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(ids.contains("flux2-klein:background-remove") && ids.contains("flux2-klein:tryon"))
        #expect(!ids.contains("flux2-klein:object-remove"), "withdrawn in the registry")
        let offer = try #require(edit.schema["x-pixelagency-adapters"]?.arrayValue?.first { $0["id"] == "flux2-klein:background-remove" })
        #expect(offer["models"]?.arrayValue?.contains("klein-4b") == true)
        // Qwen-Image Flash's 27 are all candidates: opt-in, so headless only with --allow-research.
        #expect(Self.ext(ops.first { $0.operation == "image.generate" }) == nil)

        let route = try await runtime.service.route(.imageEdit, model: "klein-4b")
        let spec = JobSpec(capability: .imageEdit, model: route.id, params: ["prompt": "Remove the background from the image"],
                           inputs: ["images": [AssetID(rawValue: "ast_1")]], count: 1,
                           adapters: [JobAdapter(id: "flux2-klein:background-remove", strength: 1.1)])
        #expect(SubmitValidation.adapterProblem(spec, route: route) == nil)
        #expect(route.adapters.first { $0.id == "flux2-klein:background-remove" }?.source.revision.count == 40)
    }
}
