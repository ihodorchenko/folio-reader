import Foundation
import CoreGraphics

/// Demo document for developing the UI without a built core.
/// The structure deliberately resembles a real one: level 1–3 headings, paragraphs,
/// a list, a figure caption, a running header.
final class MockDocumentProvider: DocumentProviding, @unchecked Sendable {
    let url: URL
    let isMock = true
    let pageCount = 4
    let fingerprint: String

    private let layouts: [PcPageLayout]
    private let documentStructure: PcDocumentStructure

    init(url: URL) {
        self.url = url
        self.fingerprint = "mock:\(url.path)"
        var pages: [PcPageLayout] = []
        var headings: [PcHeading] = []
        let bodySize = 10.5

        func font(_ size: Double, _ bold: Bool = false, _ name: String = "NewYork-Regular") -> PcFont {
            PcFont(name: name, size: size, bold: bold, italic: false, monospace: false)
        }

        func word(_ text: String, x: Double, y: Double, w: Double, size: Double, bold: Bool) -> PcWord {
            PcWord(text: text, bbox: PcRect(x: x, y: y, w: w, h: size * 1.15),
                   size: size, bold: bold, italic: false, font: bold ? "NewYork-Bold" : "NewYork-Regular")
        }

        func line(_ text: String, x: Double, y: Double, size: Double, bold: Bool = false) -> PcLine {
            var words: [PcWord] = []
            var cursor = x
            for part in text.split(separator: " ") {
                let w = Double(part.count) * size * 0.52
                words.append(word(String(part), x: cursor, y: y, w: w, size: size, bold: bold))
                cursor += w + size * 0.28
            }
            let bbox = PcRect.union(words.map(\.bbox))
            return PcLine(bbox: bbox, text: text, baselineY: y + size * 0.8, words: words)
        }

        func block(_ id: String, _ kind: PcBlockKind, level: Int, _ lines: [PcLine],
                   size: Double, bold: Bool = false, confidence: Double = 0.9) -> PcBlock {
            let bbox = PcRect.union(lines.map(\.bbox))
            return PcBlock(id: id, kind: kind, level: level, text: lines.map(\.text).joined(separator: " "),
                           bbox: bbox, font: font(size, bold), confidence: confidence, lines: lines)
        }

        let pageSize = (w: 595.0, h: 842.0)

        // --- page 1 ---
        var blocks: [PcBlock] = []
        var y = 90.0
        let title = block("p0b0", .heading, level: 1, [line("Folio demo document (PDF)", x: 64, y: y, size: 24, bold: true)],
                          size: 24, bold: true, confidence: 0.99)
        blocks.append(title)
        headings.append(PcHeading(id: title.id, page: 0, level: 1, title: title.text, bbox: title.bbox, source: "heuristic"))
        y += 52
        let chap = block("p0b1", .heading, level: 2, [line("Chapter 1. Document Structure", x: 64, y: y, size: 15, bold: true)],
                         size: 15, bold: true)
        blocks.append(chap)
        headings.append(PcHeading(id: chap.id, page: 0, level: 2, title: chap.text, bbox: chap.bbox, source: "heuristic"))
        y += 34
        for i in 0..<5 {
            let text = "This is demo paragraph number \(i + 1). It exists so the interface "
                + "looks like a real document: there are line breaks, indents and a regular "
                + "body text size."
            let wrapped = Self.wrap(text, width: 78)
            let lines = wrapped.enumerated().map { idx, s in line(s, x: 64, y: y + Double(idx) * 16, size: bodySize) }
            blocks.append(block("p0b\(blocks.count)", .body, level: 0, lines, size: bodySize))
            y += Double(wrapped.count) * 16 + 10
        }
        blocks.append(block("p0b\(blocks.count)", .list, level: 0,
                            [line("• First list item", x: 72, y: y, size: bodySize),
                             line("• Second list item", x: 72, y: y + 16, size: bodySize)], size: bodySize))
        y += 46
        blocks.append(block("p0b\(blocks.count)", .caption, level: 0,
                            [line("Fig. 1. Example figure caption", x: 64, y: y, size: 9)], size: 9))
        pages.append(PcPageLayout(index: 0, width: pageSize.w, height: pageSize.h, rotation: 0,
                                  bodyFontSize: bodySize, blocks: blocks))

        // --- page 2 ---
        blocks = []
        y = 90
        let h22 = block("p1b0", .heading, level: 2, [line("1.1. Headings and Levels", x: 64, y: y, size: 15, bold: true)],
                        size: 15, bold: true)
        blocks.append(h22)
        headings.append(PcHeading(id: h22.id, page: 1, level: 2, title: h22.text, bbox: h22.bbox, source: "heuristic"))
        y += 34
        for i in 0..<6 {
            let text = "Headings are detected by font size and weight, as well as by "
                + "vertical spacing. Level \(i + 1) is a demo line."
            let lines = Self.wrap(text, width: 78).enumerated().map { idx, s in
                line(s, x: 64, y: y + Double(idx) * 16, size: bodySize)
            }
            blocks.append(block("p1b\(blocks.count)", .body, level: 0, lines, size: bodySize))
            y += Double(lines.count) * 16 + 10
        }
        pages.append(PcPageLayout(index: 1, width: pageSize.w, height: pageSize.h, rotation: 0,
                                  bodyFontSize: bodySize, blocks: blocks))

        // --- page 3 ---
        blocks = []
        y = 90
        let h23 = block("p2b0", .heading, level: 2, [line("1.2. Force Click and Dictionary", x: 64, y: y, size: 15, bold: true)],
                        size: 15, bold: true)
        blocks.append(h23)
        headings.append(PcHeading(id: h23.id, page: 2, level: 2, title: h23.text, bbox: h23.bbox, source: "heuristic"))
        y += 34
        for i in 0..<7 {
            let text = "Force click a word like “dictionary” or any other word to open "
                + "the system definition panel. It is the same mechanism as in Preview and Books. Line \(i + 1)."
            let lines = Self.wrap(text, width: 78).enumerated().map { idx, s in
                line(s, x: 64, y: y + Double(idx) * 16, size: bodySize)
            }
            blocks.append(block("p2b\(blocks.count)", .body, level: 0, lines, size: bodySize))
            y += Double(lines.count) * 16 + 10
        }
        pages.append(PcPageLayout(index: 2, width: pageSize.w, height: pageSize.h, rotation: 0,
                                  bodyFontSize: bodySize, blocks: blocks))

        // --- page 4 (no headings) ---
        blocks = []
        y = 90
        for i in 0..<40 {
            let lines = [line("Demo line without markup \(i + 1).", x: 64, y: y, size: bodySize)]
            blocks.append(block("p3b\(blocks.count)", .body, level: 0, lines, size: bodySize))
            y += 16
        }
        pages.append(PcPageLayout(index: 3, width: pageSize.w, height: pageSize.h, rotation: 0,
                                  bodyFontSize: bodySize, blocks: blocks))

        self.layouts = pages
        self.documentStructure = PcDocumentStructure(
            title: url.deletingPathExtension().lastPathComponent,
            pageCount: pages.count,
            tagged: false,
            headings: headings,
            outline: headings.map { PcOutlineItem(title: $0.title, page: $0.page, level: max(0, $0.level - 1)) }
        )
    }

