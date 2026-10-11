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
    /// Capabilities whose models are offered only when listed here (erase offers only the edit models that remove by
    /// name, not every editor).
    let restricted: [Capability: Set<String>]

    /// Whether a model with `capabilities` is offered for this operation.
    func serves(_ id: String, capabilities modelCapabilities: [Capability]) -> Bool {
        modelCapabilities.contains { capabilities.contains($0) && (restricted[$0]?.contains(id) ?? true) }
    }

    /// The models to prefer at `tier` when a request names none: `defaults` in order, those that serve the tier.
    func preferred(at tier: QualityTier) -> [String] {
        defaults.filter { (tiers[$0] ?? otherTiers).contains(tier) }
    }

    init(_ operation: String, _ capabilities: Capability..., tiers: [String: [QualityTier]] = [:], defaults: [String] = [],
         otherTiers: [QualityTier] = [.standard], params: [String], narrowed: [String: JSONValue] = [:],
         inputs: [String: Bool], helpers: [Capability] = [], restricted: [Capability: Set<String>] = [:]) {
        self.operation = operation; self.capabilities = capabilities; self.tiers = tiers; self.defaults = defaults
        self.otherTiers = otherTiers; self.params = params; self.narrowed = narrowed; self.inputs = inputs; self.helpers = helpers
        self.restricted = restricted
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

    /// `image.upscale`'s `output` when a model it offers keeps 16 bits (G-6, AB-A-0158): TIFF too, and `bit_depth: 16` as
    /// PNG or TIFF. A 16-bit request runs only on those models (`ImageNormalizer.validate` refuses it otherwise with 422
    /// `unsupported_parameter`, Image §1.2), so the description names them.
    static func deepOutput(models: [String]) -> JSONValue {
        [
            "type": "object", "additionalProperties": false,
            "properties": [
                "media_type": ["enum": ["image/png", "image/jpeg", "image/tiff"]],
                "bit_depth": ["enum": [8, 16],
                              "description": .string("16 (PNG or TIFF) keeps a 16-bit image's depth through the model; it runs on "
                                  + models.joined(separator: ", ") + ".")],
            ],
        ]
    }

    /// Where `bit_depth: 16` can't run, stated in `image.upscale`'s schema (Base §6 rule 4: limits in the descriptor, not
    /// found by failure), so a client checks a request before sending it. Each entry pins `output.bit_depth` to 8:
    /// - for a `quality` with no 16-bit model (an absent quality is standard);
    /// - for drawn content at a quality whose drawn route (`drawnUpscale`) has no 16-bit model.
    /// The failing path is `output.bit_depth`, so a refusal is 422 `unsupported_parameter` (Image §1.2).
    static func sixteenBitRules(deepTiers: Set<QualityTier>, drawnDeepTiers: Set<QualityTier>, params: [String]) -> [JSONValue] {
        let eightBits: JSONValue = ["properties": ["output": ["properties": ["bit_depth": ["enum": [8]]]]]]
        let withoutQuality: JSONValue = .array(params.filter { $0 != "quality" }.map { .string($0) })
        func names(_ tiers: [QualityTier]) -> JSONValue { .array(tiers.map { .string($0.rawValue) }) }
        let plain = QualityTier.allCases.filter { !deepTiers.contains($0) }
        let drawn = QualityTier.allCases.filter { !drawnDeepTiers.contains($0) }
        var rules: [JSONValue] = []
        if !plain.isEmpty {
            rules.append(["if": ["properties": ["quality": ["enum": names(plain)]], "required": ["quality"]], "then": eightBits])
        }
        if plain.contains(.standard) {
            rules.append(["if": ["propertyNames": ["enum": withoutQuality]], "then": eightBits])
        }
        if !drawn.isEmpty {
            rules.append(["if": ["properties": ["content": ["const": "drawn"], "quality": ["enum": names(drawn)]],
                                 "required": ["content", "quality"]], "then": eightBits])
        }
        if drawn.contains(.standard) {
            rules.append(["if": ["properties": ["content": ["const": "drawn"]], "required": ["content"],
                                 "propertyNames": ["enum": withoutQuality]], "then": eightBits])
        }
        return rules
    }

    static let specs: [OperationSpec] = [
        // Measured (R1b, docs/TIERS.md): Z-Image Turbo leads on both prompt sets (IQA 0.915 / 0.903, hard-prompt recall
        // 0.94, text spelled right) at 13.7 s; Z-Image (28 steps, 70 s) scored lower on both, so it isn't "best".
        OperationSpec("image.generate", .textToImage,
                      tiers: ["klein-4b": [.draft], "z-image-turbo": [.standard, .best], "z-image": [.standard],
                              "qwen-image-flash": [.standard, .best]],
                      defaults: ["z-image-turbo", "klein-4b", "z-image"],
                      params: ["negative_prompt", "size", "aspect", "megapixels", "quality", "seed", "count", "output"],
                      narrowed: ["count": ["type": "integer", "minimum": 1, "maximum": 4, "default": 1], "output": output],
                      inputs: ["prompt": true]),
        // Provisional (R1b, 2 photos): Klein 4B at every tier. Qwen-Image-Edit 2511 took ~5.2 min per 1024² job (Klein
        // 15 s), barely applied one of two edits, and kept the extend marker on both photos. Offered, not a default.
        OperationSpec("image.edit", .imageEdit,
                      tiers: ["klein-4b": all, "qwen-image-edit": [.best]],
                      defaults: ["klein-4b", "qwen-image-edit"],
                      params: ["strength", "quality", "seed", "size", "output"], narrowed: ["output": output],
                      inputs: ["images": true, "instruction": true]),
        // Fill: LaMa without a prompt; with one, an edit model paints it in (`ImageNormalizer.defaultModel`).
        OperationSpec("image.fill", .imageInpaint, .imageEdit,
                      tiers: ["lama-inpaint": all, "klein-4b": all, "qwen-image-edit": [.best]],
                      defaults: ["lama-inpaint"],
                      params: ["quality", "seed", "output"], narrowed: ["output": output],
                      inputs: ["image": true, "mask": true, "prompt": false]),
        // Erase is prompt-less removal (IMG-5): MI-GAN at draft, LaMa at standard, and at best Mage-Flow Edit Turbo by name
        // (`eraseByTier`; `RunPlan.eraseByName`: Mage-VL names the object, Mage removes it, composited through the mask).
        // Measured (R2, docs/TIERS.md, removal gate subset S): Mage +3.5 dB in the hole over LaMa with object masks, and
        // the lowest shadow ring with effect masks, at 4.1 s against 0.42 s.
        OperationSpec("image.erase", .imageInpaint, .imageEdit,
                      tiers: ["lama-inpaint": all, "mage-flow-edit-turbo": [.best]],
                      defaults: ["lama-inpaint"],
                      params: ["quality", "output"], narrowed: ["output": output],
                      inputs: ["image": true, "mask": true], helpers: [.imageAnalysis],
                      restricted: [.imageEdit: namedRemovers]),
        // Extend is inpainting on a padded canvas (IMG-5): LaMa (MI-GAN at draft). Measured (R1b): fp32 LaMa continues
        // busy photos coherently every time; Klein, shown the border to paint, rendered it as a purple surface or left
        // it dark on 2 of 4 tries. With a prompt, an edit model paints the border (guarded, LaMa as fallback).
        OperationSpec("image.extend", .imageInpaint, .imageEdit,
                      tiers: ["lama-inpaint": all, "klein-4b": all, "qwen-image-edit": [.best]],
                      defaults: ["lama-inpaint", "klein-4b", "qwen-image-edit"],
                      params: ["canvas", "quality", "seed", "output"], narrowed: ["output": output],
                      inputs: ["image": true, "prompt": false]),
        // Measured (R1b, docs/TIERS.md): photos, NERVE → RealPLKSR → HEART (best PSNR on 12 of 12 Commons rungs).
        // SeedVR2 measured worst of the learned models on photos. The generative stills routes, VOSR2 and Nacre, run
        // behind ForgeCore's text-legibility guard (the runtime's enhancer, AB-D-0111): offered at best, by name,
        // never a default. Drawn content (`content: drawn`) goes by `drawnUpscale`: NERVE at draft and standard, HEART at
        // best (the G-4 drawn ladder, AB-R-0486 / AB-D-0124).
        OperationSpec("image.upscale", .imageUpscale,
                      tiers: ["nerve-upscale": all, "realplksr-upscale": [.standard], "heart-upscale": [.best],
                              "seedvr2-upscale": [.best], "nacre-upscale": [.best], "vosr2-upscale": [.best]],
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

    /// Edit models that erase by name (`RunPlan.eraseByName`): the removal gate measured Mage's (AB-R-0464).
    static let namedRemovers: Set<String> = ["mage-flow-edit-turbo"]

    /// Erase, by quality tier, when the request names no model: the named remover at best (R2, TIERS.md). LaMa keeps
    /// every tier for requests that name it, so "LaMa at best" stays LaMa.
    static let eraseByTier: [QualityTier: [String]] = [.best: ["mage-flow-edit-turbo"]]

    /// Fill with a prompt, by quality tier: the edit models that paint it, most preferred first.
    static let generativeFill: [QualityTier: [String]] = [
        .draft: ["klein-4b"], .standard: ["klein-4b", "qwen-image-edit"], .best: ["klein-4b", "qwen-image-edit"],
    ]

    /// Models not offered at all, with why: ones that take the engine process down (a Metal fault kills every
    /// client's jobs, not just the one that hit it). Lift an entry when its package is fixed.
    static let quarantined: [String: String] = [
        "qwen-image-flash": "intermittent Metal fault (kIOGPUCommandBufferCallbackErrorInvalidResource) that kills the "
            + "engine after 2–8 runs in one process (R1b, 2026-10-10; AB-T-0214)",
    ]

    /// Upscale of `content: drawn`, by quality tier, most preferred first. Measured on 75 drawn images (line art, text,
    /// UI, CG / anime) at ×4 and ×2 (AB-R-0486): HEART beats NERVE on line, UI and CG at ×4 and on line, text and CG
    /// at ×2 (SSIMULACRA2 +8 to +14), losing nowhere; NERVE ties RealPLKSR at a fifth of its cost. The price at ×4 on
    /// text-dense images: HEART turns more legible words illegible (110 vs 61 of 775).
    static let drawnUpscale: [QualityTier: [String]] = [
        .draft: ["nerve-upscale"], .standard: ["nerve-upscale"], .best: ["heart-upscale", "nerve-upscale"],
    ]

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
