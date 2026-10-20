import Foundation
import ImageServerAPI
import ImageServerModels
import MESCore
import MESEngineCore
import MLXToolKit

typealias MESValue = MESCore.JSONValue
typealias ISValue = ImageServerAPI.JSONValue

/// The Image Engine's normalizer (Engines-PRD ENG-5): MES operations and vocabulary in, model runs out.
///
/// - **Descriptors** come from the live catalog: one offer per registered model that serves the operation's
///   capability, with its licence in MES terms, its quality tiers and a default (`OperationTable`). Research and
///   work-in-progress models are offered only when the engine's operator opts in (OQ-4), and then `named_only`
///   (Base §6 rule 2), so they run only when a request names them.
/// - **Runs** resolve the model the engine kit chose, prepare it (download, load), run it, and then apply the Image
///   profile's rules to whatever came back: sizes snapped to the model's envelope (`size_snapped`), black-mask
///   pixels restored exactly (§1.7), exact ×scale upscales, upright sRGB in and out, alpha re-applied (§1.5).
public struct ImageNormalizer: MediaEngine {
    public struct Options: Sendable {
        /// Offer research and work-in-progress models (named-only). Off by default (Engines-PRD OQ-4). Ignored when
        /// there's an `enablement`, which decides model by model.
        public var allowResearch = false
        /// The operator's enabled set (the engine app's Models section, ENG-4): a model that's off isn't offered, and a
        /// research or work-in-progress model is offered, named-only, once its operator turned it on and accepted its
        /// terms. nil, as in the headless engine: every model is offered, research ones only with `allowResearch`.
        public var enablement: ModelEnablement?
        /// Which models stay in memory (ENG-3).
        public var residency = Residency.Policy()
        /// Upscale models whose package keeps 16 bits end to end (it declares `.rawRGBA16`, MLXToolKit contract 1.52.0).
        /// `ImageRuntime.start` reads it from the registered manifests; `output.bit_depth: 16` runs only on these.
        public var sixteenBitUpscalers: Set<String> = []
        /// Restore models whose package keeps 16 bits end to end (AB-T-0230), read the same way. `output.bit_depth: 16` on
        /// `image.restore` runs only where the request's own route is one of these (`OperationTable.restoreRoute`).
        public var sixteenBitRestorers: Set<String> = []
        /// Edit models that take a batch of tiles in one call (their `imageEdit` surface declares the `tiles` mode,
        /// mage-flow-swift ≥ 0.11.0). `ImageRuntime.start` reads it from the registered manifests; the creative upscale
        /// sends all its tiles in one call to these, so the conditioner loads once per job, not once per tile.
        public var tiledEditors: Set<String> = []
        /// Why the creative upscale isn't offered on this Mac (its models don't fit the engine's memory budget), or nil.
        /// `ImageRuntime.start` asks the runtime (`Creative.unavailableReason`); the extension is left out of
        /// `image.upscale` and its summary says why.
        public var creativeUnavailable: String?
        /// How long the prompt enhancer's backbone may take to answer, once loaded (`PromptEnhance`); past it the prompt goes
        /// as typed. Measured answers take 1.3–2.6 s on Qwen3.5-4B int4 (AB-R-0588).
        public var promptEnhanceTimeout: Duration = .seconds(60)
        public init(allowResearch: Bool = false, enablement: ModelEnablement? = nil, residency: Residency.Policy = .init(),
                    sixteenBitUpscalers: Set<String> = [], sixteenBitRestorers: Set<String> = [], tiledEditors: Set<String> = [],
                    creativeUnavailable: String? = nil, promptEnhanceTimeout: Duration = .seconds(60)) {
            self.allowResearch = allowResearch
            self.enablement = enablement
            self.residency = residency
            self.sixteenBitUpscalers = sixteenBitUpscalers
            self.sixteenBitRestorers = sixteenBitRestorers
            self.tiledEditors = tiledEditors
            self.creativeUnavailable = creativeUnavailable
            self.promptEnhanceTimeout = promptEnhanceTimeout
        }

