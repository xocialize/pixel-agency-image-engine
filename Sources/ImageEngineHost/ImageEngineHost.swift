import AppKit
import Foundation
import ImageServerCatalog
import ImageServerModels
import MESCore
import MESEngineKit
import MESEngineUI
import PixelAgencyImageEngine
import PromptBackbones

/// The Image Engine as a Mac app (Engines-PRD ENG-9): the engine in process, with MESEngineUI's console window and
/// menu-bar item. It serves as the headless engine does, open mode on this Mac, and the operator chooses its enabled set
/// of models in the console instead of with `--allow-research`.
///
/// The app is a thin shell around this, sandboxed (ENG-11): `ModelsFolder` resolves the models folder the operator
/// chose (`ModelsFolderSetupWindow` asks for it first), then `ImageEngineHost(modelStore:).start()`; `showConsole()`
/// when it's reopened. The engine's state and spool live in the app's container.
@MainActor
public final class ImageEngineHost {
    public let console = EngineConsoleModel(info: EngineConsoleInfo(name: "Pixel Agency Image Engine", profile: "Image",
                                                                    symbol: "photo.stack", version: ImageRuntime.version))
    private let system = SystemMonitorStore()
    private let menuBar = MenuBarPreferences()
    private let port: Int
    private let modelStore: URL
    private var window: EngineConsoleWindowController?
    private var statusItem: EngineStatusItemController?
    /// Owns the registered packages; kept for as long as the engine serves.
    private var runtime: ImageRuntime?
    private var serverTask: Task<Void, Never>?

    /// - Parameters:
    ///   - port: where the engine listens (the headless engine's default, so clients find it the same way).
    ///   - modelStore: the models folder the operator chose (`ModelsFolder`), open for this app. There's no default:
    ///     inside the sandbox `ImageRuntime.defaultModelStore` is a folder in the container, which no other app shares.
    public init(port: Int = 17610, modelStore: URL) {
        self.port = port
        self.modelStore = modelStore
    }

    /// Shows the console and the menu-bar item, then starts the engine.
    public func start() {
        let window = EngineConsoleWindowController(console: console, system: system, menuBar: menuBar)
        self.window = window
        statusItem = EngineStatusItemController(console: console, system: system, menuBar: menuBar) { window.show($0) }
        window.show(.queue)
        Task { await boot() }
    }

    public func showConsole(_ section: ConsoleSection? = nil) { window?.show(section) }

    /// Stops serving (at quit).
    public func stop() { serverTask?.cancel() }

    /// Stops serving and waits until the port is free, for a restart on another models folder.
    public func shutdown() async {
        serverTask?.cancel()
        await serverTask?.value
        serverTask = nil
    }

    private func boot() async {
        // In the app's container (ENG-11): the sandbox redirects Application Support there. So the app has an engine id
        // and enabled set of its own, apart from a headless engine's.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pixel Agency/Image Engine", isDirectory: true)
        let stateDir = support.appendingPathComponent("State", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            let enablement = ModelEnablement(file: stateDir.appendingPathComponent("enabled-models.json"))
            console.status = .starting("Registering models…")
            let runtime = await ImageRuntime.start(modelStore: modelStore, catalog: ModelCatalog.all() + PromptBackbones.entries(),
                                                   options: .init(enablement: enablement))
            self.runtime = runtime

            // The spool stays in the container too (ENG-11), apart from a headless engine's: a start wipes it (Base §13
            // rule 3).
            let spool = support.appendingPathComponent("Spool", isDirectory: true)
            var config = EngineConfiguration(id: try ImageRuntime.engineID(in: stateDir), name: console.info.name,
                                             implementationName: "pixel-agency-image-engine",
                                             implementationVersion: ImageRuntime.version, spoolDirectory: spool)
            config.stateDirectory = stateDir
            config.port = port
            config.concurrency = 1                       // one heavy model slot (ENG-3)
            config.handlesShutdownSignals = false        // the app stops the server by cancelling its task
            let server = MESEngineServer(engine: runtime.normalizer, configuration: config)
            let backend = ImageConsoleBackend(server: server, normalizer: runtime.normalizer, enablement: enablement)
            console.status = .starting("Starting the server…")
            let console = self.console
            serverTask = Task {
                do {
                    try await server.run { port in
                        await MainActor.run {
                            console.endpoint = "http://\(config.host):\(port)\(config.basePath)"
                            console.modeSummary = "Open mode · this Mac only"
                            console.attach(backend)
                        }
                    }
                } catch is CancellationError {
                } catch {
                    await MainActor.run { console.status = .failed(Self.describe(error, port: config.port)) }
                }
            }
        } catch {
            console.status = .failed("The engine couldn't start: \(error.localizedDescription)")
        }
    }

    private static func describe(_ error: any Error, port: Int) -> String {
        let text = "\(error)"
        if text.contains("Address already in use") || text.contains("EADDRINUSE") || text.contains("errno: 48") {
            return "Port \(port) is in use. Is the headless engine (pixel-agency-image-engine) already running?"
        }
        return "The server stopped: \(text)"
    }
}
