import ForgeCore
import Foundation
import ImageServerAPI
import ImageServerModels
import MLXServeCore
import MLXToolKit

/// The model runtime behind the normalizer: ML[X] Image Server's engine half (ForgeCore's tiers and the generative
/// packages, one heavy model resident at a time under MLXServe's memory governor). Keep it alive while the engine
/// serves: it owns the ForgeCore service the packages were registered with.
@MainActor
public final class ImageRuntime {
    public nonisolated let normalizer: ImageNormalizer
    public nonisolated let service: ImageEngineService
    private let forge: Any

    private init(normalizer: ImageNormalizer, service: ImageEngineService, forge: Any) {
        self.normalizer = normalizer; self.service = service; self.forge = forge
    }

    /// The engine's version, as `GET {path}` and provenance report it.
    public nonisolated static let version = "0.9.1"

    /// A stable engine id (Base §4), made once and kept with the state.
    public nonisolated static func engineID(in state: URL) throws -> String {
        let file = state.appendingPathComponent("engine-id")
        if let id = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        let id = "eng_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
        try id.write(to: file, atomically: true, encoding: .utf8)
        return id
    }

    /// The models folder every Pixel Agency engine and ML[X] app shares (Engines-PRD ENG-13), so a model downloaded
    /// once serves them all. `MLXIMG_MODEL_STORE` overrides it.
    public nonisolated static var defaultModelStore: URL {
        if let override = ProcessInfo.processInfo.environment["MLXIMG_MODEL_STORE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MLXEngine/Models", isDirectory: true)
    }

    /// Registers `catalog`'s models with the runtime (nothing is downloaded or loaded until a job needs it). The
    /// headless engine passes `ModelCatalog.all()` (ImageServerCatalog: every package) and the prompt enhancer's backbones
    /// (`PromptBackbones.entries()`); an app that embeds only ForgeCore's tiers passes those (`ModelCatalog.processing()`,
    /// or a subset), and links no generative package. Without a backbone, prompts go as typed.
    ///
    /// The router may run restricted models: what's offered is the normalizer's call (`allowResearch`), and an
    /// offered research model is `named_only`, so it runs only when a request names it.
    ///
    /// `adapters` is the adapter catalog (`ModelCatalog.adapters()`, AB-D-0155): registered after the packages, so each
    /// model lists the adapters it takes and its offers list them (`ModelOffer.adapters`). Their files download into the models
    /// folder when a job first names them, pinned and hash-checked.
    public static func start(modelStore: URL = defaultModelStore, catalog: [CatalogEntry], adapters: [AdapterEntry] = [],
                             options: ImageNormalizer.Options = .init()) async -> ImageRuntime {
        try? FileManager.default.createDirectory(at: modelStore, withIntermediateDirectories: true)
        let (service, forge) = await ImageEngineService.bootstrap(storeRoot: modelStore, catalog: catalog,
                                                                  allowRestricted: true, adapters: adapters)
        // ForgeCore's still enhancer, as ML[X] Image Server runs it: a generative upscale (VOSR2, Nacre) runs behind
        // the text-legibility guard, never bare (AB-D-0111), and reports what ran.
        let enhancer = EngineImageEnhancer(service: forge)
        var options = options
        options.sixteenBitUpscalers.formUnion(await sixteenBitModels(service, .imageUpscale))
        options.sixteenBitRestorers.formUnion(await sixteenBitModels(service, .imageRestore))
        options.tiledEditors.formUnion(await tiledEditors(service))
        let runner = EngineRunner(engine: service.engine, enhancer: enhancer)
        if options.creativeUnavailable == nil { options.creativeUnavailable = await creativeUnavailable(service, runner: runner) }
        let normalizer = ImageNormalizer(directory: service, runner: runner, textRunner: EngineTextRunner(engine: service.engine),
                                         options: options)
        return ImageRuntime(normalizer: normalizer, service: service, forge: forge)
    }

    /// The registered edit models whose package takes a batch of tiles in one call: its `imageEdit` surface declares the
    /// `tiles` mode (mage-flow-swift ≥ 0.11.0). Read from the manifests, like `sixteenBitModels`.
    static func tiledEditors(_ service: ImageEngineService) async -> Set<String> {
        var ids: Set<String> = []
        for model in await service.registeredModels() where model.capabilities.contains(.imageEdit) {
            guard let manifest = await service.engine.manifest(for: PackageID(model.packageID)) else { continue }
            if manifest.surfaces.contains(where: { $0.capability == .imageEdit && $0.supportedModes.contains(Mode(rawValue: Creative.tilesMode)) }) {
                ids.insert(model.id.rawValue)
            }
        }
        return ids
    }

    /// Whether the creative upscale's models fit this Mac, asked at start with nothing loaded, so each model's projected
    /// peak is its own: its weights at the residency the runtime chose for this Mac (below 32 GB Mage-Flow's conditioner
    /// and DiT take turns, about 10 GB) plus its activation, against the engine's budget.
    static func creativeUnavailable(_ service: ImageEngineService, runner: EngineRunner) async -> String? {
        func fit(_ capability: Capability, _ id: String) async -> MemoryFit? {
            guard let route = try? await service.route(capability, model: ModelID(id)) else { return nil }
            return await runner.machineFit(route)
        }
        return Creative.unavailableReason(editor: await fit(.imageEdit, Creative.editor),
                                          realistic: await fit(.imageUpscale, Creative.realistic))
    }

    /// The registered `capability` models whose package keeps 16 bits end to end: its surface for that capability
    /// declares `.rawRGBA16` (MLXToolKit contract 1.52.0; upscale AB-A-0158, restore AB-T-0230). Read from the manifests the
    /// engine registered, so a package release that adopts the boundary is offered at 16 bits with no change here.
    static func sixteenBitModels(_ service: ImageEngineService, _ capability: Capability) async -> Set<String> {
        var ids: Set<String> = []
        for model in await service.registeredModels() where model.capabilities.contains(capability) {
            guard let manifest = await service.engine.manifest(for: PackageID(model.packageID)) else { continue }
            if manifest.surfaces.contains(where: { $0.capability == capability && $0.acceptsRawRGBA16 }) {
                ids.insert(model.id.rawValue)
            }
        }
        return ids
    }
}

/// Runs a chat request on a text model the runtime registered: the prompt enhancer's backbone. The runtime's `ModelRunner`
/// maps image capabilities only, so `.llm` goes to the engine directly. Prepare the route first (`RunPlan.route`).
public protocol TextRunner: Sendable {
    func generate(_ request: LLMRequest, on route: RoutedModel) async throws -> String
}

/// `TextRunner` over MLXServe. Awaits the engine directly, so cancelling the job reaches the package (AB-L-0052).
public struct EngineTextRunner: TextRunner {
    public let engine: MLXServeEngine

    public init(engine: MLXServeEngine) { self.engine = engine }

    public func generate(_ request: LLMRequest, on route: RoutedModel) async throws -> String {
        let response = try await engine.run(request, package: PackageID(route.packageID))
        guard let text = response as? LLMResponse else {
            throw NormalizerError.engine("\(route.id.rawValue) returned \(type(of: response)), not text.")
        }
        return text.text
    }
}
