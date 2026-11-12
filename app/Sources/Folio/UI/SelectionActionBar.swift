import SwiftUI

/// Floating action bar for a multi-word selection: Dictionary / Translate / Copy.
///
/// It is shown above the selection while `ReaderModel.isSelectionBarVisible` is true and
/// disappears as soon as another action takes over — a drag, the context menu, the menu bar,
/// copying, the dictionary or the translation panel (see `ReaderModel.dismissSelectionBar()`).
struct SelectionActionBar: View {
    let model: ReaderModel

    /// Rough width used by the page card to keep the bar inside the page bounds.
    static let estimatedWidth: CGFloat = 250

    var body: some View {
        HStack(spacing: 2) {
            action("Dictionary", systemImage: "character.book.closed", perform: model.lookUpSelection)
            separator
            action("Translate", systemImage: "character.bubble", perform: model.translateSelection)
            separator
            action("Copy", systemImage: "doc.on.doc", perform: { _ = model.copySelection() })
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.18), radius: 7, x: 0, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Selection actions"))
    }

    private var separator: some View {
        Divider()
            .frame(height: 14)
            .opacity(0.6)
    }

    private func action(_ key: String, systemImage: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(L10n.t(key))
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t(key))
        .accessibilityLabel(L10n.t(key))
    }
}
