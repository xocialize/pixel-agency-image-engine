import Foundation
import MESCore
import MLXToolKit

/// How each Image-profile operation maps onto the model runtime (Engines-PRD IMG-1–5): the capability that serves
/// it, which model serves each quality tier by default, and the vocabulary the engine honours. A parameter the
/// engine can't honour isn't offered (Base §6 rule 4: no surprises); one it accepts but a model ignores is warned.
struct OperationSpec: Sendable {
    let operation: String
    /// The capabilities whose models are offered, the operation's own first (fill and extend also offer edit models,
    /// which run them generatively).
    let capabilities: [Capability]
    var capability: Capability { capabilities[0] }
    /// Tiers per model id. A tier's default is the first registered model listed for it in `defaults`.
    let tiers: [String: [QualityTier]]
    /// Preferred defaults, most preferred first. The first registered one is the operation's default.
    let defaults: [String]
    /// Tiers for offered models the table doesn't name.
    let otherTiers: [QualityTier]
    /// Vocabulary names offered as params.
    let params: [String]
    /// Narrower schemas than the vocabulary's, where the engine honours less.
    let narrowed: [String: JSONValue]
    /// Inputs the engine declares (name → required); others in the profile table are left out.
    let inputs: [String: Bool]
    /// Further capabilities a plan may use (e.g. restore's scratches use defect detection and inpainting).
    let helpers: [Capability]

    /// The models to prefer at `tier` when a request names none: `defaults` in order, those that serve the tier.
    func preferred(at tier: QualityTier) -> [String] {
        defaults.filter { (tiers[$0] ?? otherTiers).contains(tier) }
    }

    init(_ operation: String, _ capabilities: Capability..., tiers: [String: [QualityTier]] = [:], defaults: [String] = [],
         otherTiers: [QualityTier] = [.standard], params: [String], narrowed: [String: JSONValue] = [:],
         inputs: [String: Bool], helpers: [Capability] = []) {
        self.operation = operation; self.capabilities = capabilities; self.tiers = tiers; self.defaults = defaults
        self.otherTiers = otherTiers; self.params = params; self.narrowed = narrowed; self.inputs = inputs; self.helpers = helpers
    }
}

enum OperationTable {
    static let all: [QualityTier] = [.draft, .standard, .best]
    /// PNG and JPEG, 8-bit: what the engine writes (Image §1.2 lets an engine refuse other formats; here they're
    /// simply not offered).
    static let output: JSONValue = [
        "type": "object", "additionalProperties": false,
        "properties": ["media_type": ["enum": ["image/png", "image/jpeg"]], "bit_depth": ["enum": [8]]],
    ]

