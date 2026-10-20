import Foundation
import ImageServerAPI
import ImageServerModels
import MESCore
import MESEngineCore
import MLXToolKit

/// Adapters (LoRA) through MES (AB-D-0155, L4; docs/PROMPTS-AND-ADAPTERS.md §2.2): the runtime's adapter catalog
/// (mlx-image-runtime ≥ 0.15.0, `ModelInfo.adapters`), offered to clients as the extension `x-pixelagency.adapters` on
/// `image.generate` and `image.edit`.
///
/// - **The extension** is an array of `{id, strength?}`, in the order they apply. Its schema lists the ids on offer and
///   each one's strength range, and carries every adapter's metadata for clients (`x-pixelagency-adapters`: kind, slots,
///   the models that take it, trigger, prompt template, licence, status, clearance, bytes). Each model's offer names its
///   adapters in its notes. The shape follows MES 0.4's first-class adapters (Base §6.3, AB-A-0194), so moving to them is
///   a rename.
/// - **An adapter implies its model.** With no model named, the engine picks an offer that takes every requested adapter
///   (`ImageNormalizer.defaultModel`). Refused at submit, as MES 0.4 does:
///   - an id listed twice: 400 `invalid_request`;
///   - an adapter the named model doesn't take, or a set no offer the engine may choose takes: 422 `unsupported_parameter`;
///   - more than the model stacks: 422 `out_of_limits` (a strength outside its range fails the schema, also `out_of_limits`);
///   - under `policy.license: commercial-use`, an adapter whose terms don't allow commercial use: 422 `policy_unmet` (§10.3).
/// - **Reference-conditioned (IC) adapters** take their slots, in order, from the edit's `images`; images left over stay
///   the edit's own.
/// - **Prompts.** An adapter's prompt template wraps the prompt (or is the prompt when there's none), and its trigger is
///   added when the prompt lacks it, after prompt enhancement, with a `prompt_rewritten` warning.
/// - **Honest results.** `effective.model_params.adapters` lists each adapter applied: id, title, strength, the pinned
///   revision and sha256 of its file, and its licence (MES 0.4's `provenance.adapters`).
/// - **The enabled set.** Each adapter is an `adapter:<id>` entry in the operator's enabled set. Adapters whose terms the
///   operator should read first are opt-in (`isOptIn`): gated ones, ones whose licence doesn't allow commercial use or
///   doesn't say, and `candidate` ones not yet judged on this stack. The headless engine offers those only with
///   `--allow-research`.
public enum Adapters {
    public static let name = "x-pixelagency.adapters"
    /// The annotation on the extension's schema with every adapter on offer, for clients and for `validate`.
    static let offersKey = "x-pixelagency-adapters"
    /// The annotation with how many adapters each model stacks in one request.
    static let maxKey = "x-pixelagency-max-adapters"
    /// The operations that take adapters, with the capability their adapters must serve.
    public static let operations: [String: Capability] = ["image.generate": .textToImage, "image.edit": .imageEdit]
    /// Registry statuses never offered. Format 3 keeps withdrawn entries out of the catalog altogether; these are the
    /// statuses older registries used for the same thing.
    static let refusedStatuses: Set<String> = ["withdrawn", "broken"]

    /// The adapter's key in the operator's enabled set (`ModelEnablement`).
    public static func key(_ id: String) -> String { "adapter:" + id }

    /// The adapter id behind an enabled-set key, or nil for a model's key.
    public static func adapterID(fromKey key: String) -> String? {
        key.hasPrefix("adapter:") ? String(key.dropFirst("adapter:".count)) : nil
    }

    /// Whether the operator must switch `adapter` on and accept its terms first: its terms are gated, they don't allow
    /// commercial use or don't say, or it's a `candidate` not yet judged on this stack.
    public static func isOptIn(_ adapter: AdapterInfo) -> Bool {
        adapter.licenseGated || !["allowed", "conditional"].contains(adapter.commercialUse) || adapter.status == "candidate"
    }

    /// Never offered, whatever the enabled set says.
    public static func isRefused(_ adapter: AdapterInfo) -> Bool { refusedStatuses.contains(adapter.status) }

