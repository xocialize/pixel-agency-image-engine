import AppKit
import DesignScaffold
import SwiftUI

/// The onboarding window (ENG-11, README APP-3): shown at first launch, before the engine starts, and at a later launch
/// whose models folder can't be used as it is (APP-4). It closes once the folder is ready and hands it to `onReady`.
@MainActor
public final class ModelsFolderSetupWindow {
    private let window: NSWindow

    public init(folder: ModelsFolder, appName: String = "Pixel Agency Image Engine",
                onReady: @escaping @MainActor (URL) -> Void) {
        let window = NSWindow(contentViewController: NSViewController())
        self.window = window
        let view = ModelsFolderOnboarding(folder: folder, appName: appName, window: window) { url in
            window.orderOut(nil)
            onReady(url)
        }
        window.contentViewController = NSHostingController(rootView: view)
        // No close button: until there's a folder there's nothing else to show, so the way out is Quit.
        window.styleMask = [.titled]
        window.title = appName
        window.isReleasedWhenClosed = false
    }

    public func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// What the models folder is for, with the folder the Mac's other apps already use suggested (ENG-13, D-27), then an
/// open panel to choose or create one; or, at a later launch, what's wrong with it: locate it, choose another, or quit.
struct ModelsFolderOnboarding: View {
    let folder: ModelsFolder
    let appName: String
    /// The window the open panel attaches to.
    let window: NSWindow
    let onReady: @MainActor (URL) -> Void
    @State private var problem: String?

    private let shared = ModelsFolder.sharedSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(tint)
            Text(title).font(Tokens.Font.screenTitle)
            switch folder.status {
            case .notChosen, .ready:
                Text("\(appName) downloads the models it runs into a folder you choose, the first time a job needs "
                     + "each one. Some are tens of gigabytes, so choose a volume with room: an external one works. You "
                     + "can change the folder later in Settings.")
                    .fixedSize(horizontal: false, vertical: true)
                suggestion
            case .moved(let from, let to):
                Text("It was at \(from) and is now at \(to.path). Keep using it there, or choose another folder.")
                    .fixedSize(horizontal: false, vertical: true)
            case .unavailable(let why):
                Text(why).fixedSize(horizontal: false, vertical: true).foregroundStyle(Tokens.Color.degraded)
            }
            if let problem { Text(problem).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.failure) }
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                switch folder.status {
                case .notChosen, .ready:
                    Button("Choose Another Folder…") { choose(startingAt: nil) }
                    Button("Use Shared Folder…") { choose(startingAt: shared) }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                case .moved:
                    Button("Choose Another Folder…") { choose(startingAt: nil) }
                    Button("Use It There") { useMovedFolder() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                case .unavailable:
                    Button("Locate or Choose Another…") { choose(startingAt: folder.chosenPath.map(Self.nearestFolder)) }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(Tokens.Space.xxl)
        .frame(width: 540)
    }

    /// The shared folder, offered first so the apps on one Mac share weights.
    private var suggestion: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            Label("Share models with your other apps", systemImage: "square.stack.3d.up").font(Tokens.Font.headline)
            Text("Pixel Agency apps and ML[X] engines on this Mac keep their models in \(shared.path). Use that folder, "
                 + "and the engine runs the models they've downloaded instead of downloading them again.")
                .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var title: String {
        switch folder.status {
        case .notChosen, .ready: "Choose a models folder"
        case .moved: "The models folder moved"
        case .unavailable: "The models folder isn't available"
        }
    }

    private var symbol: String {
        switch folder.status {
        case .notChosen, .ready: "folder.badge.plus"
        case .moved, .unavailable: "folder.badge.questionmark"
        }
    }

    private var tint: Color {
        if case .unavailable = folder.status { Tokens.Color.degraded } else { Tokens.Color.accent }
    }

    /// An open panel, which grants the sandboxed app the folder the operator picks; the bookmark keeps it for later
    /// launches. Choosing with nothing selected takes the folder the panel shows, so the shared folder is one click.
    private func choose(startingAt directory: URL?) {
        let panel = Self.panel(appName: appName, startingAt: directory)
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            do {
                try folder.choose(url)
                problem = nil
                if let ready = folder.url { onReady(ready) }
            } catch {
                problem = "Couldn't keep access to that folder: \(error.localizedDescription)"
            }
        }
    }

    private func useMovedFolder() {
        do {
            try folder.useMovedFolder()
            if let ready = folder.url { onReady(ready) }
        } catch {
            problem = "Couldn't keep access to that folder: \(error.localizedDescription)"
        }
    }

    static func panel(appName: String, startingAt directory: URL?) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose or create the folder \(appName) keeps its models in"
        if let directory { panel.directoryURL = directory }
        return panel
    }

    /// The deepest folder of `path` that's still there, for a panel locating a folder that's gone.
    static func nearestFolder(_ path: String) -> URL {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.path) { url.deleteLastPathComponent() }
        return url
    }
}

/// The models folder in the app's Settings (APP-5): where it is, and a change through the same open panel. A change
/// restarts the engine on the new folder, so it's confirmed first; it moves nothing.
public struct ModelsFolderSettings: View {
    let folder: ModelsFolder
    let appName: String
    /// Restarts the engine once the folder has changed: the app stops serving and opens again on the new folder.
    let restart: @MainActor () -> Void
    @State private var pending: URL?
    @State private var problem: String?
    /// The Settings window, for the open panel's sheet.
    @State private var window: NSWindow?

    public init(folder: ModelsFolder, appName: String = "Pixel Agency Image Engine",
                restart: @escaping @MainActor () -> Void) {
        self.folder = folder
        self.appName = appName
        self.restart = restart
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent("Models folder") {
                    Text(folder.url?.path ?? "None").textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                Text("Changing the folder moves nothing: the models already downloaded stay where they are, and the "
                     + "engine downloads what it needs into the new folder. To share models with your other apps, "
                     + "choose \(ModelsFolder.sharedSuggestion.path).")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem { Text(problem).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.failure) }
                HStack {
                    if let url = folder.url {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Spacer()
                    Button("Change…") { change() }
                }
            }
        }
        .formStyle(.grouped)
        .background(HostWindow { window = $0 })
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 520)
        .alert("Restart the engine to use this folder?",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { url in
            Button("Restart") { pending = nil; use(url) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { url in
            Text("\(appName) quits and opens again with its models in \(url.path). Jobs running or waiting now are "
                 + "cancelled.")
        }
    }

    /// The open panel as a sheet on the Settings window, as at onboarding.
    private func change() {
        let panel = ModelsFolderOnboarding.panel(appName: appName, startingAt: folder.url)
        Task {
            let response = if let window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
            guard response == .OK, let url = panel.url, url.standardizedFileURL != folder.url?.standardizedFileURL
            else { return }
            pending = url
        }
    }

    private func use(_ url: URL) {
        do {
            try folder.choose(url)
            problem = nil
            restart()
        } catch {
            problem = "Couldn't keep access to that folder: \(error.localizedDescription)"
        }
    }
}

/// Hands a SwiftUI view the window it's in.
private struct HostWindow: NSViewRepresentable {
    let found: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in found(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