    static let specs: [OperationSpec] = [
        OperationSpec("image.generate", .textToImage,
                      tiers: ["klein-4b": [.draft], "z-image-turbo": [.standard], "z-image": [.best], "qwen-image-flash": [.standard, .best]],
                      defaults: ["z-image-turbo", "klein-4b", "z-image"],
                      params: ["negative_prompt", "size", "aspect", "megapixels", "quality", "seed", "count", "output"],
                      narrowed: ["count": ["type": "integer", "minimum": 1, "maximum": 4, "default": 1], "output": output],
                      inputs: ["prompt": true]),
        OperationSpec("image.edit", .imageEdit,
                      tiers: ["klein-4b": [.draft, .standard], "qwen-image-edit": [.best]],
                      defaults: ["klein-4b", "qwen-image-edit"],
                      params: ["strength", "quality", "seed", "size", "output"], narrowed: ["output": output],
                      inputs: ["images": true, "instruction": true]),
        // Fill: LaMa without a prompt; with one, an edit model paints it in (`ImageNormalizer.defaultModel`).
        OperationSpec("image.fill", .imageInpaint, .imageEdit,
                      tiers: ["lama-inpaint": all, "klein-4b": [.draft, .standard], "qwen-image-edit": [.best]],
                      defaults: ["lama-inpaint"],
                      params: ["quality", "seed", "output"], narrowed: ["output": output],
                      inputs: ["image": true, "mask": true, "prompt": false]),
        // Erase is prompt-less inpainting (IMG-5): LaMa, or MI-GAN at draft.
        OperationSpec("image.erase", .imageInpaint, defaults: ["lama-inpaint"], otherTiers: all,
                      params: ["quality", "output"], narrowed: ["output": output],
                      inputs: ["image": true, "mask": true]),
        // Extend is inpainting on a padded canvas (IMG-5). LaMa fills holes well but can't continue a scene past the
        // border, so an edit model is the default and LaMa the draft.
        OperationSpec("image.extend", .imageEdit, .imageInpaint,
                      tiers: ["lama-inpaint": [.draft], "klein-4b": [.standard], "qwen-image-edit": [.best]],
                      defaults: ["klein-4b", "qwen-image-edit", "lama-inpaint"],
                      params: ["canvas", "quality", "seed", "output"], narrowed: ["output": output],
                      inputs: ["image": true, "prompt": false]),
        // Measured (R1b, docs/TIERS.md): photos, NERVE → RealPLKSR → HEART (best PSNR on 12 of 12 Commons rungs).
        // SeedVR2 measured worst of the learned models on photos, and Nacre is a generative route: offered, never a
        // default. Drawn content goes to NERVE at every tier (it beats RealPLKSR on graphics), so NERVE serves all.
        OperationSpec("image.upscale", .imageUpscale,
                      tiers: ["nerve-upscale": all, "realplksr-upscale": [.standard], "heart-upscale": [.best],
                              "seedvr2-upscale": [.best], "nacre-upscale": [.best]],
                      defaults: ["realplksr-upscale", "heart-upscale", "nerve-upscale"],
                      params: ["scale", "content", "quality", "output"], narrowed: ["output": output],
                      inputs: ["image": true]),
        OperationSpec("image.restore", .imageRestore, defaults: ["nafnet-restore"], otherTiers: all,
                      params: ["kind", "quality", "output"], narrowed: ["output": output],
                      inputs: ["image": true], helpers: [.defectDetect, .imageInpaint]),
        OperationSpec("image.relight", .imageRelight, defaults: ["cidnet-relight"], otherTiers: all,
                      params: ["strength", "quality", "output"], narrowed: ["output": output],
                      inputs: ["image": true, "prompt": false]),
        OperationSpec("image.colorize", .imageColorize, defaults: ["ddcolor-colorize"], otherTiers: all,
                      params: ["quality", "output"], narrowed: ["output": output],
                      inputs: ["image": true]),
        OperationSpec("image.matte", .matting, defaults: ["birefnet-matte"], otherTiers: all,
                      params: ["outputs"], inputs: ["image": true]),
        // Measured: first-click IoU SAM 2.1 0.755 vs EdgeTAM 0.537 (DEV/click-select-bench), at 0.1–0.25 s per image.
        OperationSpec("image.segment", .promptSegment,
                      tiers: ["edgetam-segment": [.draft], "sam21-segment": [.standard, .best]],
                      defaults: ["sam21-segment", "edgetam-segment"],
                      params: ["count"], narrowed: ["count": ["type": "integer", "minimum": 1, "maximum": 1, "default": 1]],
                      inputs: ["image": true, "points": true]),
        OperationSpec("image.describe", .imageAnalysis, defaults: ["mage-vl"], otherTiers: all,
                      params: ["language"], inputs: ["image": true]),
        OperationSpec("image.score", .imageQualityScore, defaults: ["siglip2-quality"], otherTiers: all,
                      params: [], inputs: ["image": true]),
    ]

    /// Fill with a prompt, by quality tier: the edit models that paint it, most preferred first.
    static let generativeFill: [QualityTier: [String]] = [
        .draft: ["klein-4b"], .standard: ["klein-4b", "qwen-image-edit"], .best: ["qwen-image-edit", "klein-4b"],
    ]

    /// Models not offered at all, with why: ones that take the engine process down (a Metal fault kills every
    /// client's jobs, not just the one that hit it). Lift an entry when its package is fixed.
    static let quarantined: [String: String] = [
        "qwen-image-flash": "intermittent Metal fault (kIOGPUCommandBufferCallbackErrorInvalidResource) that kills the "
            + "engine after 2–8 runs in one process (R1b, 2026-10-10; AB-T-0214)",
    ]

    /// Upscale of `content: drawn`: NERVE at every tier.
    static let drawnUpscale = ["nerve-upscale"]

    /// `restore`'s `kind` → the models that do it at `tier`, most preferred first (when the request named none).
    /// Measured (R1b, docs/TIERS.md): denoise at σ 25, SCUNet 33.3 dB / NAFNet 32.6 / DRUNet 27.7 / Restormer-real
    /// 27.0, NAFNet ~50× faster than SCUNet; SCUNet also leads on real noise (NIND). DRUNet needs a noise level the
    /// vocabulary doesn't carry, so it's left to requests that name it. Deblur: Restormer-defocus improved SSIM on
    /// blur where motion didn't; both beat their own benchmarks' baselines (+2.09 / +1.29 dB).
    static func restoreModels(kind: String, tier: QualityTier) -> [String] {
        switch kind {
        case "general": ["nafnet-restore"]
        case "denoise": tier == .draft ? ["nafnet-restore", "scunet-denoise"] : ["scunet-denoise", "nafnet-restore", "restormer-denoise"]
        case "deblur": ["restormer-defocus", "restormer-motion", "nafnet-restore"]
        case "faces": ["gfpgan-face", "restoreformer-face"]
        default: []
        }
    }
}
