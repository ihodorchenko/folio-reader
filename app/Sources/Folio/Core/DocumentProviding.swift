import Foundation
import CoreGraphics

// MARK: - Ошибки и фабрика

enum PdfCoreError: LocalizedError {
    case dylibNotFound([String])
    case openFailed(String)
    case coreUnavailable
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .dylibNotFound(let searched):
            return "Не найден libpdfcore.dylib. Искали:\n" + searched.joined(separator: "\n")
        case .openFailed(let msg):
            return "Не удалось открыть документ: \(msg)"
        case .coreUnavailable:
            return "Ядро pdfcore недоступно"
        case .badResponse(let msg):
            return "Некорректный ответ ядра: \(msg)"
        }
    }
}

/// Любой документ, который умеет отдавать страницы и структуру.
/// Методы синхронные и потокобезопасные: вызывать можно с фоновых очередей.
protocol DocumentProviding: AnyObject, Sendable {
    var isMock: Bool { get }
    /// Стабильный ключ для кэшей (путь + размер + mtime).
    var fingerprint: String { get }
    var pageCount: Int { get }

    func structure() throws -> PcDocumentStructure
    func pageLayout(_ index: Int) throws -> PcPageLayout
    /// Размер страницы в точках (1/72"), уже с учётом rotation.
    func pageSize(_ index: Int) throws -> CGSize
    /// Рендер в пикселях. scale == 1.0 → 72 dpi. Возвращает непрозрачный CGImage.
    func render(_ index: Int, scale: Double) throws -> CGImage
    func search(_ query: String) throws -> [PcSearchHit]
}

enum PdfCore {
    /// Открывает документ через Rust-ядро, если библиотека доступна,
    /// иначе (в debug-сборке) отдаёт мок, чтобы UI можно было разрабатывать без ядра.
    static func open(url: URL) throws -> any DocumentProviding {
        if let doc = try? PdfCoreDocument(url: url) {
            return doc
        }
        if ProcessInfo.processInfo.environment["FOLIO_REQUIRE_CORE"] == "1" {
            throw PdfCoreError.coreUnavailable
        }
        return MockDocumentProvider(url: url)
    }

    static var isMockMode: Bool {
        CoreLibrary.shared() == nil
    }
}

// MARK: - Хелперы декодирования

enum PdfJson {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .useDefaultKeys
        return d
    }()

    static func decode<T: Decodable>(_ type: T.Type, from pointer: UnsafeMutablePointer<CChar>?, free: (UnsafeMutableRawPointer?) -> Void) throws -> T {
        guard let pointer else { throw PdfCoreError.badResponse("пустой указатель") }
        defer { free(UnsafeMutableRawPointer(pointer)) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<not utf8>"
            throw PdfCoreError.badResponse("\(error.localizedDescription) :: \(preview)")
        }
    }
}
