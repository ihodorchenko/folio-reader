import Foundation
import CoreGraphics

/// What a selected run of words is structurally: one word, a phrase, a sentence, a paragraph (one
/// block of the layout) or a passage of several blocks. The text of the selection is rebuilt for
/// that unit — the visual line breaks of the PDF are not part of it — and the bubble names it.
enum SelectionUnit: String, Sendable {
    case word
    case phrase
    case sentence
    case paragraph
    case passage

    var localizedTitle: String {
        switch self {
        case .word: return L10n.t("Word")
        case .phrase: return L10n.t("Phrase")
        case .sentence: return L10n.t("Sentence")
        case .paragraph: return L10n.t("Paragraph")
        case .passage: return L10n.t("Passage")
        }
    }
}

/// Selection in page coordinates (PDF points, origin at the top-left corner).
/// Lives in the model so ⌘C, the context menu and the snapshot self-tests all see the same thing.
struct Selection: Equatable, Sendable {
    var page: Int
    var rects: [PcRect]
    var text: String
    /// Reading-order word indices (the dictionary needs them: ⌘D takes the word from the selection).
    var wordIndices: [Int] = []
    /// Structure of the fragment — see `SelectionUnit` (the caption of the translation bubble).
    var unit: SelectionUnit = .phrase

    var isEmpty: Bool { rects.isEmpty || text.isEmpty }

    static func empty(page: Int = 0) -> Selection {
        Selection(page: page, rects: [], text: "")
    }
}
