import ArgumentParser
import Foundation
import ImageServerCatalog
import ImageServerModels
import MESEngineKit
import PixelAgencyImageEngine

/// The Pixel Agency Image Engine, headless: MES Base 0.1 with the Image profile, over the local model runtime.
@main
struct ImageEngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pixel-agency-image-engine",
        abstract: "The Pixel Agency Image Engine: MES Image profile over local MLX models.",
        discussion: """
            Open mode (default) serves HTTP on 127.0.0.1 to this Mac only. Paired mode serves TLS on every interface; \
            clients pair with a 6-digit code you confirm here (--approve prompt) or are pre-approved (--approve auto).

            Models download to the shared models folder on first use. Research-licensed and work-in-progress models \
            are offered only with --allow-research (you, the operator, accept their terms), and then only to requests \
            that name them.
            """)

    @Option(help: "Port (0 = any free port).") var port = 17610
    @Flag(help: "Paired mode: TLS, pairing and bearer tokens, for clients on other machines.") var paired = false
    @Option(help: "Bind address (paired mode defaults to 0.0.0.0).") var host: String?
    @Option(help: "Pairing approval: prompt (ask here) or auto (approve every request).") var approve = "prompt"
    @Option(help: "The models folder.") var store: String?
    @Flag(help: "Offer research and work-in-progress models, named-only. You accept their licences' terms (each offer links them).")
    var allowResearch = false
    @Option(help: "Job spool (wiped at start).") var spool: String?
    @Option(help: "State: engine id, TLS identity, pairings.") var state: String?
    @Option(help: "Seconds outputs are kept for collection.") var ttl = 3600
    @Flag(help: "Don't advertise over DNS-SD.") var noAdvertise = false

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered, so the listening line shows up when piped
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pixel Agency/Image Engine", isDirectory: true)
        let stateDir = state.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? support.appendingPathComponent("State")
        let spoolDir = spool.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pixel-agency-image-engine-spool")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        let modelStore = store.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ImageRuntime.defaultModelStore
        print("Registering models (models folder: \(modelStore.path))…")
        let runtime = await ImageRuntime.start(modelStore: modelStore, catalog: ModelCatalog.all(),
                                               options: .init(allowResearch: allowResearch))
        for (model, reason) in ImageNormalizer.quarantined.sorted(by: { $0.key < $1.key }) {
            print("not offering \(model): \(reason)")
        }
        let offered = await runtime.normalizer.descriptors()
        print("\(offered.count) operations, \(Set(offered.flatMap { $0.models.map(\.id) }).count) models offered"
              + (allowResearch ? " (research models named-only)" : ""))
        let deep = runtime.normalizer.options.sixteenBitUpscalers.sorted()
        print(deep.isEmpty ? "upscale runs at 8 bits" : "16-bit upscale (output.bit_depth 16): \(deep.joined(separator: ", "))")
        let deepRestore = runtime.normalizer.options.sixteenBitRestorers.sorted()
        print(deepRestore.isEmpty ? "restore runs at 8 bits"
              : "16-bit restore (output.bit_depth 16): \(deepRestore.joined(separator: ", "))")

        var config = EngineConfiguration(id: try Self.engineID(in: stateDir), name: "Pixel Agency Image Engine",
                                         implementationName: "pixel-agency-image-engine", implementationVersion: "0.2.9",
                                         spoolDirectory: spoolDir)
        config.stateDirectory = stateDir
        config.port = port
        config.outputsTTLSeconds = ttl
        config.advertise = !noAdvertise
        config.concurrency = 1                       // one heavy model slot (ENG-3)
        if paired {
            config.mode = .paired
            config.host = host ?? "0.0.0.0"
            if approve == "auto" {
                config.pairingApproval = EngineConfiguration.approveAll
            } else {
                config.pairingApproval = { @Sendable (prompt: PairingPrompt) async -> Bool in
                    print("Pairing request from “\(prompt.clientName)” (\(prompt.clientID)). Its screen should show \(prompt.code). Approve? [y/N] ")
                    let answer: String? = await Task.detached { readLine() }.value
                    return answer?.lowercased().hasPrefix("y") == true
                }
            }
        } else if let host {
            config.host = host
        }
        let server = MESEngineServer(engine: runtime.normalizer, configuration: config)
        let (scheme, bindHost, basePath) = (paired ? "https" : "http", config.host, config.basePath)
        let note = paired ? "paired mode, approve: \(approve)" : "open mode, loopback only"
        defer { withExtendedLifetime(runtime) {} }   // the runtime owns the registered packages
        try await server.run { port in
            print("pixel-agency-image-engine listening on \(scheme)://\(bindHost):\(port)\(basePath) (\(note))")
        }
    }

    /// A stable engine id (Base §4), made once and kept with the state.
    static func engineID(in state: URL) throws -> String {
        let file = state.appendingPathComponent("engine-id")
        if let id = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        let id = "eng_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
        try id.write(to: file, atomically: true, encoding: .utf8)
        return id
    }
}
