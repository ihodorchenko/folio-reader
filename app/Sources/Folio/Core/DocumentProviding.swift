import Foundation
import CoreGraphics

// MARK: - Errors and factory

enum PdfCoreError: LocalizedError {
    case dylibNotFound([String])
    case openFailed(String)
    case coreUnavailable
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .dylibNotFound(let searched):
            return L10n.t("libpdfcore.dylib not found. Searched:\n%@", searched.joined(separator: "\n"))
        case .openFailed(let msg):
            return L10n.t("Could not open the document: %@", msg)
        case .coreUnavailable:
            return L10n.t("The pdfcore library is unavailable")
        case .badResponse(let msg):
            return L10n.t("Invalid core response: %@", msg)
        }
    }
}

/// Any document that can provide pages and structure.
/// Methods are synchronous and thread-safe: they can be called from background queues.
protocol DocumentProviding: AnyObject, Sendable {
    var isMock: Bool { get }
    /// Stable cache key (path + size + mtime).
    var fingerprint: String { get }
    var pageCount: Int { get }

    func structure() throws -> PcDocumentStructure
    func pageLayout(_ index: Int) throws -> PcPageLayout
    /// Page size in points (1/72"), already including rotation.
    func pageSize(_ index: Int) throws -> CGSize
    /// Pixel rendering. scale == 1.0 → 72 dpi. Returns an opaque CGImage.
    func render(_ index: Int, scale: Double) throws -> CGImage
    func search(_ query: String) throws -> [PcSearchHit]
}

enum PdfCore {
    /// Opens the document through the Rust core if the library is available,
    /// otherwise (in a debug build) returns the mock so the UI can be developed without the core.
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

// MARK: - Decoding helpers

enum PdfJson {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .useDefaultKeys
        return d
    }()

    static func decode<T: Decodable>(_ type: T.Type, from pointer: UnsafeMutablePointer<CChar>?, free: (UnsafeMutableRawPointer?) -> Void) throws -> T {
        guard let pointer else { throw PdfCoreError.badResponse("null pointer") }
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