        /// The models of `operation` that keep 16 bits (upscale and restore offer them; nothing else does).
        func sixteenBitModels(_ operation: String) -> Set<String> {
            switch operation {
            case "image.upscale": sixteenBitUpscalers
            case "image.restore": sixteenBitRestorers
            default: []
            }
        }
    }

    let directory: any ImageModelDirectory & ModelRouter
    let runner: any ModelRunner
    /// Runs the prompt enhancer's backbone (`PromptEnhance`). Without one, prompts go as typed.
    let textRunner: (any TextRunner)?
    public let options: Options
    public let residency: Residency

    public init(directory: any ImageModelDirectory & ModelRouter, runner: any ModelRunner, textRunner: (any TextRunner)? = nil,
                options: Options = Options()) {
        self.directory = directory
        self.runner = runner
        self.textRunner = textRunner
        self.options = options
        residency = Residency(runner: runner, router: directory, policy: options.residency)
    }

    // MARK: - Descriptors

    public func descriptors() async -> [Descriptor] {
        let models = await directory.models()
        return OperationTable.specs.compactMap { descriptor($0, models: models, offering: offered) }
    }

    /// The operations as they'd be with every usable model on: what each model does once its operator turns it on (the
    /// engine app's model cards). Never served.
    public func catalogDescriptors() async -> [Descriptor] {
        let models = await directory.models()
        return OperationTable.specs.compactMap { descriptor($0, models: models, offering: offerable) }
    }

    /// Every model the runtime registered, with its state: downloaded, resident, or why it can't run here.
    public func models() async -> [ModelInfo] { await directory.models() }

    /// Whether the operator must opt in to `info` and accept its terms: research and other restricted licences, and work
    /// in progress. Offered, such a model is `named_only`.
    public static func isOptIn(_ info: ModelInfo) -> Bool { !info.isDefaultRoutable }

    /// Downloads `id`'s weights and loads it now, instead of on the first job that needs it. Room is made as for a job
    /// (Residency), and the model is released again after its keep-warm time. `progress` reports downloads (0–1).
    public func prefetch(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let info = await directory.model(ModelID(id)), let capability = info.capabilities.first else {
            throw MESError(.modelUnavailable, "No model \(id) on this engine.")
        }
        let route = try await directory.route(capability, model: info.id)
        await residency.admit(route)
        do {
            try await runner.prepare(route) { p in
                if p.phase == "downloading", let fraction = p.fraction { progress(fraction) }
            }
        } catch {
            await residency.release(route)
            throw error
        }
        await residency.release(route)
    }

    /// Releases `id` from memory unless a job is using it. Returns whether it was released.
    @discardableResult
    public func unload(_ id: String) async -> Bool {
        guard let info = await directory.model(ModelID(id)), let capability = info.capabilities.first,
              let route = try? await directory.route(capability, model: info.id) else { return false }
        return await residency.unload(route)
    }

    /// Usable on this Mac at all: registered without a problem, and not quarantined.
    func offerable(_ info: ModelInfo) -> Bool {
        info.state.problem == nil && OperationTable.quarantined[info.id.rawValue] == nil
    }

    func offered(_ info: ModelInfo) -> Bool {
        guard offerable(info) else { return false }
        if let enablement = options.enablement {
            return enablement.isEnabled(info.id.rawValue, optIn: Self.isOptIn(info))
        }
        return info.isDefaultRoutable || options.allowResearch
    }

    /// The prompt enhancer can run: a text runner, and its backbone registered, usable here and on.
    func backboneOffered() async -> Bool {
        guard textRunner != nil, let info = await directory.model(ModelID(PromptEnhance.backboneID)) else { return false }
        return offered(info)
    }

    func enhancing(_ models: [ModelInfo], offering: (ModelInfo) -> Bool) -> Bool {
        textRunner != nil && models.contains { $0.id.rawValue == PromptEnhance.backboneID && offering($0) }
    }

    func descriptor(_ spec: OperationSpec, models: [ModelInfo]) -> Descriptor? {
        descriptor(spec, models: models, offering: offered)
    }

