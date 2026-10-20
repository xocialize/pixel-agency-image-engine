import Foundation
import ImageServerAPI
import ImageServerModels
import MESCore
import MESEngineCore
import MLXToolKit
import PromptEnhanceKit

/// Prompt enhancement (Image §1.9; AB-D-0155, E2; docs/PROMPTS-AND-ADAPTERS.md §1.5): before `image.generate` runs, a
/// short prompt is rewritten into the detailed caption the model was trained on, with that model's profile from
/// prompt-enhance-kit (`ProfileLibrary.imageModels()`), on a text backbone that's a model in the catalog (`PromptBackbones`).
///
/// - **The vocabulary** `prompt_enhance: auto | on | off`, declared on generate and edit wherever the engine may rewrite
///   (the backbone is on, FLUX 3 Klein is offered, or an offered adapter has a trigger or template). Without it, `auto`:
///   - **auto** follows the profile's policy: a recommended profile rewrites a prompt that isn't already detailed; an
///     optional one leaves prompts alone.
///   - **on** rewrites whenever the profile can (a prompt that's already JSON still goes as typed).
///   - **off** sends the text as typed, adapters' triggers and templates included.
/// - **Never engine-written prompts.** Only the request's own prompt passes through here: fill and extend's marker
///   instructions, erase by name and the creative upscale's instruction go to their models as written.
/// - **Reproducible.** The enhancer's seed is the job's, so a job with a fixed seed reproduces end to end.
/// - **Honest results.** A rewrite warns `prompt_rewritten`; the text the model received is `effective.prompt` (or
///   `effective.instruction`); `effective.prompt_enhance` is the mode that applied; the backbone is a helper in
///   `provenance.helpers` with the role `prompt_enhance`. `effective.model_params.prompt_enhancement` keeps the detail:
///   the profile, its version, the outcome, the backbone and the seed.
/// - **Licence policy.** Under `policy.license: commercial-use` a backbone whose terms don't allow it is skipped, with
///   `helper_skipped_by_policy` (Base §10.3). Qwen3.5-4B is Apache-2.0.
/// - **Edits** need a rewriter that sees the input image (E4), so an edit's instruction goes as typed (`needs_vision`).
/// - **FLUX 3 Klein** keeps BFL's own upsampler, inside its package: not a helper, and its rewrite isn't handed back. The
///   mode switches it per request through the package's `upsample` key (mlx-image-runtime ≥ 0.14.0, AB-T-0336);
///   `MLXIMG_FLUX3_UPSAMPLER` sets it for the whole engine, and `off` there loads none.
public enum PromptEnhance {
    /// The backbone every text-to-image profile runs on: Qwen3.5-4B int4 (`PromptBackbones`).
    public static let backboneID = "qwen3.5-4b"
    static let library = ProfileLibrary.imageModels()
    /// The model whose enhancer lives in its own package.
    static let flux3 = "flux-3-klein"
    /// The package key that switches a model's own upsampler for one request (FLUX 3 Klein's, AB-A-0191).
    static let upsampleKey = "upsample"
    /// The operations whose prompts it enhances.
    static let operations: Set<String> = ["image.generate", "image.edit"]

    typealias Mode = ImageProfile.PromptEnhanceMode

    /// The `prompt_enhance` param's description on this engine.
    static let paramDescription = "auto (the default): rewrite a short prompt for models whose makers recommend it. on: "
        + "rewrite whenever the model has a profile. off: send the text as typed, adapters' triggers and templates "
        + "included; use it when your prompt is already a full caption. A rewrite is reported in effective.prompt "
        + "(or effective.instruction) with a prompt_rewritten warning."

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
        + " before they run, with each model's own profile, and reports the rewrite in effective.prompt. "
        + "Turned off, prompts go to the image models as typed. FLUX 3 Klein uses its own upsampler instead."

    /// The offer's line about prompts (image.generate), while the backbone is on.
    static func note(forModel id: String) -> String? {
        guard id != flux3, let profile = library.profile(forModel: id) else { return nil }
        switch profile.policy {
        case .required, .recommended:
            return "The engine rewrites a short prompt with the \(profile.title) profile before it runs, as the model's makers "
                + "recommend; the rewrite is reported in effective.prompt, and prompt_enhance off sends a prompt as typed."
        case .optional:
            return "Prompts go as typed; prompt_enhance on rewrites them with the \(profile.title) profile first."
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
        /// backbone is off or failed to load, or FLUX 3 Klein's upsampler is off on this engine), `built_in` (FLUX 3
        /// Klein's upsampler rewrote it).
        var outcome: String
        var profile: String?
        var version: Int?
        var backbone: String?
        var seed: UInt64?

        var value: MESValue {
            var object: [String: MESValue] = ["applied": .bool(applied), "outcome": .string(outcome)]
            if let profile { object["profile"] = .string(profile) }
            if let version { object["version"] = .number(Double(version)) }
            if let backbone { object["backbone"] = .string(backbone) }
            if let seed { object["seed"] = .number(Double(seed)) }
            return .object(object)
        }
    }

}

extension RunPlan {
    /// The request's `prompt_enhance` (Image §1.9), `auto` when it doesn't say.
    var promptEnhanceMode: PromptEnhance.Mode {
        context.param(ImageProfile.Param.promptEnhance)?.stringValue.flatMap(PromptEnhance.Mode.init(rawValue:)) ?? .auto
    }

