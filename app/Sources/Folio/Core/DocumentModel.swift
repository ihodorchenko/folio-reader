import Foundation
import CoreGraphics

// MARK: - Геометрия и типографика
// Зеркало JSON-контракта из pdfreader/CONTRACT.md (раздел 3).
// Координаты: точки PDF (1/72"), origin — левый верхний угол страницы, y вниз.

struct PcRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    static let zero = PcRect(x: 0, y: 0, w: 0, h: 0)

    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var midX: Double { x + w / 2 }
    var midY: Double { y + h / 2 }
    var area: Double { max(0, w) * max(0, h) }

    func contains(_ p: CGPoint) -> Bool {
        p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY
    }

    func insetBy(_ dx: Double, _ dy: Double) -> PcRect {
        PcRect(x: x + dx, y: y + dy, w: max(0, w - dx * 2), h: max(0, h - dy * 2))
    }

    static func union(_ rects: [PcRect]) -> PcRect {
        guard let first = rects.first else { return .zero }
        var r = first
        for q in rects.dropFirst() {
            let minX = min(r.x, q.x), minY = min(r.y, q.y)
            let maxX = max(r.maxX, q.maxX), maxY = max(r.maxY, q.maxY)
            r = PcRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
        }
        return r
    }
}

extension CGRect {
    init(_ r: PcRect) { self.init(x: r.x, y: r.y, width: r.w, height: r.h) }
}

struct PcFont: Codable, Hashable, Sendable {
    var name: String
    var size: Double
    var bold: Bool
    var italic: Bool
    var monospace: Bool

    static let unknown = PcFont(name: "", size: 10, bold: false, italic: false, monospace: false)
}

// MARK: - Слова, строки, блоки

struct PcWord: Codable, Hashable, Sendable {
    var text: String
    var bbox: PcRect
    var size: Double
    var bold: Bool
    var italic: Bool
    var font: String
}

struct PcLine: Codable, Hashable, Sendable {
    var bbox: PcRect
    var text: String
    var baselineY: Double
    var words: [PcWord]
}

enum PcBlockKind: String, Codable, Sendable, CaseIterable {
    case body, heading, list, caption, table, code, header, footer, formula, quote, reference

    var titleRu: String {
        switch self {
        case .body: return "Абзац"
        case .heading: return "Заголовок"
        case .list: return "Список"
        case .caption: return "Подпись"
        case .table: return "Таблица"
        case .code: return "Код"
        case .header: return "Колонтитул"
        case .footer: return "Колонтитул"
        case .formula: return "Формула"
        case .quote: return "Цитата"
        case .reference: return "Литература"
        }
    }

    var debugColor: (r: Double, g: Double, b: Double) {
        switch self {
        case .heading: return (0.96, 0.44, 0.18)
        case .body: return (0.30, 0.55, 0.90)
        case .list: return (0.20, 0.70, 0.45)
        case .caption: return (0.72, 0.45, 0.85)
        case .table: return (0.85, 0.65, 0.20)
        case .code: return (0.55, 0.55, 0.60)
        case .header, .footer: return (0.70, 0.70, 0.72)
        case .formula: return (0.85, 0.35, 0.55)
        case .quote: return (0.40, 0.65, 0.65)
        case .reference: return (0.45, 0.50, 0.40)
        }
    }
}

struct PcBlock: Codable, Hashable, Sendable {
    var id: String
    var kind: PcBlockKind
    var level: Int
    var text: String
    var bbox: PcRect
    var font: PcFont
    var confidence: Double
    var lines: [PcLine]

    // Неизвестный kind от ядра не должен валить декодирование страницы.
    private enum CodingKeys: String, CodingKey {
        case id, kind, level, text, bbox, font, confidence, lines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "body"
        kind = PcBlockKind(rawValue: rawKind) ?? .body
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        bbox = try c.decodeIfPresent(PcRect.self, forKey: .bbox) ?? .zero
        font = try c.decodeIfPresent(PcFont.self, forKey: .font) ?? .unknown
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        lines = try c.decodeIfPresent([PcLine].self, forKey: .lines) ?? []
    }

    init(id: String, kind: PcBlockKind, level: Int, text: String, bbox: PcRect,
         font: PcFont, confidence: Double, lines: [PcLine]) {
        self.id = id; self.kind = kind; self.level = level; self.text = text
        self.bbox = bbox; self.font = font; self.confidence = confidence; self.lines = lines
    }
}

struct PcPageLayout: Codable, Sendable {
    var index: Int
    var width: Double
    var height: Double
    var rotation: Int
    var bodyFontSize: Double
    var blocks: [PcBlock]

    var pageRect: PcRect { PcRect(x: 0, y: 0, w: width, h: height) }
}

// MARK: - Структура документа

struct PcHeading: Codable, Hashable, Sendable {
    var id: String
    var page: Int
    var level: Int
    var title: String
    var bbox: PcRect
    var source: String
}

struct PcOutlineItem: Codable, Hashable, Sendable {
    var title: String
    var page: Int
    var level: Int
    var children: [PcOutlineItem]

    private enum CodingKeys: String, CodingKey { case title, page, level, children }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 0
        children = try c.decodeIfPresent([PcOutlineItem].self, forKey: .children) ?? []
    }

    init(title: String, page: Int, level: Int, children: [PcOutlineItem] = []) {
        self.title = title; self.page = page; self.level = level; self.children = children
    }
}

struct PcDocumentStructure: Codable, Sendable {
    var title: String?
    var pageCount: Int
    var tagged: Bool
    var headings: [PcHeading]
    var outline: [PcOutlineItem]

    private enum CodingKeys: String, CodingKey { case title, pageCount, tagged, headings, outline }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        tagged = try c.decodeIfPresent(Bool.self, forKey: .tagged) ?? false
        headings = try c.decodeIfPresent([PcHeading].self, forKey: .headings) ?? []
        outline = try c.decodeIfPresent([PcOutlineItem].self, forKey: .outline) ?? []
    }

    init(title: String?, pageCount: Int, tagged: Bool, headings: [PcHeading], outline: [PcOutlineItem]) {
        self.title = title; self.pageCount = pageCount; self.tagged = tagged
        self.headings = headings; self.outline = outline
    }
}

struct PcSearchHit: Codable, Hashable, Sendable {
    var page: Int
    var rects: [PcRect]
    var snippet: String
}

struct PcSearchResponse: Codable, Sendable {
    var query: String
    var hits: [PcSearchHit]
}
