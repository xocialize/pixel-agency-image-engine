import Foundation
import ImageServerAPI
import ImageServerCatalog
import ImageServerModels
import MESEngineCore
@testable import PixelAgencyImageEngine
import Testing

// AB-T-0221: on a machine without local snapshots, Z-Image Turbo's first download named a repo that was never
// published, and the engine failed image.generate with a bare `httpStatus(404)`. This lists and sizes, on the hub,
// everything each model the engine offers by default would download into an empty models folder (nothing is
// downloaded). Needs the network; skipped when the hub can't be reached.
@Suite("Default offers download from the hub", .serialized)
struct HubWeightTests {
    /// Offers whose packages download their own weights inside `load()` and declare no weight sources, so nothing
    /// can check them before they run (mlx-image-runtime's `DownloadCheck.opaque`). Empty since NAFNet, DDColor and
    /// LaMa declared theirs (AB-T-0222); a new one has to be added here on purpose.
    static let selfFetching: Set<String> = []

    @Test("Every model offered by default resolves its first download on the hub",
          .enabled("needs huggingface.co") { await Hub.reachable() })
    @MainActor
    func defaultOffersResolve() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("pa-hub-weights-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        // What a fresh install serves: the real catalog, no MLXIMG_WEIGHTS_ROOT, no snapshot overrides, no research.
        let runtime = await ImageRuntime.start(modelStore: store, catalog: ModelCatalog.all(environment: [:]))
        let offered = Set(await runtime.normalizer.descriptors().flatMap { $0.models.map(\.id) }).sorted()
        #expect(offered.contains("z-image-turbo"))

        var checked: [String] = [], present: [String] = [], opaque: Set<String> = []
        for id in offered {
            switch await runtime.service.downloadCheck(ModelID(id)) {
            case .pending(let download):
                #expect(download.unresolved.isEmpty, """
                    \(id): the hub can't serve \(download.unresolved.map(\.label).joined(separator: ", ")) \
                    (no listing, or nothing matching the source's globs)
                    """)
                checked.append(id)
            case .present: present.append(id)
            case .opaque: opaque.insert(id)
            case nil: Issue.record("\(id) is offered but not registered")
            }
        }
        #expect(checked.contains("z-image-turbo"), "the AB-T-0221 regression is checked")
        #expect(opaque.subtracting(Self.selfFetching).isEmpty,
                "fetch weights nothing can check: \(opaque.subtracting(Self.selfFetching).sorted())")
        print("hub weights: \(checked.count) of \(offered.count) default offers checked on the hub; no download: "
              + "\(present.joined(separator: ", ")); unseen self-fetchers: \(opaque.sorted().joined(separator: ", "))")
    }
}

enum Hub {
    /// Any HTTP answer from the hub counts; a transport error doesn't.
    static func reachable() async -> Bool {
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/models/mlx-community/Z-Image-Turbo-bf16")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        return (try? await URLSession.shared.data(for: request).1) is HTTPURLResponse
    }
}
