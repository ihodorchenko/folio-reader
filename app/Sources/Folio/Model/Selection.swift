import Foundation
import CoreGraphics

/// Выделение в координатах страницы (точки PDF, origin — левый верхний угол).
/// Живёт в модели, чтобы ⌘C, контекстное меню и снапшот-самотесты видели одно и то же.
struct Selection: Equatable, Sendable {
    var page: Int
    var rects: [PcRect]
    var text: String
    /// Индексы слов в порядке чтения (нужно словарю: ⌘D берёт слово из выделения).
    var wordIndices: [Int] = []

    var isEmpty: Bool { rects.isEmpty || text.isEmpty }

    static func empty(page: Int = 0) -> Selection {
        Selection(page: page, rects: [], text: "")
    }
}