    /// The adapter's own licence in MES terms (Base §10.2), which applies on top of its model's. `conditional` (e.g.
    /// OpenRAIL's use restrictions) allows commercial use, with a notice to read the conditions.
    public static func license(_ adapter: AdapterInfo) -> MESCore.License {
        let use: CommercialUse
        switch adapter.commercialUse {
        case "allowed", "conditional": use = .yes
        case "prohibited": use = .no
        default: use = .unknown
        }
        var notes: [String] = []
        if adapter.commercialUse == "conditional" {
            notes.append("Commercial use is allowed on the conditions of its licence (\(adapter.license)): read them first.")
        } else if use == .unknown {
            notes.append("Its licence doesn't say whether commercial use is allowed.")
        }
        if let notice = adapter.notice { notes.append(notice) }
        return MESCore.License(spdx: adapter.license, commercialUse: use, termsURL: adapter.licenseURL,
                               notice: notes.isEmpty ? nil : notes.joined(separator: " "),
                               acceptedRequired: isOptIn(adapter) ? true : nil)
    }

    // MARK: - The request

    /// One adapter a request asks for.
    struct Choice: Equatable, Sendable {
        var id: String
        var strength: Double?
    }

    /// The extension's adapters, in order; empty when the request doesn't carry it.
    static func choices(_ extensions: [String: MESValue]?) -> [Choice] {
        (extensions?[name]?.arrayValue ?? []).compactMap { item in
            item["id"]?.stringValue.map { Choice(id: $0, strength: item["strength"]?.numberValue) }
        }
    }

    // MARK: - The offer

    /// An adapter on offer for one operation.
    struct Offer: Equatable, Sendable {
        var info: AdapterInfo
        /// The operation's offered models that take it, in the descriptor's order.
        var models: [String]
        /// The strengths every one of those models applies faithfully, within the adapter's own range.
        var strengthMin: Double
        var strengthMax: Double

        var license: MESCore.License { Adapters.license(info) }

        /// Its entry in `x-pixelagency-adapters`.
        var value: MESValue {
            var object: [String: MESValue] = [
                "id": .string(info.id), "title": .string(info.title), "kind": .string(info.kind),
                "models": .array(models.map { .string($0) }),
                "strength": ["min": .number(strengthMin), "max": .number(strengthMax), "default": .number(info.defaultStrength)],
                "license": (try? MESValue(encoding: license)) ?? .null,
                "status": .string(info.status),
            ]
            if !info.conditioning.isEmpty {
                object["slots"] = .array(info.conditioning.map { slot in
                    var s: [String: MESValue] = ["role": .string(slot.role), "kind": .string(slot.media), "required": .bool(slot.required)]
                    if let note = slot.note { s["notes"] = .string(note) }
                    return .object(s)
                })
            }
            if let notes = Adapters.notes(info) { object["notes"] = .string(notes) }
            if let trigger = info.trigger { object["trigger"] = .string(trigger) }
            if let template = info.promptTemplate { object["prompt_template"] = .string(template) }
            if !info.clearance.isEmpty { object["clearance"] = .object(info.clearance.mapValues { .string($0) }) }
            if let bytes = info.bytes { object["bytes"] = .number(Double(bytes)) }
            return .object(object)
        }

        /// Read back from `x-pixelagency-adapters`, as much as `validate` needs.
        init?(_ value: MESValue) {
            guard let id = value["id"]?.stringValue else { return nil }
            let slots = (value["slots"]?.arrayValue ?? []).map { slot in
                AdapterInfo.AdapterSlot(role: slot["role"]?.stringValue ?? "", media: slot["kind"]?.stringValue ?? "image",
                                        required: slot["required"]?.boolValue ?? true, maxCount: 1)
            }
            let use: String
            switch value["license"]?["commercial_use"] {
            case .bool(true)?: use = "allowed"
            case .bool(false)?: use = "prohibited"
            default: use = "unknown"
            }
            info = AdapterInfo(id: id, title: value["title"]?.stringValue ?? id, kind: value["kind"]?.stringValue ?? "plain",
                               baseModels: [], capabilities: [], license: value["license"]?["spdx"]?.stringValue ?? "NOASSERTION",
                               commercialUse: use, defaultStrength: value["strength"]?["default"]?.numberValue ?? 1,
                               conditioning: slots, status: value["status"]?.stringValue ?? "")
            models = (value["models"]?.arrayValue ?? []).compactMap(\.stringValue)
            strengthMin = value["strength"]?["min"]?.numberValue ?? 0
            strengthMax = value["strength"]?["max"]?.numberValue ?? 2
        }

