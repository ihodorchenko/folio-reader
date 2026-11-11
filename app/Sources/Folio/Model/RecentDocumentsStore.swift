import Foundation
import Observation

/// One document in the recents list.
struct RecentDocument: Identifiable, Hashable, Sendable {
    let url: URL
    /// Menu title: the file name, plus the folder when names collide.
    let title: String
    /// Parent folder — for the tooltip and to tell same-named files apart.
    let folder: String

    var id: String { url.standardizedFileURL.path }
}

extension Notification.Name {
    /// The recents list changed (for the "Open Recent" submenu).
    static let recentDocumentsChanged = Notification.Name("Folio.recentDocumentsChanged")
}

/// Most-recently-used document list (MRU) in `UserDefaults`.
///
/// Used by the "File → Open Recent" menu and by the reader's empty state.
/// Files that no longer exist on disk are hidden from the menu.
@Observable
@MainActor
final class RecentDocumentsStore {
    static let shared = RecentDocumentsStore()

    /// How many documents to show in the menu.
    static let limit = 12
    private static let key = "Folio.recentDocuments"

    private(set) var documents: [RecentDocument] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    // MARK: - Changes

    /// Remember an opened document: it becomes the first in the list.
    func note(_ url: URL) {
        guard url.isFileURL else { return }
        let path = url.standardizedFileURL.path
        var paths = storedPaths().filter { $0 != path }
        paths.insert(path, at: 0)
        if paths.count > Self.limit { paths = Array(paths.prefix(Self.limit)) }
        defaults.set(paths, forKey: Self.key)
        reload()
        folioLog("recent: \"\(url.lastPathComponent)\", total \(documents.count)")
    }

    func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        defaults.set(storedPaths().filter { $0 != path }, forKey: Self.key)
        reload()
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
        documents = []
        folioLog("recent: list cleared")
        NotificationCenter.default.post(name: .recentDocumentsChanged, object: nil)
    }

    /// Re-read the list: drop deleted files and normalize the titles while at it.
    func reload() {
        let existing = storedPaths().filter { FileManager.default.fileExists(atPath: $0) }
        if existing != storedPaths() {
            defaults.set(existing, forKey: Self.key)
        }
        let nameCounts = Dictionary(grouping: existing) { URL(fileURLWithPath: $0).lastPathComponent }
            .mapValues(\.count)
        documents = existing.prefix(Self.limit).map { path in
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            let parent = url.deletingLastPathComponent().lastPathComponent
            let title = (nameCounts[name] ?? 1) > 1 ? "\(name) — \(parent)" : name
            return RecentDocument(url: url, title: title, folder: url.deletingLastPathComponent().path)
        }
        NotificationCenter.default.post(name: .recentDocumentsChanged, object: nil)
    }

    // MARK: - Internals

    private func storedPaths() -> [String] {
        (defaults.array(forKey: Self.key) as? [String]) ?? []
    }
}
