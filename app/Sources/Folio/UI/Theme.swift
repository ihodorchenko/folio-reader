import SwiftUI
import AppKit

/// Общие константы и цвета UI-слоя.
enum FolioUI {
    static let pageSpacing: CGFloat = 28
    static let contentPadding: CGFloat = 40
    static let pageVerticalPadding: CGFloat = 26
}

extension Color {
    static var folioPageBackground: Color { Color(nsColor: .underPageBackgroundColor) }
    static var folioSidebarBackground: Color { Color(nsColor: .windowBackgroundColor) }
}
