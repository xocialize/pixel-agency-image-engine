import Foundation
import Observation

/// The engine app's working folder, which holds the model store (Engines-PRD ENG-11, README APP-3–5 and APP-8): chosen at
/// first launch, kept as an app-scope security-scoped bookmark, opened at every launch and released at quit. After
/// Pixel Agency Lite's `WorkingFolder` and PixelAgencyEditor's `BookmarkedFolder`, under the same defaults key as their
/// models folder.
///
/// Nothing goes wrong silently (APP-4). A bookmark that no longer resolves, a volume that isn't connected or a folder in
/// the Trash is `unavailable`; a folder that was moved or renamed is `moved` until the operator says to use it there.
@MainActor @Observable
public final class ModelsFolder {
    public enum Status: Equatable {
        case notChosen
        case ready(URL)
        /// The bookmark still finds the folder, but somewhere else: moved or renamed since it was chosen. It's open at
        /// its new place; `useMovedFolder()` keeps it there.
        case moved(from: String, to: URL)
        /// The bookmark no longer resolves (deleted, or on a volume that's gone), or the folder is in the Trash.
        case unavailable(String)
    }

    public static let defaultsKey = "PixelAgency.modelsFolderBookmark"

    public private(set) var status: Status = .notChosen
    let defaults: UserDefaults
    let key: String
    /// The folder open now, and whether opening it took a security scope (a folder inside the container needs none).
    private var access: (url: URL, scoped: Bool)?

    public init(defaults: UserDefaults = .standard, key: String = ModelsFolder.defaultsKey) {
        self.defaults = defaults
        self.key = key
        resolve()
    }

    /// The folder, once it's ready to use.
    public var url: URL? { if case .ready(let url) = status { url } else { nil } }

    /// Where the folder was when it was chosen, as the bookmark recorded it.
    public var chosenPath: String? {
        defaults.data(forKey: key).flatMap { URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: $0)?.path }
    }

    /// Where the other Pixel Agency apps and the ML[X] engines keep their models, suggested at onboarding so the apps on
    /// one Mac share weights (ENG-13, D-27): `MLXIMG_MODEL_STORE` when it's set, as for the headless engine, else
    /// `~/Library/Application Support/MLXEngine/Models` in the operator's real Library. Inside the sandbox the home folder
    /// is the container, which holds no other app's models (AB-A-0174).
    public nonisolated static var sharedSuggestion: URL {
        if let override = ProcessInfo.processInfo.environment["MLXIMG_MODEL_STORE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: realHomeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Application Support/MLXEngine/Models", isDirectory: true)
    }

    /// Resolves the bookmark and starts accessing the folder (APP-4), closing the one open until now.
    public func resolve() {
        close()
        guard let data = defaults.data(forKey: key) else { status = .notChosen; return }
        let chosenPath = chosenPath
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            let scoped = url.startAccessingSecurityScopedResource()
            guard scoped || FileManager.default.isWritableFile(atPath: url.path) else {
                status = .unavailable("The models folder can't be opened any more: \(url.path).")
                return
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                status = .unavailable(missing(url.path))
                return
            }
            // Deleting a folder in the Finder moves it to the Trash, where the bookmark still finds it.
            if url.pathComponents.contains(".Trash") {
                if scoped { url.stopAccessingSecurityScopedResource() }
                status = .unavailable("The models folder is in the Trash: \(chosenPath ?? url.path) was deleted.")
                return
            }
            access = (url, scoped)
            if let chosenPath, !Self.samePlace(chosenPath, url) {
                status = .moved(from: chosenPath, to: url)
                return
            }
            if stale { try? store(url) }                          // refresh a stale-but-resolvable bookmark
            status = .ready(url)
        } catch {
            // The error itself says only that the bookmark didn't resolve ("isn't in the correct format").
            status = .unavailable(missing(chosenPath))
        }
    }

    /// Sets the folder (APP-3, APP-5) from a URL the operator chose in an open panel. When it can't be kept, the folder
    /// stays as it was.
    public func choose(_ url: URL) throws {
        try store(url)
        resolve()
    }

    /// Keeps a folder that moved at its new place.
    public func useMovedFolder() throws {
        guard case .moved(_, let url) = status else { return }
        try store(url)
        status = .ready(url)
    }

    /// Stops accessing the folder (at quit).
    public func stop() {
        close()
    }

    private func close() {
        if let access, access.scoped { access.url.stopAccessingSecurityScopedResource() }
        access = nil
    }

    private func missing(_ path: String?) -> String {
        "The models folder is missing\(path.map { ": \($0)" } ?? ""). It may have been deleted, or be on a volume that "
            + "isn't connected."
    }

    private func store(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: key)
    }

    /// Whether the path a bookmark was made for and where it resolved are one place, `/var` and `/private/var` alike.
    private static func samePlace(_ path: String, _ url: URL) -> Bool {
        let chosen = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = url.standardizedFileURL
        return chosen.path == resolved.path
            || chosen.resolvingSymlinksInPath().path == resolved.resolvingSymlinksInPath().path
    }

    /// The home folder outside the sandbox's container, from the password database, which the sandbox doesn't redirect.
    private nonisolated static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir { return String(cString: directory) }
        return NSHomeDirectory()
    }
}
