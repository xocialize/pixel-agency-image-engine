import Foundation
import ImageServerAPI
import MESCore
import MESEngineKit
import MESEngineUI
import PixelAgencyImageEngine

/// The Image Engine as its console sees it: the server's operator API for the queue, and the runtime's catalog for the
/// model cards, each with what it does when it's on (`ImageNormalizer.catalogDescriptors`) and its state on this Mac.
struct ImageConsoleBackend: EngineConsoleBackend {
    let server: MESEngineServer
    let normalizer: ImageNormalizer
    let enablement: ModelEnablement

    func activity() -> AsyncStream<EngineActivity> { server.activity() }

    func cancel(job id: String) async throws { try await server.cancel(job: id) }

    func operations() async -> [Descriptor] { await server.operations() ?? [] }

    func models() async -> [EngineModel] {
        async let infos = normalizer.models()
        async let catalog = normalizer.catalogDescriptors()
        async let live = operations()
        let (models, all, served) = await (infos, catalog, live)
        let order = Dictionary(all.enumerated().map { ($1.operation, $0) }, uniquingKeysWith: { a, _ in a })
        let deep = normalizer.options.sixteenBitUpscalers.union(normalizer.options.sixteenBitRestorers)

        var catalogDefaults: Set<String> = []
        let cards = models.compactMap { info -> EngineModel? in
            let id = info.id.rawValue
            let offers = all.compactMap { d in d.models.first { $0.id == id }.map { (d.operation, $0) } }
            let unavailable = info.state.problem ?? ImageNormalizer.quarantined[id]
            // A model that serves no operation (a helper inside another one) has nothing to switch; the prompt enhancer's
            // backbone has, since turning it off stops prompt enhancement.
            let backbone = id == PromptEnhance.backboneID
            guard !offers.isEmpty || unavailable != nil || backbone else { return nil }
            let optIn = ImageNormalizer.isOptIn(info)
            let enabled = enablement.isEnabled(id, optIn: optIn)
            // On, a model is the default where the served operations say so (it may have taken over from one that's
            // off); off, where it would be once on.
            let roles = offers.map { operation, offer in
                EngineModel.Role(operation: operation, qualityTiers: offer.qualityTiers,
                                 isDefault: enabled ? served.first { $0.operation == operation }?.models
                                     .contains { $0.id == id && $0.isDefault == true } ?? false : offer.isDefault == true,
                                 namedOnly: offer.namedOnly == true)
            }
            let offer = offers.first?.1
            let catalogDefault = offers.contains { $0.1.isDefault == true }
            var tags: [String] = []
            if info.maturity == .wip { tags.append("Work in progress") }
            if deep.contains(id) { tags.append("16-bit") }
            // How the model wants its prompts (AB-D-0155): its enhancer's policy.
            if let prompting = PromptEnhance.prompting(forModel: id) { tags.append("Prompt enhancement: \(prompting.policy)") }
            if backbone { tags.append("Prompt enhancer") }
            let card = EngineModel(
                id: id, title: info.displayName, summary: info.summary,
                license: offer?.license ?? ImageNormalizer.license(info), optIn: optIn,
                enabled: enabled, acceptedAt: enablement.acceptedAt(id), roles: roles,
                notes: backbone ? PromptEnhance.backboneNote : offer?.notes,
                memoryClass: offer?.memoryClass ?? ImageNormalizer.memoryClass(info.footprintBytes), speedClass: offer?.speedClass,
                footprintBytes: info.state.residentBytes ?? info.footprintBytes,
                install: info.state.downloaded ? .downloaded(bytes: nil) : .notDownloaded(bytes: nil),
                resident: info.state.resident, unavailable: unavailable,
                source: info.sourceRepo.isEmpty ? nil : info.sourceRepo,
                sourceURL: info.sourceRepo.isEmpty ? nil : URL(string: "https://huggingface.co/\(info.sourceRepo)"),
                tags: tags)
            if catalogDefault { catalogDefaults.insert(id) }
            return card
        }
        // A stable order, so a card stays put when it's switched: by the first operation it serves, the models that are
        // defaults with everything on first.
        return cards.sorted { a, b in
            func rank(_ m: EngineModel) -> (Int, Int, Int, String) {
                (m.unavailable == nil ? 0 : 1, m.roles.map { order[$0.operation] ?? 99 }.min() ?? 99,
                 catalogDefaults.contains(m.id) ? 0 : 1, m.title)
            }
            return rank(a) < rank(b)
        }
    }

    func setEnabled(_ enabled: Bool, model id: String) async throws {
        guard let info = await normalizer.models().first(where: { $0.id.rawValue == id }) else {
            throw MESError(.modelUnavailable, "No model \(id) on this engine.")
        }
        try enablement.set(id, enabled: enabled, optIn: ImageNormalizer.isOptIn(info))
        await server.reloadDescriptors()
    }

    func download(model id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        // One heavy model at a time (ENG-3): a download loads the model too, so it waits for an idle engine.
        if let running = await server.health()?.running {
            throw MESError(.busy, "The engine is running a job (\(running)). Download when the queue is empty, or let the "
                + "first job that needs the model download it.")
        }
        try await normalizer.prefetch(id, progress: progress)
    }

    func unload(model id: String) async { await normalizer.unload(id) }
}
