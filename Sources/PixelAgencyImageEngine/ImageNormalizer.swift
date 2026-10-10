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
        /// Offer research and work-in-progress models (named-only). Off by default (Engines-PRD OQ-4).
        public var allowResearch = false
        /// Which models stay in memory (ENG-3).
        public var residency = Residency.Policy()
        public init(allowResearch: Bool = false, residency: Residency.Policy = .init()) {
            self.allowResearch = allowResearch
            self.residency = residency
        }
    }

    let directory: any ImageModelDirectory & ModelRouter
    let runner: any ModelRunner
    let options: Options
    public let residency: Residency

    public init(directory: any ImageModelDirectory & ModelRouter, runner: any ModelRunner, options: Options = Options()) {
        self.directory = directory
        self.runner = runner
        self.options = options
        residency = Residency(runner: runner, router: directory, policy: options.residency)
    }

    // MARK: - Descriptors

    public func descriptors() async -> [Descriptor] {
        let models = await directory.models()
        return OperationTable.specs.compactMap { descriptor($0, models: models) }
    }

    func offered(_ info: ModelInfo) -> Bool {
        info.state.problem == nil && OperationTable.quarantined[info.id.rawValue] == nil
            && (info.isDefaultRoutable || options.allowResearch)
    }

    func descriptor(_ spec: OperationSpec, models: [ModelInfo]) -> Descriptor? {
        let candidates = models.filter { !Set($0.capabilities).isDisjoint(with: spec.capabilities) && offered($0) }
        guard !candidates.isEmpty, let profile = ImageProfile.operations.operations[spec.operation] else { return nil }
        let defaultID = spec.defaults.first { id in candidates.contains { $0.id.rawValue == id && $0.isDefaultRoutable } }
            ?? candidates.first { $0.isDefaultRoutable }?.id.rawValue
        var offers = candidates.map { info in
            ModelOffer(id: info.id.rawValue, title: info.displayName, license: Self.license(info),
                       memoryClass: Self.memoryClass(info.footprintBytes), speedClass: Self.speedClass(spec, info),
                       qualityTiers: spec.tiers[info.id.rawValue] ?? spec.otherTiers,
                       isDefault: info.id.rawValue == defaultID ? true : nil,
                       namedOnly: info.isDefaultRoutable ? nil : true)
        }
        offers.sort { a, b in
            func rank(_ o: ModelOffer) -> Int { o.isDefault == true ? 0 : o.namedOnly == true ? 2 : 1 }
            return rank(a) < rank(b)
        }
        var tiers = Set(offers.filter { $0.namedOnly != true }.flatMap(\.qualityTiers))
        if tiers.isEmpty { tiers = Set(offers.flatMap(\.qualityTiers)) }

        var properties: [String: MESValue] = [:]
        for (order, name) in spec.params.enumerated() {
            guard case .object(var schema)? = spec.narrowed[name] ?? ImageProfile.vocabularySchema(name, operation: spec.operation)
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
                       mediaTypes: io.kind == .data ? ["application/json"] : io.kind == .mask ? ["image/png"] : ["image/png", "image/jpeg"],
                       min: spec.operation == "image.matte" ? 0 : 1,
                       max: name == "images" ? 4 : 1)
        }
        let maxPixels = candidates.map(\.envelope.maxPixels).max() ?? 1 << 20
        return Descriptor(
            operation: spec.operation, profile: ImageProfile.id, profileVersion: ImageProfile.version,
            title: Self.titles[spec.operation] ?? spec.operation, summary: Self.summaries[spec.operation],
            inputs: inputs,
            params: .object(["type": "object", "additionalProperties": false, "properties": .object(properties)]),
            outputs: outputs,
            limits: .init(maxMegapixels: Double(maxPixels) / 1_000_000, maxInputs: maxInputs, maxCount: spec.operation == "image.generate" ? 4 : 1),
            qualityTiers: OperationTable.all.filter(tiers.contains), models: offers, remote: .init(possible: false))
    }

    static let imageTypes = ["image/png", "image/jpeg", "image/heic", "image/webp", "image/tiff"]

    /// Models the engine won't offer, and why (`OperationTable.quarantined`).
    public static var quarantined: [String: String] { OperationTable.quarantined }

    /// A model's licence in MES terms (Base §10.2). Commercial use follows the engine's licence classification:
    /// only models whose weights and code are all permissive allow it. Others ask for acceptance (ENG-14).
    static func license(_ info: ModelInfo) -> MESCore.License {
        let stamp = info.license
        let spdx = stamp.weightLicenses.isEmpty ? "NOASSERTION" : stamp.weightLicenses.joined(separator: " AND ")
        let permissive = stamp.licenseClass == .permissive
        return MESCore.License(spdx: spdx, commercialUse: permissive ? .yes : .no,
                               termsURL: info.sourceRepo.isEmpty ? nil : "https://huggingface.co/\(info.sourceRepo)",
                               notice: notice(info, spdx: spdx), acceptedRequired: permissive ? nil : true)
    }

    /// What a person should know before using a model's results, in plain words. (The runtime's own advisories are
    /// log lines for the operator, not notices.)
    static func notice(_ info: ModelInfo, spdx: String) -> String? {
        var parts: [String] = []
        switch info.license.licenseClass {
        case .permissive: break
        case .evalAcknowledged: parts.append("Evaluation licence (\(spdx)): for evaluation only, not for commercial use.")
        default: parts.append("Research licence (\(spdx)): not for commercial use. Read the terms before you use or share results.")
        }
        if info.maturity == .wip { parts.append("Work in progress: results may change between versions.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func memoryClass(_ bytes: UInt64?) -> ModelOffer.MemoryClass? {
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
        if let size = request.params?["size"], let w = size["width"]?.intValue, let h = size["height"]?.intValue,
           let max = descriptor.limits?.maxMegapixels, Double(w * h) > max * 1_000_000 {
            throw MESError(.outOfLimits, "\(w)×\(h) is over \(descriptor.operation)'s \(max) megapixels.", param: "size")
        }
    }

    /// The default when a request names no model (Base §6 rule 2): each tier's preferred model (`OperationSpec.
    /// preferred`), refined by the request's params: restore by `kind`, fill or extend with a prompt to an edit model,
    /// upscale of drawn content to NERVE. Only `candidates` (the tier's allowed, not named-only offers) can be returned.
    public func defaultModel(for request: JobRequest, descriptor: Descriptor, kitChoice: ModelOffer,
                             candidates: [ModelOffer]) -> ModelOffer? {
        guard let spec = OperationTable.specs.first(where: { $0.operation == request.operation }) else { return nil }
        let tier = request.params?["quality"]?.stringValue.flatMap(QualityTier.init(rawValue:)) ?? .standard
        var preferred: [String] = []
        switch request.operation {
        case "image.restore":
            if let kind = request.params?["kind"]?.stringValue { preferred = OperationTable.restoreModels(kind: kind, tier: tier) }
        case "image.fill", "image.extend":
            if case .text(let prompt)? = request.inputs?["prompt"], !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
                preferred = OperationTable.generativeFill[tier] ?? []
            }
        case "image.upscale":
            if request.params?["content"]?.stringValue == "drawn" { preferred = OperationTable.drawnUpscale }
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
            throw Self.mesError(error)
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