    /// The prompt `image.generate` or `image.edit` runs: the request's own, rewritten by the model's profile when the
    /// mode and the profile's policy say so. Call it before the image model loads: the backbone loads, runs, and is
    /// released or kept warm (`Residency.releaseHelper`) first. `param` is the input it came from (`prompt` or
    /// `instruction`). Reports the mode in `effective.prompt_enhance`, the backbone in `helpers`, and the detail in
    /// `model_params.prompt_enhancement`; `reportPrompt` reports the text once adapters have had their say.
    mutating func enhancedPrompt(_ prompt: String, param: String, task: EnhanceTask, seed: UInt64) async throws -> String {
        let mode = promptEnhanceMode
        let model = context.model.id
        if context.descriptor.params["properties"]?[ImageProfile.Param.promptEnhance] != nil {
            effective[ImageProfile.Param.promptEnhance] = .string(mode.rawValue)
        }
        func report(_ record: PromptEnhance.Record) { modelParams["prompt_enhancement"] = record.value }

        if model == PromptEnhance.flux3 {
            report(flux3Upsampler(mode, param: param))
            return prompt
        }
        guard let profile = PromptEnhance.library.profile(forModel: model) else {
            if mode == .on {
                warn(ImageProfile.WarningCode.promptEnhanceIgnored, "\(context.model.title) has no prompt enhancement profile; "
                     + "the \(param) was used as typed.", param: ImageProfile.Param.promptEnhance)
            }
            report(.init(outcome: "no_profile"))
            return prompt
        }
        var record = PromptEnhance.Record(outcome: "off", profile: profile.id, version: profile.version)
        guard mode != .off else {
            report(record)
            return prompt
        }
        if task.needsVision {
            if mode == .on {
                warn(ImageProfile.WarningCode.promptEnhanceIgnored, "Edit instructions aren't enhanced yet: the rewriter would "
                     + "need to see the image. The instruction was used as typed.", param: ImageProfile.Param.promptEnhance)
            }
            record.outcome = PromptEnhance.wire(.needsVision)
            report(record)
            return prompt
        }

        // Would the kit call the backbone at all? Its decision reads only the prompt and the profile, so a prompt that
        // goes as typed (an optional profile under auto, a detailed or structured prompt) never loads the backbone.
        let enhanceMode: EnhanceMode = mode == .on ? .always : .auto
        if let skip = PromptEnhancer.decision(prompt, profile: profile, task: task, mode: enhanceMode) {
            record.outcome = PromptEnhance.wire(skip)
            report(record)
            return prompt
        }

        record.backbone = PromptEnhance.backboneID
        record.seed = seed
        guard let text = normalizer.textRunner, await normalizer.backboneOffered(),
              let info = await normalizer.directory.model(ModelID(PromptEnhance.backboneID)) else {
            record.outcome = "unavailable"
            if mode == .on {
                warn(ImageProfile.WarningCode.promptEnhanceIgnored, "The prompt enhancer (\(PromptEnhance.backboneID)) is off "
                     + "on this engine; the \(param) was used as typed.", param: ImageProfile.Param.promptEnhance)
            }
            report(record)
            return prompt
        }
        // A helper's licence is held to the request's policy like the model's (Base §10.3).
        let license = ImageNormalizer.license(info)
        guard context.policy.allows(license) else {
            record.outcome = "policy"
            warn(BaseWarningCode.helperSkippedByPolicy, "The prompt enhancer (\(info.displayName), \(license.spdx)) doesn't "
                 + "satisfy the request's licence policy; the \(param) was used as typed.", param: ImageProfile.Param.promptEnhance)
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
            warn(ImageProfile.WarningCode.promptEnhanceFailed, "The prompt enhancer couldn't load (\(why)); the \(param) was "
                 + "used as typed.", param: ImageProfile.Param.promptEnhance)
            report(record)
            return prompt
        }
        await context.reporter.progress(.preparing, message: "enhancing the prompt")
        let enhancer = PromptEnhancer(parameters: LLMParameters(temperature: 0.7, maxTokens: 512, seed: seed))
        // The kit rethrows cancellation, so a cancelled job stops here instead of generating from the prompt as typed.
        let result = try await enhancer.enhance(prompt, profile: profile, task: task, mode: enhanceMode,
                                                timeout: normalizer.options.promptEnhanceTimeout) { request in
            try await text.generate(request, on: backbone)
        }
        if let i = admitted.lastIndex(where: { $0.packageID == backbone.packageID }) { admitted.remove(at: i) }
        await normalizer.residency.releaseHelper(backbone)

        record.outcome = PromptEnhance.wire(result.outcome)
        record.applied = result.applied
        switch result.outcome {
        case .enhanced:
            helpers.append(HelperRef(id: PromptEnhance.backboneID, title: backbone.displayName,
                                     revision: Self.pinned(backbone.revision), license: license,
                                     role: ImageProfile.HelperRole.promptEnhance))
            warn(ImageProfile.WarningCode.promptRewritten, "The \(param) was rewritten for \(context.model.title) with the "
                 + "\(profile.title) profile (v\(profile.version)) on \(backbone.displayName); what ran is in effective.\(param). "
                 + "prompt_enhance off sends it as typed.", param: param)
        case .failed, .timedOut, .empty:
            print("job \(context.jobID): prompt enhancement \(record.outcome): \(result.failure ?? "-")")
            warn(ImageProfile.WarningCode.promptEnhanceFailed, "Prompt enhancement "
                 + "\(record.outcome.replacingOccurrences(of: "_", with: " ")); the \(param) was used as typed.",
                 param: ImageProfile.Param.promptEnhance)
        default:
            break
        }
        report(record)
        return result.prompt
    }

