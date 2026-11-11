import Foundation
import Observation

/// Один документ в списке недавних.
struct RecentDocument: Identifiable, Hashable, Sendable {
    let url: URL
    /// Подпись для меню: имя файла, а при совпадении имён — с папкой.
    let title: String
    /// Родительская папка — для подсказки и различения одноимённых файлов.
    let folder: String

    var id: String { url.standardizedFileURL.path }
}

extension Notification.Name {
    /// Список недавних документов изменился (для подменю «Открыть недавние»).
    static let recentDocumentsChanged = Notification.Name("Folio.recentDocumentsChanged")
}

/// Список недавно открытых документов (MRU) в `UserDefaults`.
///
/// Используется меню «Файл → Открыть недавние» и пустым состоянием ридера.
/// Файлы, которых больше нет на диске, из меню скрываются.
@Observable
@MainActor
final class RecentDocumentsStore {
    static let shared = RecentDocumentsStore()

    /// Сколько документов показывать в меню.
    static let limit = 12
    private static let key = "Folio.recentDocuments"

    private(set) var documents: [RecentDocument] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    // MARK: - Изменения

    /// Запомнить открытый документ: он становится первым в списке.
    func note(_ url: URL) {
        guard url.isFileURL else { return }
        let path = url.standardizedFileURL.path
        var paths = storedPaths().filter { $0 != path }
        paths.insert(path, at: 0)
        if paths.count > Self.limit { paths = Array(paths.prefix(Self.limit)) }
        defaults.set(paths, forKey: Self.key)
        reload()
        folioLog("recent: «\(url.lastPathComponent)», всего \(documents.count)")
    }

    func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        defaults.set(storedPaths().filter { $0 != path }, forKey: Self.key)
        reload()
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
        documents = []
        folioLog("recent: список очищен")
        NotificationCenter.default.post(name: .recentDocumentsChanged, object: nil)
    }

    /// Перечитать список: отбросить удалённые файлы и заодно нормализовать имена.
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

    // MARK: - Внутреннее

    private func storedPaths() -> [String] {
        (defaults.array(forKey: Self.key) as? [String]) ?? []
    }
}