    func descriptor(_ spec: OperationSpec, models: [ModelInfo], offering: (ModelInfo) -> Bool) -> Descriptor? {
        let candidates = models.filter { spec.serves($0.id.rawValue, capabilities: $0.capabilities) && offering($0) }
        guard !candidates.isEmpty, let profile = ImageProfile.operations.operations[spec.operation] else { return nil }
        let defaultID = spec.defaults.first { id in candidates.contains { $0.id.rawValue == id && $0.isDefaultRoutable } }
            ?? candidates.first { $0.isDefaultRoutable }?.id.rawValue
        // Prompt enhancement (AB-D-0155): on generate and edit while its backbone is on.
        let enhancing = PromptEnhance.operations.contains(spec.operation) && enhancing(models, offering: offering)
        var offers = candidates.map { info in
            ModelOffer(id: info.id.rawValue, title: info.displayName, license: Self.license(info),
                       memoryClass: Self.memoryClass(info.footprintBytes), speedClass: Self.speedClass(spec, info),
                       qualityTiers: spec.tiers[info.id.rawValue] ?? spec.otherTiers,
                       isDefault: info.id.rawValue == defaultID ? true : nil,
                       namedOnly: info.isDefaultRoutable ? nil : true,
                       notes: Self.notes(info.id.rawValue, operation: spec.operation, enhancing: enhancing))
        }
        offers.sort { a, b in
            func rank(_ o: ModelOffer) -> Int { o.isDefault == true ? 0 : o.namedOnly == true ? 2 : 1 }
            return rank(a) < rank(b)
        }
        var tiers = Set(offers.filter { $0.namedOnly != true }.flatMap(\.qualityTiers))
        if tiers.isEmpty { tiers = Set(offers.flatMap(\.qualityTiers)) }

        // 16 bits (AB-A-0158, AB-T-0230): offered on upscale and restore when a model they offer keeps them.
        let deepSet = options.sixteenBitModels(spec.operation)
        let deepModels = offers.map(\.id).filter { deepSet.contains($0) }
        var properties: [String: MESValue] = [:]
        for (order, name) in spec.params.enumerated() {
            let narrowed = name == "output" && !deepModels.isEmpty ? OperationTable.deepOutput(models: deepModels) : spec.narrowed[name]
            guard case .object(var schema)? = narrowed ?? ImageProfile.vocabularySchema(name, operation: spec.operation)
            else { continue }
            schema["x-mes-ui"] = .object(Self.hints(name, order: order))
            properties[name] = .object(schema)
        }
        let maxInputs = candidates.map(\.envelope.maxInputs).max() ?? 1
        let inputs = profile.inputs.sorted { $0.key < $1.key }.compactMap { name, io -> InputSpec? in
            guard let required = spec.inputs[name] else { return nil }
            return InputSpec(name: name, kind: io.kind, required: required,
                             min: io.kind == .text || io.kind == .data ? nil : (required ? 1 : 0),
                             max: io.kind == .text || io.kind == .data ? nil : (name == "images" ? maxInputs : 1),
                             mediaTypes: io.kind == .image ? Self.imageTypes : io.kind == .mask ? ["image/png", "image/jpeg"] : nil)
        }
        let outputs = profile.outputs.sorted { $0.key < $1.key }.map { name, io in
            OutputSpec(name: name, kind: io.kind,
                       mediaTypes: io.kind == .data ? ["application/json"] : io.kind == .mask ? ["image/png"]
                           : deepModels.isEmpty ? ["image/png", "image/jpeg"] : ["image/png", "image/jpeg", "image/tiff"],
                       min: spec.operation == "image.matte" ? 0 : 1,
                       max: name == "images" ? 4 : 1)
        }
        let maxPixels = candidates.map(\.envelope.maxPixels).max() ?? 1 << 20
        var params: [String: MESValue] = ["type": "object", "additionalProperties": false, "properties": .object(properties)]
        if !deepModels.isEmpty {
            let routable = offers.filter { $0.namedOnly != true }
            let rules: [MESValue]
            if spec.operation == "image.restore" {
                // Per kind: the tiers whose own route (the model an 8-bit request of that kind runs) keeps 16 bits.
                let deepRoutes = Dictionary(uniqueKeysWithValues: OperationTable.restoreKinds.map { kind in
                    (kind, Set(QualityTier.allCases.filter { tier in
                        let candidates = routable.filter { $0.qualityTiers.contains(tier) }.map(\.id)
                        return OperationTable.restoreRoute(kind: kind, tier: tier, among: candidates).map(deepModels.contains) ?? false
                    }))
                })
                rules = OperationTable.restoreSixteenBitRules(deepRoutes: deepRoutes, params: spec.params)
            } else {
                let deepTiers = Set(routable.filter { deepModels.contains($0.id) }.flatMap(\.qualityTiers))
                let drawnDeepTiers = Set(QualityTier.allCases.filter { tier in
                    (OperationTable.drawnUpscale[tier] ?? []).contains { id in deepModels.contains(id) && routable.contains { $0.id == id } }
                })
                rules = OperationTable.sixteenBitRules(deepTiers: deepTiers, drawnDeepTiers: drawnDeepTiers, params: spec.params)
            }
            // No rules when every route keeps 16 bits: JSON Schema's `allOf` must be non-empty.
            if !rules.isEmpty { params["allOf"] = .array(rules) }
        }
        // The creative upscale: offered when its models are here and fit this Mac; otherwise the summary says why.
        let creative = spec.operation == "image.upscale" && creativeAvailable(models, offering: offering)
        let creativeOffered = creative && options.creativeUnavailable == nil
        let extensions = (creativeOffered ? [Creative.spec] : []) + (enhancing ? [PromptEnhance.spec] : [])
        var summary = Self.summaries[spec.operation]
        if creative, let why = options.creativeUnavailable { summary = [summary, why].compactMap { $0 }.joined(separator: " ") }
        return Descriptor(
            operation: spec.operation, profile: ImageProfile.id, profileVersion: ImageProfile.version,
            title: Self.titles[spec.operation] ?? spec.operation, summary: summary,
            inputs: inputs,
            params: .object(params),
            outputs: outputs,
            limits: .init(maxMegapixels: Double(maxPixels) / 1_000_000, maxInputs: maxInputs, maxCount: spec.operation == "image.generate" ? 4 : 1),
            qualityTiers: OperationTable.all.filter(tiers.contains), models: offers,
            extensions: extensions.isEmpty ? nil : extensions,
            remote: .init(possible: false))
    }

