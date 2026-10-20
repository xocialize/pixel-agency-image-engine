import Foundation
import ImageServerAPI
import ImageServerModels
import MESCore
import MESEngineCore
import MLXToolKit
import PromptEnhanceKit

/// Prompt enhancement (AB-D-0155, E2; docs/PROMPTS-AND-ADAPTERS.md §1.5): before `image.generate` runs, a short prompt
/// is rewritten into the detailed caption the model was trained on, with that model's profile from prompt-enhance-kit
/// (`ProfileLibrary.imageModels()`), on a text backbone that's a model in the catalog (`PromptBackbones`).
///
/// - **The extension** `x-pixelagency.prompt_enhance {mode, seed}` on `image.generate` and `image.edit`, declared while the
///   backbone is on. A request without it is `auto`:
///   - **auto** follows the profile's policy: a recommended profile rewrites a prompt that isn't already detailed; an
///     optional one leaves prompts alone.
///   - **on** rewrites whenever the profile can (a prompt that's already JSON still goes as typed).
///   - **off** sends the prompt as typed.
/// - **Never engine-written prompts.** Only the request's own prompt passes through here: fill and extend's marker
///   instructions, erase by name and the creative upscale's instruction go to their models as written.
/// - **Reproducible.** The enhancer's seed is the job's (the extension's `seed` overrides it), so a job with a fixed seed
///   reproduces end to end.
/// - **Honest results (G4).** `effective.model_params.prompt_enhancement` says what happened, with the rewrite, and a
///   `prompt_rewritten` warning says the prompt was changed.
/// - **Edits** need a rewriter that sees the input image (E4), so an edit's instruction goes as typed (`needs_vision`).
/// - **FLUX 3 Klein** keeps BFL's own upsampler, inside its package, switched only for the whole engine
///   (`MLXIMG_FLUX3_UPSAMPLER`) until the runtime passes request metaData through (AB-A-0191).
public enum PromptEnhance {
    static let name = "x-pixelagency.prompt_enhance"
    /// The backbone every text-to-image profile runs on: Qwen3.5-4B int4 (`PromptBackbones`).
    public static let backboneID = "qwen3.5-4b"
    static let library = ProfileLibrary.imageModels()
    /// The model whose enhancer lives in its own package.
    static let flux3 = "flux-3-klein"
    /// The operations whose prompts it enhances.
    static let operations: Set<String> = ["image.generate", "image.edit"]

    enum Mode: String, Sendable { case auto, on, off }

    struct Request: Equatable, Sendable {
        var mode = Mode.auto
        /// The enhancer's seed, when the request pins it apart from the job's.
        var seed: UInt64?

        /// The extension's values; `auto` when the request doesn't carry it.
        init(_ extensions: [String: MESValue]) {
            let value = extensions[PromptEnhance.name]
            mode = value?["mode"]?.stringValue.flatMap(Mode.init(rawValue:)) ?? .auto
            seed = value?["seed"]?.intValue.flatMap { $0 >= 0 ? UInt64($0) : nil }
        }
    }

    static let spec = ExtensionSpec(name: name, title: "Prompt enhancement", schema: [
        "type": "object", "additionalProperties": false,
        "properties": [
            "mode": ["enum": ["auto", "on", "off"], "default": "auto",
                     "description": .string("auto (the default, also without this extension): rewrite a short prompt for "
                         + "models whose makers recommend it. on: rewrite whenever the model has a profile. off: send the prompt "
                         + "as typed; use it when your prompt is already a full caption. The rewrite is reported in "
                         + "effective.model_params.prompt_enhancement."),
                     "x-mes-ui": ["label": "Enhance prompt", "widget": "picker", "order": 1,
                                  "help": "Rewrite a short prompt into the detailed caption the model works best with."]],
            "seed": ["type": "integer", "minimum": 0, "maximum": 9_007_199_254_740_991,
                     "description": .string("The enhancer's sampling seed. The job's seed by default, so a fixed seed "
                         + "reproduces the rewrite too."),
                     "x-mes-ui": ["label": "Enhancer seed", "widget": "seed", "order": 2, "advanced": true]],
        ],
    ])

    /// How a model wants its prompts, for its offer's notes and its console card: `required`, `recommended` or `optional`,
    /// and who rewrites them. nil for a model with no enhancer.
    public static func prompting(forModel id: String) -> (policy: String, by: String)? {
        if id == flux3 { return ("required", "its own upsampler") }
        guard let profile = library.profile(forModel: id) else { return nil }
        return (profile.policy.rawValue, "the \(profile.title) profile")
    }

