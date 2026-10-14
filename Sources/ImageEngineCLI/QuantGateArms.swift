import Foundation
import ImageServerAPI
import ImageServerModels
import MLXKlein
import MLXSenseNovaU1
import MLXServeCore
import MLXToolKit

/// The Generative Fill quant gate's arms (AB-A-0178), offered by name only with `--quant-gate-arms`: the int4 tiers
/// AB-D-0141 ships, Klein int8 evicted (the 16 GB alternative) and the 768² references, so each pair runs through the
/// engine's own fill route (marker, guard, harmonize, feather) exactly as the bake-off's arms did (AB-R-0534). The
/// catalog's `klein-4b` (bf16, 1024²) and `sensenova-u1-fast` (8step-v2-8bit) are the other references. The fill
/// route renders the whole canvas at the model's envelope, so a 768² envelope is the 768² fill window.
enum QuantGateArms {
    static let kleinWindow = SizeEnvelope(maxPixels: 768 * 768, multipleOf: 16, maxInputs: 4)

    static func entries(environment: [String: String] = ProcessInfo.processInfo.environment) -> [CatalogEntry] {
        // The 8step-v2-4bit artifact (the bake-off's memory arm); the model store has only the 8-bit tier.
        let senseNova4 = environment["QUANT_GATE_SENSENOVA_4BIT"]
            ?? "/Volumes/Satechi/Development/mlxengine-image/weights/artifacts/SenseNova-U1.5-8B-MoT-8step-v2-4bit"
        return [
            klein(id: "klein-4b-768", name: "FLUX.2 Klein 4B (bf16, 768² window)", quant: .bf16, evict: false),
            klein(id: "klein-4b-int4-evict-768", name: "FLUX.2 Klein 4B (int4, encoder evicted, 768² window)", quant: .int4, evict: true),
            klein(id: "klein-4b-int8-evict-768", name: "FLUX.2 Klein 4B (int8, encoder evicted, 768² window)", quant: .int8, evict: true),
            senseNova(.fast4V2, id: "sensenova-u1-fast-4bit", name: "SenseNova-U1.5 8-step (int4)", snapshot: senseNova4, envelope: nil),
            senseNova(.fast4V2, id: "sensenova-u1-fast-4bit-768", name: "SenseNova-U1.5 8-step (int4, 768² window)", snapshot: senseNova4,
                      envelope: 768 * 768),
            senseNova(.fast8V2, id: "sensenova-u1-fast-768", name: "SenseNova-U1.5 8-step (int8, 768² window)", snapshot: "",
                      envelope: 768 * 768),
        ]
    }

    static func klein(id: String, name: String, quant: Quant, evict: Bool) -> CatalogEntry {
        let packageID = PackageID("imgsrv.\(id)")
        let configuration = KleinConfiguration.turbo(quant: quant, evictEncoder: evict)
        return CatalogEntry(
            id: ModelID(id), packageID: packageID, displayName: name, summary: "Quant-gate arm (AB-A-0178).",
            capabilities: [.imageEdit], maturity: .prod, envelope: kleinWindow,
            defaults: GenerationDefaults(steps: 4, guidance: 1.0), quant: quant,
            source: .package(manifest: Klein4BT2IPackage.manifest, register: {
                try await $0.register(Klein4BT2IPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    static func senseNova(_ variant: SenseNovaVariant, id: String, name: String, snapshot: String, envelope pixels: Int?) -> CatalogEntry {
        let packageID = PackageID("imgsrv.\(id)")
        let configuration = SenseNovaU1Configuration(variant: variant, snapshotPath: snapshot)
        return CatalogEntry(
            id: ModelID(id), packageID: packageID, displayName: name, summary: "Quant-gate arm (AB-A-0178).",
            capabilities: [.imageEdit], maturity: .prod,
            envelope: SizeEnvelope(maxPixels: pixels ?? 2048 * 2048, multipleOf: 32, maxInputs: 1),
            defaults: GenerationDefaults(steps: 8, guidance: 1.0), quant: variant.quant,
            source: .package(manifest: SenseNovaU1Package.manifest, register: {
                try await $0.register(SenseNovaU1Package.registration, configuration: configuration, id: packageID)
            }))
    }
}
