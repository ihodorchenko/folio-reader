import SwiftUI
import AppKit

/// Вкладка «Страницы»: миниатюры с ленивой подгрузкой.
struct ThumbnailsSidebarView: View {
    let model: ReaderModel

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 150), spacing: 10, alignment: .top)]

    var body: some View {
        Group {
            if model.pageCount == 0 {
                ProgressView("Загрузка страниц…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(0..<model.pageCount, id: \.self) { page in
                            thumbnail(for: page)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func thumbnail(for page: Int) -> some View {
        ThumbnailCell(model: model, page: page)
    }
}

private struct ThumbnailCell: View {
    let model: ReaderModel
    let page: Int

    @State private var image: CGImage?

    private var isCurrent: Bool { model.currentPage == page }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .textBackgroundColor))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(1)
                } else {
                    Image(systemName: "doc")
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(0.72, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isCurrent ? Color.accentColor : Color.black.opacity(0.14),
                                  lineWidth: isCurrent ? 2.5 : 0.75)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 2, x: 0, y: 1)

            Text("\(page + 1)")
                .font(.system(size: 10, weight: isCurrent ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            folioLog("sidebar: переход к странице \(page + 1) из миниатюр")
            model.scrollTo(page: page, bbox: nil)
        }
        .help("Страница \(page + 1)")
        .task(id: model.docIdentity + ":thumb:" + String(page)) {
            loadThumbnail()
        }
        .onChange(of: model.currentPage) { _, _ in
            // миниатюры не перерисовываем, обновляется только индикатор
        }
    }

    private func loadThumbnail() {
        guard let doc = model.doc else { return }
        image = nil
        let scale = 0.18 * Double(model.backingScale)
        let prefix = model.thumbnailPrefix
        let key = RenderStore.key(prefix, page, scale)
        if let cached = RenderStore.shared.cached(key) {
            image = cached
            return
        }
        let immediate = RenderStore.shared.image(page: page, scale: scale, provider: doc, prefix: prefix) { rendered in
            if let rendered { image = rendered }
        }
        // Синхронный режим (снапшот) отдаёт готовую миниатюру сразу.
        if let immediate { image = immediate }
    }
}
