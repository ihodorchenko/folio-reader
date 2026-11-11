import Foundation
import CoreGraphics

/// Selection in page coordinates (PDF points, origin at the top-left corner).
/// Lives in the model so ⌘C, the context menu and the snapshot self-tests all see the same thing.
struct Selection: Equatable, Sendable {
    var page: Int
    var rects: [PcRect]
    var text: String
    /// Reading-order word indices (the dictionary needs them: ⌘D takes the word from the selection).
    var wordIndices: [Int] = []

    var isEmpty: Bool { rects.isEmpty || text.isEmpty }

    static func empty(page: Int = 0) -> Selection {
        Selection(page: page, rects: [], text: "")
    }
}
