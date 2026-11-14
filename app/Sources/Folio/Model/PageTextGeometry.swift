import Foundation
import CoreGraphics

/// Flat, reading-order representation of a page's words.
/// Used for hit-testing (hover / force click), drag selection and ⌘C.
struct PageTextGeometry {
    struct WordRef {
        let word: PcWord
        /// Global (per page) line number — a break inside a block is only a visual line break.
        let lineID: Int
        /// Block (paragraph) of the word: a new block is a paragraph boundary, a new line is not.
        let blockID: Int
        let blockKind: PcBlockKind
        let baselineY: Double
        let order: Int
    }

    let page: Int
    let pageSize: CGSize
    let words: [WordRef]

    init(layout: PcPageLayout) {
        var refs: [WordRef] = []
        var lineID = 0
        for (blockID, block) in layout.blocks.enumerated() {
            for line in block.lines {
                for word in line.words {
                    refs.append(WordRef(word: word, lineID: lineID, blockID: blockID,
                                        blockKind: block.kind, baselineY: line.baselineY,
                                        order: refs.count))
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

    /// Word under a page point. An exact bbox hit comes first,
    /// then the nearest word within the tolerance (for the gaps between words).
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

    /// Nearest word with no distance limit — the last resort for ⌘D.
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

    // MARK: - Selection

    /// Selects words in the reading-order range (i...j, inclusive).
    ///
    /// The text is rebuilt from the layout structure, not from the visual line breaks: a word, a
    /// phrase, a sentence or a paragraph is one fragment. The system translator segments on line
    /// breaks, so a sentence split over two lines would otherwise arrive as two paragraphs.
    func selection(from i: Int, to j: Int) -> Selection {
        guard !words.isEmpty else { return .empty(page: page) }
        let lo = max(0, min(i, j))
        let hi = min(words.count - 1, max(i, j))
        guard lo <= hi else { return .empty(page: page) }

        var refs: [WordRef] = []
        var rects: [PcRect] = []
        var indices: [Int] = []
        for index in lo...hi {
            let ref = words[index]
            refs.append(ref)
            rects.append(ref.word.bbox)
            indices.append(index)
        }
        let text = Self.joinedText(of: refs)
        return Selection(page: page, rects: rects, text: text, wordIndices: indices,
                         unit: unit(of: refs, text: text))
    }

    // MARK: - Fragment text from the structure

    /// Reading-order text of a run of words: words of one line are separated by a space, a visual
    /// line break inside a paragraph becomes a space (a soft hyphen at the break is dropped, so
    /// "trans-" + "former" becomes "transformer"), and a new block is a paragraph break.
    static func joinedText(of refs: [WordRef]) -> String {
        var result = ""
        var previous: WordRef?
        for ref in refs {
            let word = ref.word.text.replacingOccurrences(of: "\u{00AD}", with: "")
            guard let prev = previous else {
                result = word
                previous = ref
                continue
            }
            if ref.blockID != prev.blockID, isParagraphBreak(from: ref, after: result, next: word) {
                result += "\n\n" + word
            } else if ref.lineID != prev.lineID || ref.blockID != prev.blockID {
                result = joiningLineBreak(result, next: word)
            } else {
                result += " " + word
            }
            previous = ref
        }
        return result
    }

    /// "trans-" + "former" → "transformer"; "US-" + "Based" → "US-Based"; otherwise a space.
    private static func joiningLineBreak(_ text: String, next: String) -> String {
        guard let last = text.last, let first = next.first else { return text + next }
        guard softHyphens.contains(last) else { return text + " " + next }
        if first.isLowercase {
            // The break split a single word: drop the hyphen and glue the halves together.
            return String(text.dropLast()) + next
        }
        if first.isLetter || first.isNumber {
            // The hyphen belongs to the word itself ("US-", "e-"): keep it, drop only the break.
            return text + next
        }
        return text + " " + next
    }

    private static let softHyphens: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{00AD}"]
    private static let sentenceTerminals: Set<Character> = [".", "!", "?", "…"]
    private static let paragraphTerminals: Set<Character> = [".", "!", "?", "…", ":", ";", "\"", "»", "”", ")"]

    /// A block boundary is a paragraph break when the previous block closed a sentence; a block
    /// that continues a lowercase sentence is the same paragraph split by the layout. List items,
    /// table cells and code lines are separate by definition, whatever letter they start with.
    private static func isParagraphBreak(from ref: WordRef, after text: String, next: String) -> Bool {
        switch ref.blockKind {
        case .list, .table, .code, .reference: return true
        default: break
        }
        guard let last = text.last, let first = next.first else { return true }
        if paragraphTerminals.contains(last) { return true }
        return first.isUppercase
    }

    /// What the fragment is: one word, a phrase, a sentence, a paragraph or a passage of blocks.
    ///
    /// A fragment counts as a paragraph only when it *is* the block — a sentence cut in the middle
    /// is a phrase, not a paragraph of its own.
    func unit(of refs: [WordRef], text: String) -> SelectionUnit {
        guard !refs.isEmpty else { return .phrase }
        if refs.count == 1 { return .word }
        let blocks = Set(refs.map(\.blockID))
        if blocks.count > 1 { return .passage }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsSentence = trimmed.last.map { Self.sentenceTerminals.contains($0) } ?? false
        if endsSentence, !Self.containsSentenceBreak(trimmed) { return .sentence }
        guard let blockID = blocks.first,
              Set(refs.map(\.lineID)).count > 1,
              refs.count == words.filter({ $0.blockID == blockID }).count else {
            return .phrase
        }
        return .paragraph
    }

    /// More than one sentence inside the fragment ("Hello. World.").
    private static func containsSentenceBreak(_ text: String) -> Bool {
        let characters = Array(text)
        guard characters.count > 1 else { return false }
        for index in 0..<(characters.count - 1) where sentenceTerminals.contains(characters[index]) {
            let next = characters[index + 1]
            if next == " " || next == "\n" { return true }
        }
        return false
    }

    func word(at index: Int) -> PcWord? {
        guard index >= 0, index < words.count else { return nil }
        return words[index].word
    }

    /// Rects merged per line — more compact for drawing.
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
