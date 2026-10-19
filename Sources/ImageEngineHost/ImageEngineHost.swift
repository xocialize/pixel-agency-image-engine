import AppKit
import Foundation
import ImageServerCatalog
import ImageServerModels
import MESCore
import MESEngineKit
import MESEngineUI
import PixelAgencyImageEngine

/// The Image Engine as a Mac app (Engines-PRD ENG-9): the engine in process, with MESEngineUI's console window and
/// menu-bar item. It serves as the headless engine does, open mode on this Mac, and the operator chooses its enabled set
/// of models in the console instead of with `--allow-research`.
///
/// The app is a thin shell around this: `ImageEngineHost().start()` at launch, `showConsole()` when it's reopened.
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
    ///   - modelStore: the shared models folder (ENG-13).
    public init(port: Int = 17610, modelStore: URL = ImageRuntime.defaultModelStore) {
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

    private func boot() async {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pixel Agency/Image Engine", isDirectory: true)
        // The headless engine's state folder: the same engine id, so clients that know this engine still do.
        let stateDir = support.appendingPathComponent("State", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            let enablement = ModelEnablement(file: stateDir.appendingPathComponent("enabled-models.json"))
            console.status = .starting("Registering models…")
            let runtime = await ImageRuntime.start(modelStore: modelStore, catalog: ModelCatalog.all(),
                                                   options: .init(enablement: enablement))
            self.runtime = runtime

            // Its own spool: a start wipes the spool (Base §13 rule 3), and a headless engine may be using its own.
            let spool = FileManager.default.temporaryDirectory.appendingPathComponent("pixel-agency-image-engine-app-spool")
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
