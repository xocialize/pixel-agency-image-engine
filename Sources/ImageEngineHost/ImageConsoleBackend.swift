import Foundation
import ImageServerAPI
import ImageServerModels
import MESCore
import MESEngineKit
import MESEngineUI
import PixelAgencyImageEngine

/// The Image Engine as its console sees it: the server's operator API for the queue, and the runtime's catalog for the
/// model cards, each with what it does when it's on (`ImageNormalizer.catalogDescriptors`) and its state on this Mac.
///
/// Adapters (AB-D-0155): a model's card lists the adapters it takes, and each adapter has a card of its own after its
/// model's, keyed `adapter:<id>` in the enabled set, so the operator switches it on (accepting its terms when it's opt-in)
/// and downloads it like a model. MESEngineUI has no nested adapter cards yet.
struct ImageConsoleBackend: EngineConsoleBackend {
    let server: MESEngineServer
    let normalizer: ImageNormalizer
    /// The runtime, for adapter files: on disk or not, and fetched now.
    let service: ImageEngineService
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
            // The adapters it takes, by title, with how many are on.
            let adapters = info.adapters.filter { !Adapters.isRefused($0) }
            // The offer's own line about adapters names those of one operation, by id; the card names them all, by title.
            var notes = backbone ? PromptEnhance.backboneNote : offer?.notes.flatMap { notes in
                let mine = notes.range(of: "Adapters (\(Adapters.name)").map { String(notes[..<$0.lowerBound]) } ?? notes
                let trimmed = mine.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            if !adapters.isEmpty {
                let on = adapters.filter { enablement.isEnabled(Adapters.key($0.id), optIn: Adapters.isOptIn($0)) }.count
                tags.append("Adapters: \(on) of \(adapters.count) on")
                let line = "Adapters (each has its own card): " + adapters.map(\.title).joined(separator: ", ") + "."
                notes = [notes, line].compactMap { $0 }.joined(separator: " ")
            }
            let card = EngineModel(
                id: id, title: info.displayName, summary: info.summary,
                license: offer?.license ?? ImageNormalizer.license(info), optIn: optIn,
                enabled: enabled, acceptedAt: enablement.acceptedAt(id), roles: roles,
                notes: notes,
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
        // defaults with everything on first; each model's adapters right after it.
        let sorted = cards.sorted { a, b in
            func rank(_ m: EngineModel) -> (Int, Int, Int, String) {
                (m.unavailable == nil ? 0 : 1, m.roles.map { order[$0.operation] ?? 99 }.min() ?? 99,
                 catalogDefaults.contains(m.id) ? 0 : 1, m.title)
            }
            return rank(a) < rank(b)
        }
        let adapterCards = await adapterCards(models, catalog: all)
        var placed = Set<String>()
        return sorted.flatMap { card -> [EngineModel] in
            let mine = adapterCards.filter { $0.models.first == card.id && placed.insert($0.card.id).inserted }.map(\.card)
            return [card] + mine
        } + adapterCards.filter { !placed.contains($0.card.id) }.map(\.card)
    }

    /// A card per adapter, with the models that take it (most preferred first): what it is, its licence, whether it's on
    /// and downloaded, and the operations it's offered on (named-only: a request names an adapter to use it).
    func adapterCards(_ models: [ModelInfo], catalog: [Descriptor]) async -> [(card: EngineModel, models: [String])] {
        var seen = Set<String>()
        let adapters = models.flatMap(\.adapters).filter { !Adapters.isRefused($0) && seen.insert($0.id).inserted }
        var sources: [String: (repo: String, revision: String)] = [:]
        for capability in Set(Adapters.operations.values) {
            for descriptor in await service.engine.adapters(for: capability) {
                sources[descriptor.id] = (descriptor.source.repo, descriptor.source.revision)
            }
        }
        var result: [(card: EngineModel, models: [String])] = []
        for adapter in adapters {
            let takers = models.filter { $0.adapters.contains { $0.id == adapter.id } }
            let usable = takers.filter { $0.state.problem == nil && ImageNormalizer.quarantined[$0.id.rawValue] == nil }
            let key = Adapters.key(adapter.id)
            let optIn = Adapters.isOptIn(adapter)
            let roles = catalog.compactMap { d -> EngineModel.Role? in
                guard let taking = Adapters.models(taking: adapter.id, in: d) else { return nil }
                let tiers = Set(d.models.filter { taking.contains($0.id) }.flatMap(\.qualityTiers))
                return EngineModel.Role(operation: d.operation, qualityTiers: QualityTier.allCases.filter(tiers.contains),
                                        namedOnly: true)
            }
            let what = adapter.kind == "ic" ? "A reference-conditioned adapter (IC LoRA)" : "An adapter (LoRA)"
            var tags = ["Adapter"]
            if adapter.kind == "ic" { tags.append("Reference images") }
            if adapter.status != "verified" { tags.append(adapter.status.capitalized) }
            let source = sources[adapter.id]
            let downloaded = !(await service.engine.adapterNeedsDownload(id: adapter.id))
            let card = EngineModel(
                id: key, title: adapter.title,
                summary: "\(what) for \(takers.map(\.displayName).joined(separator: ", ")). Requests name it as \(adapter.id) "
                    + "in \(Adapters.name).",
                license: Adapters.license(adapter), optIn: optIn,
                enabled: enablement.isEnabled(key, optIn: optIn), acceptedAt: enablement.acceptedAt(key), roles: roles,
                notes: Adapters.notes(adapter), footprintBytes: adapter.bytes,
                install: downloaded ? .downloaded(bytes: adapter.bytes) : .notDownloaded(bytes: adapter.bytes),
                resident: false,
                unavailable: usable.isEmpty ? "Its model (\(takers.map(\.displayName).joined(separator: ", "))) isn't available on this Mac." : nil,
                source: source.map { "\($0.repo) @ \($0.revision.prefix(7))" },
                sourceURL: source.flatMap { URL(string: "https://huggingface.co/\($0.repo)/tree/\($0.revision)") },
                tags: tags)
            result.append((card, takers.map(\.id.rawValue)))
        }
        return result
    }

    func setEnabled(_ enabled: Bool, model id: String) async throws {
        if let adapterID = Adapters.adapterID(fromKey: id) {
            guard let adapter = await normalizer.models().flatMap(\.adapters).first(where: { $0.id == adapterID }) else {
                throw MESError(.modelUnavailable, "No adapter \(adapterID) on this engine.")
            }
            try enablement.set(id, enabled: enabled, optIn: Adapters.isOptIn(adapter))
            await server.reloadDescriptors()
            return
        }
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
        // An adapter's file: fetched now, pinned and hash-checked, into the models folder.
        if let adapterID = Adapters.adapterID(fromKey: id) {
            try await service.prepareAdapters([adapterID])
            progress(1)
            return
        }
        try await normalizer.prefetch(id, progress: progress)
    }

    func unload(model id: String) async {
        guard Adapters.adapterID(fromKey: id) == nil else { return }   // an adapter is applied per run, never resident
        await normalizer.unload(id)
    }
}
