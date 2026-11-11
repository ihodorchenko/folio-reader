import SwiftUI
import AppKit

/// Shared constants and colors for the UI layer.
enum FolioUI {
    static let pageSpacing: CGFloat = 28
    static let contentPadding: CGFloat = 40
    static let pageVerticalPadding: CGFloat = 26
}

extension Color {
    static var folioPageBackground: Color { Color(nsColor: .underPageBackgroundColor) }
    static var folioSidebarBackground: Color { Color(nsColor: .windowBackgroundColor) }
}
