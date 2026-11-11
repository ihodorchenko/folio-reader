import Foundation
import CoreGraphics
import Darwin

// MARK: - C ABI Rust-ядра (pdfreader/CONTRACT.md, раздел 1)
// Намеренно dlopen, а не линковка: приложение собирается и запускается даже без
// собранного ядра (тогда UI работает на MockDocumentProvider).

typealias PcOpenFn = @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
typealias PcCloseFn = @convention(c) (OpaquePointer?) -> Void
typealias PcPageCountFn = @convention(c) (OpaquePointer?) -> Int32
typealias PcPageDimFn = @convention(c) (OpaquePointer?, Int32) -> Double
typealias PcRenderFn = @convention(c) (
    OpaquePointer?, Int32, Double,
    UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
) -> Int32
typealias PcPageJsonFn = @convention(c) (OpaquePointer?, Int32) -> UnsafeMutablePointer<CChar>?
typealias PcDocJsonFn = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
typealias PcSearchFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
typealias PcFreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
typealias PcCStringFn = @convention(c) () -> UnsafePointer<CChar>?

final class CoreLibrary {
    let handle: UnsafeMutableRawPointer
    let open: PcOpenFn
    let close: PcCloseFn
    let pageCount: PcPageCountFn
    let pageWidth: PcPageDimFn
    let pageHeight: PcPageDimFn
    let renderPage: PcRenderFn
    let pageLayoutJson: PcPageJsonFn
    let structureJson: PcDocJsonFn
    let searchJson: PcSearchFn
    let freeBuffer: PcFreeFn
    let freeJson: PcFreeFn
    let lastError: PcCStringFn
    let version: PcCStringFn
    let path: String

    private static var cached: CoreLibrary?
    private static let cacheLock = NSLock()

    /// Ищет и загружает libpdfcore.dylib. nil — ядро не собрано/не найдено.
    static func shared() -> CoreLibrary? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached { return cached }
        guard let path = locateDylib() else { return nil }
        guard let lib = CoreLibrary(path: path) else { return nil }
        cached = lib
        return lib
    }

    init?(path: String) {
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let s = dlsym(h, name) else { return nil }
            return unsafeBitCast(s, to: T.self)
        }
        guard let open = sym("pc_open", as: PcOpenFn.self),
              let close = sym("pc_close", as: PcCloseFn.self),
              let pageCount = sym("pc_page_count", as: PcPageCountFn.self),
              let pageWidth = sym("pc_page_width", as: PcPageDimFn.self),
              let pageHeight = sym("pc_page_height", as: PcPageDimFn.self),
              let renderPage = sym("pc_render_page", as: PcRenderFn.self),
              let pageLayoutJson = sym("pc_page_layout_json", as: PcPageJsonFn.self),
              let structureJson = sym("pc_document_structure_json", as: PcDocJsonFn.self),
              let searchJson = sym("pc_search_json", as: PcSearchFn.self),
              let freeBuffer = sym("pc_free_buffer", as: PcFreeFn.self),
              let freeJson = sym("pc_free_json", as: PcFreeFn.self),
              let lastError = sym("pc_last_error", as: PcCStringFn.self),
              let version = sym("pc_version", as: PcCStringFn.self)
        else {
            dlclose(h)
            return nil
        }
        self.handle = h
        self.open = open
        self.close = close
        self.pageCount = pageCount
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.renderPage = renderPage
        self.pageLayoutJson = pageLayoutJson
        self.structureJson = structureJson
        self.searchJson = searchJson
        self.freeBuffer = freeBuffer
        self.freeJson = freeJson
        self.lastError = lastError
        self.version = version
        self.path = path
    }

    var versionString: String {
        version().map { String(cString: $0) } ?? "pdfcore"
    }

    var lastErrorMessage: String {
        if let p = lastError() { return String(cString: p) }
        return "unknown error"
    }

    static var searchedPaths: [String] = []

    static func locateDylib() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["PDFCORE_DYLIB"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        let cwd = fm.currentDirectoryPath
        let exeDir = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath().deletingLastPathComponent().path
        // 1. Внутри .app-бандла: Contents/MacOS, Contents/Frameworks, Contents/Resources.
        //    Эти пути важнее cwd, иначе запуск из папки проекта подхватит dev-копию ядра.
        candidates += [
            "\(exeDir)/libpdfcore.dylib",
            "\(exeDir)/../Frameworks/libpdfcore.dylib",
            "\(exeDir)/../Resources/libpdfcore.dylib",
        ]
        // 2. Рядом с бинарником в dev-сборке SwiftPM (app/.build/.../debug/Folio).
        candidates += [
            "\(exeDir)/../../../core/libpdfcore.dylib",
            "\(exeDir)/../../../target/release/libpdfcore.dylib",
            "\(exeDir)/../../../../core/target/release/libpdfcore.dylib",
            "\(exeDir)/../../../../../core/target/release/libpdfcore.dylib",
        ]
        // 3. cwd и окрестности воркспейса.
        candidates += [
            "\(cwd)/.build/core/libpdfcore.dylib",
            "\(cwd)/app/.build/core/libpdfcore.dylib",
            "\(cwd)/libpdfcore.dylib",
            "\(cwd)/../core/target/release/libpdfcore.dylib",
            "\(cwd)/core/target/release/libpdfcore.dylib",
        ]
        // путь из env-скрипта запуска
        if let root = ProcessInfo.processInfo.environment["FOLIO_ROOT"] {
            candidates += [
                "\(root)/core/target/release/libpdfcore.dylib",
                "\(root)/app/.build/core/libpdfcore.dylib",
            ]
        }
        searchedPaths = candidates
        for path in candidates where fm.fileExists(atPath: path) {
            // Нормализуем "…/MacOS/../Frameworks/…" — путь идёт в логи и summary.
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return nil
    }
}

