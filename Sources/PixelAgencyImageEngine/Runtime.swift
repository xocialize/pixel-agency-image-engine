import Foundation
import ImageServerModels

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

    /// The models folder every Pixel Agency engine and ML[X] app shares (Engines-PRD ENG-13), so a model downloaded
    /// once serves them all. `MLXIMG_MODEL_STORE` overrides it.
    public nonisolated static var defaultModelStore: URL {
        if let override = ProcessInfo.processInfo.environment["MLXIMG_MODEL_STORE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MLXEngine/Models", isDirectory: true)
    }

    /// Registers every catalog model with the runtime (nothing is downloaded or loaded until a job needs it).
    ///
    /// The router may run restricted models: what's offered is the normalizer's call (`allowResearch`), and an
    /// offered research model is `named_only`, so it runs only when a request names it.
    public static func start(modelStore: URL = defaultModelStore, options: ImageNormalizer.Options = .init()) async -> ImageRuntime {
        try? FileManager.default.createDirectory(at: modelStore, withIntermediateDirectories: true)
        let (service, forge) = await ImageEngineService.bootstrap(storeRoot: modelStore, catalog: ModelCatalog.all(),
                                                                  allowRestricted: true)
        let normalizer = ImageNormalizer(directory: service, runner: EngineRunner(engine: service.engine), options: options)
        return ImageRuntime(normalizer: normalizer, service: service, forge: forge)
    }
}