        init(info: AdapterInfo, models: [String], strengthMin: Double, strengthMax: Double) {
            self.info = info; self.models = models; self.strengthMin = strengthMin; self.strengthMax = strengthMax
        }
    }

    /// How to use an adapter, in a sentence or two (MES 0.4's adapter `notes`).
    public static func notes(_ info: AdapterInfo) -> String? {
        var parts: [String] = []
        if info.kind == "ic", !info.conditioning.isEmpty {
            parts.append("Takes its reference images from the edit's images, in this order: "
                + info.conditioning.map { $0.role + ($0.required ? "" : " (optional)") }.joined(separator: ", ") + ".")
        }
        if let template = info.promptTemplate {
            parts.append(template.contains("{prompt}")
                ? "Your prompt is placed in its template: \(template)"
                : "Without a prompt it runs \"\(template)\".")
        }
        if let trigger = info.trigger, trigger != info.promptTemplate {
            parts.append("The engine adds its trigger, \"\(trigger)\", when the prompt lacks it.")
        }
        if info.status == "candidate" { parts.append("A candidate: checked, but not yet judged on this engine.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The extension for one operation's offers. `maxAdapters` is how many each model stacks.
    static func spec(_ offers: [Offer], maxAdapters: [String: Int]) -> ExtensionSpec {
        let most = maxAdapters.values.max() ?? 1
        let low = offers.map(\.strengthMin).min() ?? 0, high = offers.map(\.strengthMax).max() ?? 2
        // Each adapter's own range, where it's narrower than the union.
        let ranges: [MESValue] = offers.filter { $0.strengthMin > low || $0.strengthMax < high }.map { offer in
            ["if": ["properties": ["id": ["const": .string(offer.info.id)]], "required": ["id"]],
             "then": ["properties": ["strength": ["minimum": .number(offer.strengthMin), "maximum": .number(offer.strengthMax)]]]]
        }
        var item: [String: MESValue] = [
            "type": "object", "additionalProperties": false, "required": ["id"],
            "properties": [
                "id": ["enum": .array(offers.map { .string($0.info.id) }),
                       "description": "An adapter on offer; x-pixelagency-adapters says which models take it and how to use it."],
                "strength": ["type": "number", "minimum": .number(low), "maximum": .number(high),
                             "description": "How strongly it applies. Its default strength when left out."],
            ],
        ]
        if !ranges.isEmpty { item["allOf"] = .array(ranges) }
        return ExtensionSpec(name: name, title: "Adapters", schema: [
            "type": "array", "maxItems": .number(Double(most)), "items": .object(item),
            "description": .string("Adapters (LoRA) to apply, in order: [{id, strength?}]. An adapter implies its model: with "
                + "no model named the engine picks one that takes every adapter. A reference-conditioned (ic) adapter takes its "
                + "images from the edit's images, in its slots' order. What ran is reported in effective.model_params.adapters."),
            "x-mes-ui": ["label": "Adapters", "order": 3, "advanced": true,
                         "help": "Small add-on weights that give the model a style or a skill."],
            offersKey: .array(offers.map(\.value)),
            maxKey: .object(maxAdapters.mapValues { .number(Double($0)) }),
        ])
    }

    /// The models of `descriptor`'s operation that take adapter `id`, or nil when it isn't offered there.
    public static func models(taking id: String, in descriptor: Descriptor) -> [String]? {
        offers(in: descriptor)?.offers[id]?.models
    }

    /// The offers and the models' limits, read back from an operation's descriptor.
    static func offers(in descriptor: Descriptor) -> (offers: [String: Offer], maxAdapters: [String: Int])? {
        guard let spec = descriptor.extensions?.first(where: { $0.name == name }) else { return nil }
        let offers = (spec.schema[offersKey]?.arrayValue ?? []).compactMap(Offer.init)
        let max = (spec.schema[maxKey]?.objectValue ?? [:]).compactMapValues(\.intValue)
        return (Dictionary(offers.map { ($0.info.id, $0) }, uniquingKeysWith: { a, _ in a }), max)
    }

    // MARK: - Submit

    /// The extension's rules at submit (the schema has checked ids and strengths): duplicates, licence policy, the
    /// models that take the set, how many they stack, and an IC adapter's images.
    static func validate(_ request: JobRequest, descriptor: Descriptor) throws {
        let choices = choices(request.extensions)
        guard !choices.isEmpty else { return }
        let param = name
        var seen = Set<String>()
        for choice in choices where !seen.insert(choice.id).inserted {
            throw MESError(.invalidRequest, "Adapter \(choice.id) is listed twice.", param: param)
        }
        guard let declared = Self.offers(in: descriptor) else {
            throw MESError(.unsupportedParameter, "\(descriptor.operation) takes no adapters.", param: param)
        }
        let (offers, maxAdapters) = declared
        var chosen: [Offer] = []
        for choice in choices {
            guard let offer = offers[choice.id], !isRefused(offer.info) else {
                throw MESError(.unsupportedParameter, "\(descriptor.operation) offers no adapter \(choice.id).", param: param)
            }
            chosen.append(offer)
        }
        let policy = request.policy ?? Policy()
        if policy.effectiveLicense == .commercialUse, let barred = chosen.first(where: { $0.license.commercialUse != .yes }) {
            throw MESError(.policyUnmet, "Adapter \(barred.info.id) doesn't satisfy the request's policy: its licence "
                           + "(\(barred.info.license)) doesn't allow commercial use.",
                           reason: "\(barred.info.id): \(barred.info.license)", param: param)
        }

        // The models that take every adapter named, and stack that many.
        let taking = descriptor.models.filter { model in chosen.allSatisfy { $0.models.contains(model.id) } }
        let fits = { (model: ModelOffer) in choices.count <= (maxAdapters[model.id] ?? 1) }
        let names = { (models: [ModelOffer]) in models.map(\.id).joined(separator: ", ") }
        if let named = request.model {
            guard let model = taking.first(where: { $0.id == named }) else {
                let other = chosen.first { !$0.models.contains(named) } ?? chosen[0]
                throw MESError(.unsupportedParameter, "\(named) doesn't take adapter \(other.info.id); "
                               + "\(other.models.joined(separator: ", ")) \(other.models.count == 1 ? "does" : "do").", param: param)
            }
            guard fits(model) else {
                throw MESError(.outOfLimits, "\(named) applies at most \(maxAdapters[named] ?? 1) adapter(s) at once.", param: param)
            }
        } else {
            guard !taking.isEmpty else {
                throw MESError(.unsupportedParameter, "No model of \(descriptor.operation) takes every adapter named "
                               + "(\(choices.map(\.id).joined(separator: ", "))).", param: param)
            }
            // What the engine may choose by itself (Base §6 rule 2): the tier's offers, not named-only, within policy.
            let tier = Self.tier(request, descriptor: descriptor)
            let choosable = taking.filter { $0.qualityTiers.contains(tier) && $0.namedOnly != true && policy.allows($0) }
            guard !choosable.isEmpty else {
                throw MESError(.unsupportedParameter, "No model the engine may pick at \(tier.rawValue) takes "
                               + "\(choices.map(\.id).joined(separator: ", ")); name one of: \(names(taking)).", param: param)
            }
            guard choosable.contains(where: fits) else {
                throw MESError(.outOfLimits, "\(names(choosable)) apply at most "
                               + "\(choosable.map { maxAdapters[$0.id] ?? 1 }.max() ?? 1) adapter(s) at once.", param: param)
            }
        }

        // A reference-conditioned adapter's slots are filled, in order, from the edit's images.
        let slots = chosen.flatMap(\.info.conditioning)
        let required = slots.filter(\.required).count
        if required > 0 {
            let images = request.inputs?["images"]?.values.count ?? 0
            guard images >= required else {
                throw MESError(.invalidRequest, "\(chosen.filter { $0.info.kind == "ic" }.map(\.info.id).joined(separator: ", ")) "
                               + "takes \(required) image(s) in images, in this order: "
                               + slots.filter(\.required).map(\.role).joined(separator: ", ") + ".", param: "images")
            }
        }
    }

    /// The tier the engine kit chooses at (`JobRegistry.chooseModel`): the request's, or standard, or the first offered.
    static func tier(_ request: JobRequest, descriptor: Descriptor) -> QualityTier {
        if let tier = request.params?["quality"]?.stringValue.flatMap(QualityTier.init(rawValue:)) { return tier }
        return descriptor.qualityTiers.contains(.standard) ? .standard : descriptor.qualityTiers.first ?? .standard
    }

    // MARK: - Prompts

    /// `prompt` as the adapters want it: each one's template wrapped round it (or standing in for an empty one), then its
    /// trigger added when the prompt lacks it. Returns the ids that changed it.
    static func prompt(_ prompt: String, for adapters: [AdapterInfo]) -> (prompt: String, changedBy: [String]) {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var changedBy: [String] = []
        for adapter in adapters {
            let before = text
            if let template = adapter.promptTemplate {
                if template.contains("{prompt}") {
                    text = template.replacingOccurrences(of: "{prompt}", with: text)
                } else if text.isEmpty {
                    text = template
                }
            }
            if let trigger = adapter.trigger?.trimmingCharacters(in: .whitespaces), !trigger.isEmpty,
               text.range(of: trigger, options: .caseInsensitive) == nil {
                // A trigger word goes before the prompt; a trigger sentence is its own sentence.
                let sentence = trigger.contains(" ")
                let joint = !sentence || trigger.last.map { ".!?".contains($0) } == true ? " " : ". "
                text = text.isEmpty ? trigger : trigger + joint + text
            }
            if text != before { changedBy.append(adapter.id) }
        }
        return (text, changedBy)
    }
}

extension RunPlan {
    /// The request's adapters for `route`, as the runtime takes them (`JobSpec.adapters`), with an IC adapter's images
    /// taken in order from `images` into inputs of their own. Returns the images left for the edit itself. Records each
    /// adapter in `model_params.adapters` and adapts `prompt` (`Adapters.prompt`), warning when it changed.
    mutating func applyAdapters(_ route: RoutedModel, prompt: inout String, param: String, images: [MLXToolKit.Image] = [])
        async -> (adapters: [JobAdapter]?, inputs: [String: [MLXToolKit.Image]], images: [MLXToolKit.Image]) {
        let choices = Adapters.choices(context.extensions)
        guard !choices.isEmpty else { return (nil, [:], images) }
        let infos = await normalizer.directory.model(route.id)?.adapters ?? []
        var remaining = images[...]
        var inputs: [String: [MLXToolKit.Image]] = [:]
        var jobAdapters: [JobAdapter] = []
        var applied: [AdapterInfo] = []
        var records: [MESValue] = []
        for (n, choice) in choices.enumerated() {
            let info = infos.first { $0.id == choice.id }
            var conditioning: [String: String] = [:]
            for slot in info?.conditioning ?? [] where slot.required || !remaining.isEmpty {
                guard let image = remaining.popFirst() else { break }
                let input = "adapter\(n).\(slot.role)"
                inputs[input] = [image]
                conditioning[slot.role] = input
            }
            jobAdapters.append(JobAdapter(id: choice.id, strength: choice.strength, conditioning: conditioning))
            if let info { applied.append(info) }

            // What ran (MES 0.4's provenance.adapters): the pinned file and the licence.
            let descriptor = route.adapters.first { $0.id == choice.id }
            let source = descriptor?.source
            var record: [String: MESValue] = [
                "id": .string(choice.id),
                "strength": .number(choice.strength ?? descriptor?.defaultStrength ?? info?.defaultStrength ?? 1),
            ]
            if let info {
                record["title"] = .string(info.title)
                record["license"] = (try? MESValue(encoding: Adapters.license(info))) ?? .null
            }
            if let source {
                record["source"] = .string(source.repo)
                record["revision"] = .string(source.revision)
                record["sha256"] = .string(source.sha256)
            }
            records.append(.object(record))
        }
        modelParams["adapters"] = .array(records)

        let adapted = Adapters.prompt(prompt, for: applied)
        if !adapted.changedBy.isEmpty {
            modelParams["adapter_prompt"] = .string(adapted.prompt)
            warn("prompt_rewritten", "The \(param) was changed for \(adapted.changedBy.joined(separator: ", ")) (its trigger or "
                 + "prompt template); what ran is in effective.model_params.adapter_prompt.", param: param)
            prompt = adapted.prompt
        }
        return (jobAdapters, inputs, Array(remaining))
    }
}
