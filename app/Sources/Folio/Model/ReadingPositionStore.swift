import Foundation

/// Позиция чтения, которую нужно восстановить при следующем открытии документа.
struct ReadingPosition: Codable, Sendable, Equatable {
    var page: Int
    /// 0…1 — насколько далеко прокручена страница (как `currentPageProgress`).
    var progress: Double
    var zoom: Double
    var fitWidth: Bool
}

/// Хранилище позиций чтения: `UserDefaults`, ключ `Folio.readingPositions`
/// (путь документа → позиция). Плюс последний открытый документ — для запуска
/// приложения «с того места».
@MainActor
enum ReadingPositionStore {
    private static let positionsKey = "Folio.readingPositions"
    private static let lastDocumentKey = "Folio.lastDocumentPath"
    private static let timestampKey = "ts"
    private static let limit = 50

    private static var defaults: UserDefaults { .standard }

    // MARK: - Позиция документа

    static func save(_ position: ReadingPosition, for url: URL) {
        guard url.isFileURL else { return }
        var all = rawPositions()
        all[key(for: url)] = [
            "page": position.page,
            "progress": position.progress,
            "zoom": position.zoom,
            "fitWidth": position.fitWidth,
            timestampKey: Date().timeIntervalSince1970,
        ]
        trim(&all)
        defaults.set(all, forKey: positionsKey)
    }

    static func load(for url: URL) -> ReadingPosition? {
        guard let entry = rawPositions()[key(for: url)] else { return nil }
        let page = entry["page"] as? Int ?? 0
        let progress = entry["progress"] as? Double ?? 0
        let zoom = entry["zoom"] as? Double ?? 1
        let fitWidth = entry["fitWidth"] as? Bool ?? true
        return ReadingPosition(page: max(0, page),
                               progress: min(max(progress, 0), 1),
                               zoom: zoom,
                               fitWidth: fitWidth)
    }

    static func forget(for url: URL) {
        var all = rawPositions()
        all.removeValue(forKey: key(for: url))
        defaults.set(all, forKey: positionsKey)
    }

    // MARK: - Последний документ

    static func setLastDocument(_ url: URL?) {
        if let url {
            defaults.set(url.path, forKey: lastDocumentKey)
        } else {
            defaults.removeObject(forKey: lastDocumentKey)
        }
    }

    /// Последний документ, если файл ещё существует.
    static func lastDocument() -> URL? {
        guard let path = defaults.string(forKey: lastDocumentKey),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Внутреннее

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func rawPositions() -> [String: [String: Any]] {
        (defaults.dictionary(forKey: positionsKey) as? [String: [String: Any]]) ?? [:]
    }

    /// Не даём словарю расти бесконечно: оставляем последние `limit` документов.
    private static func trim(_ all: inout [String: [String: Any]]) {
        guard all.count > limit else { return }
        let sorted = all.sorted {
            (($0.value[timestampKey] as? Double) ?? 0) > (($1.value[timestampKey] as? Double) ?? 0)
        }
        all = Dictionary(uniqueKeysWithValues: sorted.prefix(limit).map { ($0.key, $0.value) })
    }
}