    /// The backbone's card: what turning it off does.
    public static let backboneNote = "The prompt enhancer: it rewrites short prompts for "
        + library.profiles.flatMap(\.models).sorted().joined(separator: ", ")
        + " before they run, with each model's own profile, and reports the rewrite in effective.model_params.prompt_enhancement. "
        + "Turned off, prompts go to the image models as typed. FLUX 3 Klein uses its own upsampler instead."

    /// The offer's line about prompts (image.generate), while the backbone is on.
    static func note(forModel id: String) -> String? {
        guard id != flux3, let profile = library.profile(forModel: id) else { return nil }
        switch profile.policy {
        case .required, .recommended:
            return "The engine rewrites a short prompt with the \(profile.title) profile before it runs, as the model's makers "
                + "recommend; the rewrite is reported in effective.model_params.prompt_enhancement, and "
                + "\(name) mode off sends a prompt as typed."
        case .optional:
            return "Prompts go as typed; \(name) mode on rewrites them with the \(profile.title) profile first."
        }
    }

    /// The kit's outcomes on the wire.
    static func wire(_ outcome: EnhanceResult.Outcome) -> String {
        switch outcome {
        case .enhanced: "enhanced"
        case .passedThrough: "passed_through"
        case .notRecommended: "not_recommended"
        case .noInstruction: "no_instruction"
        case .needsVision: "needs_vision"
        case .failed: "failed"
        case .timedOut: "timed_out"
        case .empty: "empty"
        }
    }

    /// What `effective.model_params.prompt_enhancement` reports.
    struct Record {
        var applied = false
        /// The kit's outcome (`wire`), or the engine's own: `off` (the request asked), `no_profile`, `unavailable` (the
        /// backbone is off or failed to load), `built_in` (FLUX 3 Klein's upsampler).
        var outcome: String
        var profile: String?
        var version: Int?
        var backbone: String?
        var seed: UInt64?
        /// The prompt the model ran, when it was rewritten.
        var prompt: String?

        var value: MESValue {
            var object: [String: MESValue] = ["applied": .bool(applied), "outcome": .string(outcome)]
            if let profile { object["profile"] = .string(profile) }
            if let version { object["version"] = .number(Double(version)) }
            if let backbone { object["backbone"] = .string(backbone) }
            if let seed { object["seed"] = .number(Double(seed)) }
            if let prompt { object["prompt"] = .string(prompt) }
            return .object(object)
        }
    }

}