// MARK: - Документ поверх ядра

final class PdfCoreDocument: DocumentProviding, @unchecked Sendable {
    let url: URL
    let pageCount: Int
    let fingerprint: String
    var isMock: Bool { false }

    private let lib: CoreLibrary
    private let doc: OpaquePointer
    private let lock = NSLock()
    private var layoutCache: [Int: PcPageLayout] = [:]
    private var structureCache: PcDocumentStructure?

    init(url: URL) throws {
        guard let lib = CoreLibrary.shared() else {
            throw PdfCoreError.dylibNotFound(CoreLibrary.searchedPaths)
        }
        let path = url.path
        guard let doc = path.withCString({ lib.open($0) }) else {
            throw PdfCoreError.openFailed(lib.lastErrorMessage)
        }
        self.lib = lib
        self.doc = doc
        self.url = url
        self.pageCount = Int(lib.pageCount(doc))
        self.fingerprint = Self.fingerprint(for: url)
        if pageCount <= 0 {
            lib.close(doc)
            throw PdfCoreError.openFailed("документ без страниц")
        }
    }

    deinit {
        lib.close(doc)
    }

    static func fingerprint(for url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(mtime)"
    }

    // MARK: DocumentProviding

    func structure() throws -> PcDocumentStructure {
        lock.lock()
        defer { lock.unlock() }
        if let structureCache { return structureCache }
        let json = lib.structureJson(doc)
        let structure: PcDocumentStructure = try PdfJson.decode(PcDocumentStructure.self, from: json, free: lib.freeJson)
        structureCache = structure
        return structure
    }

    func pageLayout(_ index: Int) throws -> PcPageLayout {
        guard index >= 0, index < pageCount else {
            throw PdfCoreError.badResponse("страница \(index) вне диапазона 0..<\(pageCount)")
        }
        lock.lock()
        defer { lock.unlock() }
        if let cached = layoutCache[index] { return cached }
        let json = lib.pageLayoutJson(doc, Int32(index))
        let layout: PcPageLayout = try PdfJson.decode(PcPageLayout.self, from: json, free: lib.freeJson)
        layoutCache[index] = layout
        return layout
    }

    func pageSize(_ index: Int) throws -> CGSize {
        lock.lock()
        defer { lock.unlock() }
        let w = lib.pageWidth(doc, Int32(index))
        let h = lib.pageHeight(doc, Int32(index))
        guard w > 0, h > 0 else {
            throw PdfCoreError.badResponse("некорректный размер страницы \(index)")
        }
        return CGSize(width: w, height: h)
    }

    func render(_ index: Int, scale: Double) throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }
        var w: Int32 = 0
        var h: Int32 = 0
        var buffer: UnsafeMutablePointer<UInt8>?
        let status = lib.renderPage(doc, Int32(index), scale, &w, &h, &buffer)
        guard status == 0, let buffer, w > 0, h > 0 else {
            throw PdfCoreError.badResponse("render: \(lib.lastErrorMessage)")
        }
        defer { lib.freeBuffer(UnsafeMutableRawPointer(buffer)) }
        let byteCount = Int(w) * Int(h) * 4
        let data = Data(bytes: buffer, count: byteCount)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw PdfCoreError.badResponse("CGDataProvider")
        }
        // Ядро отдаёт BGRA (B,G,R,A), alpha == 255.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.noneSkipFirst.rawValue)
        guard let image = CGImage(
            width: Int(w), height: Int(h),
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: Int(w) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        ) else {
            throw PdfCoreError.badResponse("CGImage")
        }
        return image
    }

    func search(_ query: String) throws -> [PcSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let json = trimmed.withCString { lib.searchJson(doc, $0) }
        let response: PcSearchResponse = try PdfJson.decode(PcSearchResponse.self, from: json, free: lib.freeJson)
        return response.hits
    }
}