    /// The creative upscale's models are here: its editor (Mage-Flow-Edit-Turbo, for image edits) and its Realistic
    /// (VOSR2).
    func creativeAvailable(_ models: [ModelInfo], offering: (ModelInfo) -> Bool) -> Bool {
        models.contains { $0.id.rawValue == Creative.editor && $0.capabilities.contains(.imageEdit) && offering($0) }
            && models.contains { $0.id.rawValue == Creative.realistic && offering($0) }
    }

    static let imageTypes = ["image/png", "image/jpeg", "image/heic", "image/webp", "image/tiff"]

    /// Models the engine won't offer, and why (`OperationTable.quarantined`).
    public static var quarantined: [String: String] { OperationTable.quarantined }

    /// A model's licence in MES terms (Base §10.2). Commercial use follows the engine's licence classification:
    /// only models whose weights and code are all permissive allow it. Others ask for acceptance (ENG-14).
    public static func license(_ info: ModelInfo) -> MESCore.License {
        let stamp = info.license
        let spdx = stamp.weightLicenses.isEmpty ? "NOASSERTION" : stamp.weightLicenses.joined(separator: " AND ")
        let permissive = stamp.licenseClass == .permissive
        return MESCore.License(spdx: spdx, commercialUse: permissive ? .yes : .no,
                               termsURL: info.sourceRepo.isEmpty ? nil : "https://huggingface.co/\(info.sourceRepo)",
                               notice: notice(info, spdx: spdx), acceptedRequired: permissive ? nil : true)
    }