    /// The text the model receives, in `effective.prompt` or `effective.instruction`, when it isn't the request's own
    /// (Image §1.9): rewritten by the enhancer, or by an adapter's trigger or template.
    mutating func reportPrompt(_ prompt: String, typed: String, param: String) {
        if prompt != typed { effective[param] = .string(prompt) }
    }

    /// FLUX 3 Klein's enhancer is BFL's upsampler, inside flux3-klein-swift. The mode reaches it as the package's
    /// `upsample` key (`requestPromptKeys`): off skips it, with a warning, since BFL requires it; on asks for it; auto
    /// leaves the engine's setting. `MLXIMG_FLUX3_UPSAMPLER=off` (the runtime reads the same variable) loads no
    /// upsampler, so on can't be honoured. It's part of the model, not a helper, and the package doesn't hand the
    /// rewrite back, so it warns `prompt_rewritten` without the text (Image §1.9 allows that).
    mutating func flux3Upsampler(_ mode: PromptEnhance.Mode, param: String) -> PromptEnhance.Record {
        let tier = ProcessInfo.processInfo.environment["MLXIMG_FLUX3_UPSAMPLER"]?.lowercased() ?? "int8"
        let configured = tier != "off"
        var record = PromptEnhance.Record(outcome: "built_in", profile: "flux3-upsampler")
        switch mode {
        case .off:
            record.outcome = "off"
            if configured {
                warn("prompt_upsampler_off", "FLUX 3 Klein's own prompt upsampler was skipped, as asked; its makers require "
                     + "it, so expect weaker results unless the prompt is already a full scene caption.",
                     param: ImageProfile.Param.promptEnhance)
            }
            return record
        case .on where !configured:
            warn(ImageProfile.WarningCode.promptEnhanceIgnored, "FLUX 3 Klein's prompt upsampler is switched off on this "
                 + "engine; the \(param) was used as typed.", param: ImageProfile.Param.promptEnhance)
            record.outcome = "unavailable"
            return record
        case .auto where !configured:
            record.outcome = "unavailable"
            return record
        case .on, .auto:
            warn(ImageProfile.WarningCode.promptRewritten, "FLUX 3 Klein's own upsampler rewrote the \(param) inside the "
                 + "model, as its makers require; the rewrite isn't handed back. prompt_enhance off sends it as typed.",
                 param: param)
            record.applied = true
            record.backbone = "flux-3-image-klein-pup (\(tier))"
            return record
        }
    }

    /// The package keys for the request's own prompt, on a model that rewrites prompts itself (FLUX 3 Klein's
    /// `upsample`, AB-T-0336): off sends it as typed, on asks for the upsampler, auto leaves the engine's setting.
    func requestPromptKeys(_ route: RoutedModel) -> ISValueObject? {
        guard route.takes(PromptEnhance.upsampleKey) else { return nil }
        switch promptEnhanceMode {
        case .off: return [PromptEnhance.upsampleKey: .bool(false)]
        case .on: return [PromptEnhance.upsampleKey: .bool(true)]
        case .auto: return nil
        }
    }

    /// The package keys for a prompt the engine wrote (fill and extend's marker instructions, erase by name, the creative
    /// upscale's instruction): it goes to the model as written, so a model's own upsampler is skipped (§1.1).
    func writtenPromptKeys(_ route: RoutedModel) -> ISValueObject? {
        route.takes(PromptEnhance.upsampleKey) ? [PromptEnhance.upsampleKey: .bool(false)] : nil
    }
}

extension RoutedModel {
    /// Whether this model takes the package key `name` per request, for the routed capability.
    func takes(_ name: String) -> Bool { requestKeys.contains { $0.name == name } }
}