    private static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > width {
                lines.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    func structure() throws -> PcDocumentStructure { documentStructure }

    func pageLayout(_ index: Int) throws -> PcPageLayout {
        guard index >= 0, index < pageCount else { throw PdfCoreError.badResponse("page out of range") }
        return layouts[index]
    }

    func pageSize(_ index: Int) throws -> CGSize {
        let layout = try pageLayout(index)
        return CGSize(width: layout.width, height: layout.height)
    }

    func render(_ index: Int, scale: Double) throws -> CGImage {
        let layout = try pageLayout(index)
        let w = max(1, Int((layout.width * scale).rounded()))
        let h = max(1, Int((layout.height * scale).rounded()))
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PdfCoreError.badResponse("mock context")
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.setStrokeColor(red: 0.85, green: 0.85, blue: 0.87, alpha: 1)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 0.5, y: 0.5, width: layout.width - 1, height: layout.height - 1))
        for block in layout.blocks {
            let color = block.kind.debugColor
            ctx.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: block.kind == .body ? 0.35 : 0.55)
            for line in block.lines {
                ctx.fill(CGRect(x: line.bbox.x, y: layout.height - line.bbox.maxY,
                                width: line.bbox.w, height: line.bbox.h * 0.62))
            }
        }
        guard let image = ctx.makeImage() else { throw PdfCoreError.badResponse("mock image") }
        return image
    }

    func search(_ query: String) throws -> [PcSearchHit] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var hits: [PcSearchHit] = []
        for layout in layouts {
            for block in layout.blocks where block.text.lowercased().contains(q) {
                hits.append(PcSearchHit(page: layout.index, rects: [block.bbox], snippet: block.text))
            }
        }
        return hits
    }
}