    /// An offer's `notes` (Base §6 rule 5): the model's usage guidance, and on `image.generate` how the engine treats its
    /// prompts while the prompt enhancer is on.
    static func notes(_ id: String, operation: String, enhancing: Bool) -> String? {
        let prompts = enhancing && operation == "image.generate" ? PromptEnhance.note(forModel: id) : nil
        let parts = [notes[id], prompts].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Per-model usage guidance for the offer's `notes` (Base §6 rule 5): how to prompt the model, in a sentence or two.
    /// Licence terms stay in `license.notice`; limits stay in the descriptor.
    static let notes: [String: String] = [
        "flux-3-klein": "Short requests are fine: the engine runs BFL's prompt upsampler, which expands each one into the "
            + "full scene caption the model needs (about 10 s). Put text to render in quotes, e.g. a sign reading \"OPEN\"; "
            + "a layout of bounding boxes may go in the prompt as JSON.",
    ]

    /// The FLUX Kommunity License's package-local identifier (flux3-klein-swift `SPDXLicense.fluxKommunity`).
    static let fluxKommunity = "LicenseRef-FLUX-Kommunity-1.0"

    /// What a person should know before using a model's results, in plain words. (The runtime's own advisories are
    /// log lines for the operator, not notices.)
    static func notice(_ info: ModelInfo, spdx: String) -> String? {
        var parts: [String] = []
        switch info.license.licenseClass {
        case .permissive: break
        case .evalAcknowledged: parts.append("Evaluation licence (\(spdx)): for evaluation only, not for commercial use.")
        default:
            if info.license.weightLicenses.contains(fluxKommunity) {
                // FLUX Kommunity (FLUX 3 Klein, AB-D-0151): not a research-only licence, but the engine can't tell
                // whether its operator qualifies for the commercial-outputs exception, so the offer stays
                // commercial_use: false and the notice names the exception.
                parts.append("FLUX Kommunity licence: non-commercial use; commercial use of outputs only for businesses "
                    + "under US$5M revenue that filter content and disclose AI generation; never use outputs to train "
                    + "another image model. Read the terms before you use or share results.")
            } else {
                parts.append("Research licence (\(spdx)): not for commercial use. Read the terms before you use or share results.")
            }
        }
        if info.maturity == .wip { parts.append("Work in progress: results may change between versions.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public static func memoryClass(_ bytes: UInt64?) -> ModelOffer.MemoryClass? {
        guard let bytes else { return nil }
        let gb = Double(bytes) / 1_073_741_824
        return gb < 4 ? .small : gb < 12 ? .medium : gb < 24 ? .large : .xlarge
    }

    static func speedClass(_ spec: OperationSpec, _ info: ModelInfo) -> ModelOffer.SpeedClass? {
        guard let tiers = spec.tiers[info.id.rawValue] else { return nil }
        return tiers.contains(.draft) ? .fast : tiers == [.best] ? .slow : .standard
    }

    static func hints(_ name: String, order: Int) -> [String: MESValue] {
        let widgets: [String: String] = ["negative_prompt": "textarea", "seed": "seed", "quality": "picker", "size": "size",
                                         "aspect": "aspect", "megapixels": "slider", "strength": "slider", "count": "stepper",
                                         "scale": "picker", "content": "picker", "kind": "picker", "outputs": "picker",
                                         "language": "text"]
        var hints: [String: MESValue] = ["label": .string(name.replacingOccurrences(of: "_", with: " ").capitalized),
                                         "order": .number(Double(order))]
        if let w = widgets[name] { hints["widget"] = .string(w) }
        if ["negative_prompt", "seed", "megapixels", "output"].contains(name) { hints["advanced"] = true }
        return hints
    }

    static let titles = [
        "image.generate": "Generate", "image.edit": "Edit", "image.fill": "Generative fill", "image.erase": "Erase",
        "image.extend": "Extend canvas", "image.upscale": "Upscale", "image.restore": "Restore", "image.relight": "Relight",
        "image.colorize": "Colorize", "image.matte": "Select subject", "image.segment": "Select by points",
        "image.describe": "Describe", "image.score": "Quality score",
    ]
    static let summaries = [
        "image.generate": "Text to image.", "image.edit": "Changes an image as instructed, keeping what the instruction doesn't mention.",
        "image.fill": "Paints the masked area from the prompt, or fills it plausibly without one; everything outside the mask stays exactly as it is.",
        "image.erase": "Removes what the mask covers.", "image.extend": "Extends the canvas and continues the picture into the new area; the original stays exactly as it is.",
        "image.upscale": "Exactly ×2 or ×4.", "image.restore": "Denoise, deblur, faces, or scratches, chosen by kind.",
        "image.relight": "Corrects under- and over-exposure.", "image.colorize": "Colours black-and-white photos.",
        "image.matte": "The main subject as a mask, and cut out.", "image.segment": "The object at the given points, as a mask.",
        "image.describe": "A caption, alt text and tags.", "image.score": "No-reference quality, 0 to 1.",
    ]

    // MARK: - Validation

    public func validate(_ request: JobRequest, descriptor: Descriptor) throws {
        try ImageProfileRules.validate(request, descriptor: descriptor)
        try validateBitDepth(request, descriptor: descriptor)
        // The creative upscale runs at 8 bits: Mage and VOSR2 are 8-bit models (AB-T-0230).
        if request.extensions?[Creative.name] != nil, request.params?["output"]?["bit_depth"]?.intValue == 16 {
            throw MESError(.unsupportedParameter, "The creative upscale runs at 8 bits.", param: "output")
        }
        if let size = request.params?["size"], let w = size["width"]?.intValue, let h = size["height"]?.intValue,
           let max = descriptor.limits?.maxMegapixels, Double(w * h) > max * 1_000_000 {
            throw MESError(.outOfLimits, "\(w)×\(h) is over \(descriptor.operation)'s \(max) megapixels.", param: "size")
        }
    }

    /// `output.bit_depth: 16` (Image §1.2, AB-A-0158): honoured only as PNG or TIFF, and only on a model that keeps 16 bits
    /// — the named one, or else one the requested tier can default to (for restore, the request's own route: its kind's
    /// model at that tier, never a switch to another one; scratches never). Anything else is 422 `unsupported_parameter`,
    /// at submit, so a client (Pixel Agency Desktop) can fall back to its own 16-bit restore around an 8-bit step.
    func validateBitDepth(_ request: JobRequest, descriptor: Descriptor) throws {
        guard let output = request.params?["output"], output["bit_depth"]?.intValue == 16 else { return }
        let deepSet = options.sixteenBitModels(descriptor.operation)
        let deep = descriptor.models.map(\.id).filter { deepSet.contains($0) }
        guard !deep.isEmpty else {
            throw MESError(.unsupportedParameter, "\(descriptor.operation) runs at 8 bits on this engine.", param: "output")
        }
        let type = output["media_type"]?.stringValue ?? "image/png"
        guard type == "image/png" || type == "image/tiff" else {
            throw MESError(.unsupportedParameter, "16 bits needs image/png or image/tiff, not \(type).", param: "output")
        }
        let runsOn = "16 bits runs on \(deep.joined(separator: ", "))."
        let kind = request.params?["kind"]?.stringValue ?? "general"
        if descriptor.operation == "image.restore", kind == "scratches" {
            throw MESError(.unsupportedParameter, "Scratch repair (defect detection, then inpainting) runs at 8 bits.", param: "output")
        }
        if let named = request.model {
            guard deep.contains(named) else {
                throw MESError(.unsupportedParameter, "\(named) runs at 8 bits; \(runsOn)", param: "output")
            }
            return
        }
        let tier = request.params?["quality"]?.stringValue.flatMap(QualityTier.init(rawValue:)) ?? .standard
        let policy = request.policy ?? Policy()
        var candidates = descriptor.models.filter { $0.qualityTiers.contains(tier) && $0.namedOnly != true && policy.allows($0) }
            .map(\.id)
        if descriptor.operation == "image.restore" {
            guard let route = OperationTable.restoreRoute(kind: kind, tier: tier, among: candidates), deep.contains(route) else {
                throw MESError(.unsupportedParameter, "No \(tier.rawValue)-quality \(kind) restorer keeps 16 bits; \(runsOn)",
                               param: "output")
            }
            return
        }
        // Drawn content keeps its route (AB-D-0124): 16 bits only where that route has a 16-bit model, never by
        // switching drawn content to a photo model.
        let drawn = request.params?["content"]?.stringValue == "drawn"
        if drawn { candidates = (OperationTable.drawnUpscale[tier] ?? []).filter(candidates.contains) }
        guard candidates.contains(where: deep.contains) else {
            throw MESError(.unsupportedParameter, "No \(tier.rawValue)-quality \(drawn ? "drawn-content " : "")upscaler keeps 16 bits; \(runsOn)",
                           param: "output")
        }
    }

    /// The default when a request names no model (Base §6 rule 2): each tier's preferred model (`OperationSpec.
    /// preferred`), refined by the request's params: restore by `kind`, fill or extend with a prompt to an edit model,
    /// upscale of drawn content by `OperationTable.drawnUpscale`, erase at best to the named remover. Only `candidates` (the tier's allowed, not named-only offers) can be returned.
    public func defaultModel(for request: JobRequest, descriptor: Descriptor, kitChoice: ModelOffer,
                             candidates: [ModelOffer]) -> ModelOffer? {
        guard let spec = OperationTable.specs.first(where: { $0.operation == request.operation }) else { return nil }
        let tier = request.params?["quality"]?.stringValue.flatMap(QualityTier.init(rawValue:)) ?? .standard
        var preferred: [String] = []
        switch request.operation {
        case "image.restore":
            // At 16 bits too: `validateBitDepth` admitted the request only where this route keeps them.
            if let kind = request.params?["kind"]?.stringValue { preferred = OperationTable.restoreModels(kind: kind, tier: tier) }
        case "image.fill", "image.extend":
            if case .text(let prompt)? = request.inputs?["prompt"], !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
                preferred = OperationTable.generativeFill[tier] ?? []
            }
        case "image.erase":
            preferred = OperationTable.eraseByTier[tier] ?? []
        case "image.upscale":
            if request.params?["content"]?.stringValue == "drawn" { preferred = OperationTable.drawnUpscale[tier] ?? [] }
            // A 16-bit request runs on a model that keeps 16 bits (`validateBitDepth` made sure the tier has one).
            if request.params?["output"]?["bit_depth"]?.intValue == 16 {
                let pool = request.params?["content"]?.stringValue == "drawn" ? preferred
                    : preferred + spec.preferred(at: tier) + candidates.map(\.id)
                preferred = pool.filter { options.sixteenBitUpscalers.contains($0) }
            }
        default:
            break
        }
        return (preferred + spec.preferred(at: tier)).lazy.compactMap { id in candidates.first { $0.id == id } }.first
    }

    public func residentModels() async -> [String] {
        var ids: [String] = []
        for package in await runner.residentPackages() {
            if let id = await directory.modelID(forPackage: package) { ids.append(id.rawValue) }
        }
        return ids.sorted()
    }

    // MARK: - Running

    public func run(_ context: RunContext) async throws -> MESEngineCore.RunOutput {
        do {
            guard let spec = OperationTable.specs.first(where: { $0.operation == context.operation }) else {
                throw MESError(.unknownOperation, "No plan for \(context.operation).")
            }
            var job = RunPlan(context: context, spec: spec, normalizer: self)
            do {
                let output = try await job.run()
                await job.releaseModels()
                return output
            } catch {
                await job.releaseModels()
                throw error
            }
        } catch {
            let failure = Self.mesError(error)
            // The job record carries the error; the operator's log names it too (a download failure names its repo).
            if let failure = failure as? MESError {
                print("job \(context.jobID) (\(context.operation), \(context.model.id)) failed: \(failure.code): \(failure.message)")
            }
            throw failure
        }
    }

    /// Runtime failures as MES errors (Base §12).
    static func mesError(_ error: Error) -> Error {
        switch error {
        case let e as MESError: return e
        case is CancellationError: return error
        case let e as APIError:
            switch e.status {
            case 409: return MESError(.policyUnmet, e.message)
            case 503: return MESError(.noCapacity, e.message)
            case 400, 422: return MESError(.outOfLimits, e.message, param: e.param)
            default: return MESError(.modelUnavailable, e.message)
            }
        case let e as JobError: return MESError(.engineError, "\(e.message) (\(e.code))")
        case let e as NormalizerError:
            if case .input(let m) = e { return MESError(.inputInvalid, m) }
            return MESError(.engineError, e.description)
        default: return MESError(.engineError, "\(error)")
        }
    }
}
