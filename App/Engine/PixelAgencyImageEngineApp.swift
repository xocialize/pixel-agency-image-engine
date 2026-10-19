import AppKit
import ImageEngineHost
import SwiftUI

/// Pixel Agency Image Engine as a Mac app (Engines-PRD ENG-9): a thin shell around `ImageEngineHost`, which runs the
/// engine in process with MESEngineUI's console window (Queue, Models, System) and menu-bar item. Closing the window
/// leaves the engine serving from the menu bar; Quit stops it.
@main
struct PixelAgencyImageEngineApp: App {
    @NSApplicationDelegateAdaptor(EngineAppDelegate.self) var appDelegate

    var body: some Scene {
        // The console is an AppKit window the menu-bar item can bring back; SwiftUI supplies the main menu.
        Settings { EmptyView() }
    }
}

@MainActor
final class EngineAppDelegate: NSObject, NSApplicationDelegate {
    private let host = ImageEngineHost()

    func applicationDidFinishLaunching(_ notification: Notification) { host.start() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { host.showConsole() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { host.stop() }
}