extension RunPlan {
    /// The prompt `image.generate` or `image.edit` runs: the request's own, rewritten by the model's profile when the
    /// extension's mode and the profile's policy say so. Call it before the image model loads: the backbone loads, runs,
    /// and is released or kept warm (`Residency.releaseHelper`) first. Reports in `model_params.prompt_enhancement`.
    mutating func enhancedPrompt(_ prompt: String, task: EnhanceTask, seed jobSeed: UInt64) async throws -> String {
        let request = PromptEnhance.Request(context.extensions)
        let model = context.model.id
        func report(_ record: PromptEnhance.Record) { modelParams["prompt_enhancement"] = record.value }

        if model == PromptEnhance.flux3 {
            report(flux3Upsampler(request.mode))
            return prompt
        }
        guard let profile = PromptEnhance.library.profile(forModel: model) else {
            if request.mode == .on {
                warn("prompt_enhance_ignored", "\(context.model.title) has no prompt enhancement profile; the prompt was used as typed.",
                     param: PromptEnhance.name)
            }
            report(.init(outcome: "no_profile"))
            return prompt
        }
        let seed = request.seed ?? jobSeed
        var record = PromptEnhance.Record(outcome: "off", profile: profile.id, version: profile.version)
        guard request.mode != .off else {
            report(record)
            return prompt
        }
        if task.needsVision {
            if request.mode == .on {
                warn("prompt_enhance_ignored", "Edit instructions aren't enhanced yet: the rewriter would need to see the image. "
                     + "The instruction was used as typed.", param: PromptEnhance.name)
            }
            record.outcome = PromptEnhance.wire(.needsVision)
            report(record)
            return prompt
        }

        // Would the kit call the backbone at all? Its decision reads only the prompt and the profile, so a prompt that
        // goes as typed (an optional profile under auto, a detailed or structured prompt) never loads the backbone.
        let mode: EnhanceMode = request.mode == .on ? .always : .auto
        if let skip = PromptEnhancer.decision(prompt, profile: profile, task: task, mode: mode) {
            record.outcome = PromptEnhance.wire(skip)
            report(record)
            return prompt
        }

        record.backbone = PromptEnhance.backboneID
        record.seed = seed
        guard let text = normalizer.textRunner, await normalizer.backboneOffered() else {
            record.outcome = "unavailable"
            if request.mode == .on {
                warn("prompt_enhance_ignored", "The prompt enhancer (\(PromptEnhance.backboneID)) is off on this engine; the "
                     + "prompt was used as typed.", param: PromptEnhance.name)
            }
            report(record)
            return prompt
        }
        let backbone: RoutedModel
        do {
            backbone = try await route(.llm, named: PromptEnhance.backboneID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Enhancement never blocks generation: a backbone that can't load leaves the prompt as typed.
            print("job \(context.jobID): the prompt enhancer didn't load: \(error)")
            record.outcome = "unavailable"
            let why = (ImageNormalizer.mesError(error) as? MESError)?.message ?? "\(error)"
            warn("prompt_enhance_failed", "The prompt enhancer couldn't load (\(why)); the prompt was used as typed.",
                 param: PromptEnhance.name)
            report(record)
            return prompt
        }
        await context.reporter.progress(.preparing, message: "enhancing the prompt")
        let enhancer = PromptEnhancer(parameters: LLMParameters(temperature: 0.7, maxTokens: 512, seed: seed))
        // The kit rethrows cancellation, so a cancelled job stops here instead of generating from the prompt as typed.
        let result = try await enhancer.enhance(prompt, profile: profile, task: task, mode: mode,
                                                timeout: normalizer.options.promptEnhanceTimeout) { request in
            try await text.generate(request, on: backbone)
        }
        if let i = admitted.lastIndex(where: { $0.packageID == backbone.packageID }) { admitted.remove(at: i) }
        await normalizer.residency.releaseHelper(backbone)

        record.outcome = PromptEnhance.wire(result.outcome)
        record.applied = result.applied
        switch result.outcome {
        case .enhanced:
            record.prompt = result.prompt
            warn("prompt_rewritten", "The prompt was rewritten for \(context.model.title) with the \(profile.title) profile "
                 + "(v\(profile.version)) on \(backbone.displayName); the rewrite is in effective.model_params.prompt_enhancement. "
                 + "\(PromptEnhance.name) mode off sends a prompt as typed.", param: "prompt")
        case .failed, .timedOut, .empty:
            print("job \(context.jobID): prompt enhancement \(record.outcome): \(result.failure ?? "-")")
            warn("prompt_enhance_failed", "Prompt enhancement \(record.outcome.replacingOccurrences(of: "_", with: " ")); the "
                 + "prompt was used as typed.", param: PromptEnhance.name)
        default:
            break
        }
        report(record)
        return result.prompt
    }

    /// FLUX 3 Klein's enhancer is BFL's upsampler, inside flux3-klein-swift, which rewrites every prompt unless the engine
    /// was started with `MLXIMG_FLUX3_UPSAMPLER=off` (the runtime reads the same variable). The package doesn't hand the
    /// rewrite back, so it isn't reported.
    ///
    /// TODO(AB-A-0191): once the runtime passes request metaData through, map the mode onto the package's
    /// `metaData["upsample"]` (off → false, with a warning that results will suffer) instead of warning that it can't.
    mutating func flux3Upsampler(_ mode: PromptEnhance.Mode) -> PromptEnhance.Record {
        let tier = ProcessInfo.processInfo.environment["MLXIMG_FLUX3_UPSAMPLER"]?.lowercased() ?? "int8"
        let on = tier != "off"
        if mode == .off, on {
            warn("prompt_enhance_ignored", "FLUX 3 Klein's own prompt upsampler can't be switched off per request yet; it "
                 + "rewrote the prompt.", param: PromptEnhance.name)
        } else if mode == .on, !on {
            warn("prompt_enhance_ignored", "FLUX 3 Klein's prompt upsampler is switched off on this engine; the prompt was used "
                 + "as typed.", param: PromptEnhance.name)
        }
        if on {
            warn("prompt_rewritten", "FLUX 3 Klein's own upsampler rewrote the prompt inside the model, as its makers require; "
                 + "the rewrite isn't reported.", param: "prompt")
        }
        return .init(applied: on, outcome: "built_in", profile: "flux3-upsampler", backbone: on ? "flux-3-image-klein-pup (\(tier))" : nil)
    }
}
