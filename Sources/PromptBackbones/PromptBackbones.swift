import Foundation
import ImageServerAPI
import ImageServerModels
import MLXQwenLLM
import MLXServeCore
import MLXToolKit
import PixelAgencyImageEngine

/// The prompt enhancer's text models (AB-D-0155), as catalog entries the runtime registers beside the image models. Each
/// is a model like any other: in the operator's enabled set, on a console card, downloaded and loaded on first use, and
/// held under Residency. The engine runs them through `EngineTextRunner` (the runtime's `ModelRunner` maps image
/// capabilities only).
///
/// Its own target because it links MLX (MLXQwenLLM): the normalizer stays free of model packages, as with
/// ImageServerCatalog. The headless engine and the app pass `ModelCatalog.all() + PromptBackbones.entries()`.
public enum PromptBackbones {
    public static func entries() -> [CatalogEntry] { [qwen4B(), qwen9B()] }

    /// Qwen3.5-4B at int4 (Apache-2.0): the small text backbone the prose profiles run on. Measured in the E1 gate
    /// (AB-R-0588): 1.3–2.6 s per rewrite once loaded, 1.6 s to load, about 2 GB of weights.
    static func qwen4B() -> CatalogEntry {
        qwen(.b4, id: PromptEnhance.backboneID, displayName: "Qwen3.5 4B",
             summary: "Rewrites short prompts into the detailed captions image models are trained on, with each model's own "
                 + "profile, before the image model runs (prompt_enhance). Alibaba Qwen (Apache-2.0), int4, about 2 GB.")
    }

    /// Qwen3.5-9B at int4 (Apache-2.0): the large backbone the structured profiles run on (SenseNova U1.5's Render JSON;
    /// E3). Measured in the E3 gate: Render JSON in the vendor's exact format 16 of 16 times, 23 s per rewrite, a 7.9 GB
    /// peak; about 5.6 GB of weights.
    static func qwen9B() -> CatalogEntry {
        qwen(.b9, id: PromptEnhance.largeBackboneID, displayName: "Qwen3.5 9B",
             summary: "Writes the structured prompts some image models read, such as SenseNova U1.5's Render JSON, with "
                 + "each model's own profile, before the image model runs (prompt_enhance). Alibaba Qwen (Apache-2.0), "
                 + "int4, about 5.6 GB.")
    }

    static func qwen(_ size: QwenSize, id rawID: String, displayName: String, summary: String) -> CatalogEntry {
        let model = QwenModel(size: size, quant: .int4)
        let id = ModelID(rawID)
        let packageID = PackageID("imgsrv.\(id.rawValue)")
        let configuration = QwenLLMConfiguration(model: model)
        return CatalogEntry(
            id: id, packageID: packageID, displayName: displayName, summary: summary,
            capabilities: [.llm], maturity: .prod,
            envelope: SizeEnvelope(maxPixels: 1, multipleOf: 1, maxInputs: 0),
            defaults: GenerationDefaults(steps: nil, guidance: nil), quant: model.quant,
            source: .package(manifest: manifest(model), register: {
                try await $0.register(QwenLLMPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    /// The package's manifest for this checkpoint. QwenLLMPackage's static manifest describes its default (0.8B, 8-bit);
    /// the card's source and footprint should name what runs.
    static func manifest(_ model: QwenModel) -> PackageManifest {
        let base = QwenLLMPackage.manifest
        return PackageManifest(
            contractVersion: base.contractVersion, license: base.license,
            provenance: Provenance(sourceRepo: model.weightsRepo ?? base.provenance.sourceRepo, revision: "main",
                                   tier: base.provenance.tier),
            requirements: model.requirements, specialties: base.specialties, surfaces: base.surfaces)
    }
}
