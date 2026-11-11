import Foundation
import CoreGraphics

/// Плоское представление слов страницы в порядке чтения.
/// Используется для hit-testing (hover / force click), drag-выделения и ⌘C.
struct PageTextGeometry {
    struct WordRef {
        let word: PcWord
        /// Глобальный (по странице) номер строки — нужен, чтобы склеивать выделение переносом строки.
        let lineID: Int
        let baselineY: Double
        let order: Int
    }

    let page: Int
    let pageSize: CGSize
    let words: [WordRef]

    init(layout: PcPageLayout) {
        var refs: [WordRef] = []
        var lineID = 0
        for block in layout.blocks {
            for line in block.lines {
                for word in line.words {
                    refs.append(WordRef(word: word, lineID: lineID,
                                        baselineY: line.baselineY, order: refs.count))
                }
                lineID += 1
            }
        }
        self.page = layout.index
        self.pageSize = CGSize(width: layout.width, height: layout.height)
        self.words = refs
    }

    var isEmpty: Bool { words.isEmpty }

    // MARK: - Hit-testing

    /// Слово под точкой страницы. Сначала точное попадание в bbox,
    /// затем — ближайшее слово в пределах допуска (для «провалов» между словами).
    func wordIndex(at point: CGPoint, tolerance: CGFloat = 0) -> Int? {
        for (index, ref) in words.enumerated() where ref.word.bbox.contains(point) {
            return index
        }
        guard tolerance > 0 else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for (index, ref) in words.enumerated() {
            let d = PageTextGeometry.distanceToRect(point, ref.word.bbox)
            if d <= tolerance, best == nil || d < best!.distance {
                best = (index, d)
            }
        }
        return best?.index
    }

    /// Ближайшее слово без ограничения по расстоянию — последний шанс для ⌘D.
    func nearestWordIndex(to point: CGPoint) -> Int? {
        guard !words.isEmpty else { return nil }
        var best: (index: Int, distance: CGFloat) = (-1, .greatestFiniteMagnitude)
        for (index, ref) in words.enumerated() {
            let d = PageTextGeometry.distanceToRect(point, ref.word.bbox)
            if d < best.distance { best = (index, d) }
        }
        return best.index >= 0 ? best.index : nil
    }

    static func distanceToRect(_ p: CGPoint, _ r: PcRect) -> CGFloat {
        let dx = max(max(r.x - Double(p.x), 0), Double(p.x) - r.maxX)
        let dy = max(max(r.y - Double(p.y), 0), Double(p.y) - r.maxY)
        return CGFloat((dx * dx + dy * dy).squareRoot())
    }

    // MARK: - Выделение

    /// Выделение слов в диапазоне порядка чтения (i...j, включительно).
    func selection(from i: Int, to j: Int) -> Selection {
        guard !words.isEmpty else { return .empty(page: page) }
        let lo = max(0, min(i, j))
        let hi = min(words.count - 1, max(i, j))
        guard lo <= hi else { return .empty(page: page) }

        var rects: [PcRect] = []
        var indices: [Int] = []
        var text = ""
        var previousLine = -1
        for index in lo...hi {
            let ref = words[index]
            if ref.lineID != previousLine {
                if !text.isEmpty { text += "\n" }
                previousLine = ref.lineID
            } else if !text.isEmpty {
                text += " "
            }
            text += ref.word.text
            rects.append(ref.word.bbox)
            indices.append(index)
        }
        return Selection(page: page, rects: rects, text: text, wordIndices: indices)
    }

    func word(at index: Int) -> PcWord? {
        guard index >= 0, index < words.count else { return nil }
        return words[index].word
    }

    /// Объединённые прямоугольники по строкам — компактнее для отрисовки.
    func lineRects(for selection: Selection) -> [PcRect] {
        guard !selection.rects.isEmpty else { return [] }
        var result: [PcRect] = []
        var current: PcRect?
        for rect in selection.rects {
            if let c = current, abs(c.midY - rect.midY) < max(2, rect.h * 0.6) {
                current = PcRect.union([c, rect])
            } else {
                if let c = current { result.append(c) }
                current = rect
            }
        }
        if let c = current { result.append(c) }
        return result
    }
}
