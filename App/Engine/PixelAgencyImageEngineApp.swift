import AppKit
import ImageEngineHost
import SwiftUI

/// Pixel Agency Image Engine as a Mac app (Engines-PRD ENG-9): a thin shell around `ImageEngineHost`, which runs the
/// engine in process with MESEngineUI's console window (Queue, Models, System) and menu-bar item. Closing the window
/// leaves the engine serving from the menu bar; Quit stops it.
///
/// Sandboxed (ENG-11): the engine starts once the models folder the operator chose is open, and onboarding asks for it
/// first (README APP-3, APP-4). Settings changes it (APP-5).
@main
struct PixelAgencyImageEngineApp: App {
    @NSApplicationDelegateAdaptor(EngineAppDelegate.self) var appDelegate

    var body: some Scene {
        // The console is an AppKit window the menu-bar item can bring back; SwiftUI supplies the main menu.
        Settings {
            ModelsFolderSettings(folder: appDelegate.folder) { appDelegate.restart() }
        }
    }
}

@MainActor
final class EngineAppDelegate: NSObject, NSApplicationDelegate {
    let folder = ModelsFolder()
    private var host: ImageEngineHost?
    private var setup: ModelsFolderSetupWindow?

    func applicationDidFinishLaunching(_ notification: Notification) { startWhenReady() }

    /// Starts the engine on the models folder, or asks for one first: at first launch, or when the folder can't be
    /// used as it is (missing, in the Trash, moved).
    private func startWhenReady() {
        guard let modelStore = folder.url else {
            let setup = ModelsFolderSetupWindow(folder: folder) { [weak self] _ in self?.startWhenReady() }
            self.setup = setup
            setup.show()
            return
        }
        let host = ImageEngineHost(modelStore: modelStore)
        self.host = host
        host.start()
    }

    /// Settings changed the models folder: stop serving so the port is free, and open the app again on the new folder.
    /// The new instance starts as this one quits.
    func restart() {
        Task {
            await host?.shutdown()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            _ = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if let host { host.showConsole() } else { setup?.show() }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        host?.stop()
        folder.stop()
    }
}
