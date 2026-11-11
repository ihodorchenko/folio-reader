import SwiftUI
import AppKit

enum ScrollCoordinateSpace {
    static let pages = "folio.pages"
}

/// Координаты нижних/верхних краёв страниц внутри скролла (для currentPage).
struct PageFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Непрерывный вертикальный скролл страниц с ленивой загрузкой.
struct DetailView: View {
    let model: ReaderModel

    @State private var viewportHeight: CGFloat = 0
    @State private var pinchBaseZoom: Double = 0

    var body: some View {
        GeometryReader { geometry in
            Group {
                if model.doc == nil && !model.isLoading {
                    emptyState
                } else {
                    pageScrollView
                }
            }
            .onAppear {
                viewportHeight = geometry.size.height
                model.updateAvailableWidth(geometry.size.width)
            }
            .onChange(of: geometry.size) { _, size in
                viewportHeight = size.height
                model.updateAvailableWidth(size.width)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Скролл страниц

    private var pageScrollView: some View {
        ScrollViewReader { proxy in
            // Обе оси: при зуме больше fit-width страница должна прокручиваться
            // и по горизонтали (как в Preview), иначе правый край обрезается.
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: FolioUI.pageSpacing) {
                    ForEach(0..<max(model.pageCount, 0), id: \.self) { page in
                        PageCard(model: model, page: page)
                    }
                }
                .padding(.horizontal, FolioUI.contentPadding)
                .padding(.vertical, FolioUI.pageVerticalPadding)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: ScrollCoordinateSpace.pages)
            .onChange(of: model.scrollRequest) { _, request in
                guard let request else { return }
                performScroll(proxy: proxy, request: request)
            }
            .onPreferenceChange(PageFramesKey.self) { frames in
                updateCurrentPage(frames: frames)
            }
            .simultaneousGesture(pinchGesture)
        }
        .overlay(alignment: .bottomTrailing) {
            pageStatusBadge
                .padding(12)
        }
    }

    private var pageStatusBadge: some View {
        Text("\(min(model.currentPage + 1, max(model.pageCount, 1))) / \(max(model.pageCount, 0))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.08)))
            .opacity(model.pageCount > 0 ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func performScroll(proxy: ScrollViewProxy, request: ScrollRequest) {
        guard model.pageCount > 0 else { return }
        let page = min(max(request.page, 0), model.pageCount - 1)
        let pageHeight = Double(model.pageSize(page).height)
        var fraction: Double = 0
        if let bbox = request.bbox, pageHeight > 0 {
            fraction = min(max(Double(bbox.y) / pageHeight, 0), 1)
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            proxy.scrollTo(page, anchor: UnitPoint(x: 0.5, y: fraction))
        }
    }

    private func updateCurrentPage(frames: [Int: CGRect]) {
        guard viewportHeight > 0, !frames.isEmpty else { return }
        let center = viewportHeight / 2
        guard let best = frames.min(by: { lhs, rhs in
            abs(lhs.value.midY - center) < abs(rhs.value.midY - center)
        }) else { return }
        let frame = best.value
        // Активный заголовок определяем по верхней части вьюпорта (≈25% высоты) —
        // так он совпадает с тем, что читатель видит на экране, а не с центром.
        let anchorY = min(viewportHeight * 0.25, 260)
        let progress = frame.height > 1 ? (anchorY - frame.minY) / frame.height : 0
        model.updateVisiblePage(best.key, progress: Double(min(max(progress, 0), 1)))
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if pinchBaseZoom <= 0 { pinchBaseZoom = model.zoom }
                model.setZoom(pinchBaseZoom * Double(value.magnification))
            }
            .onEnded { _ in pinchBaseZoom = 0 }
    }

    // MARK: - Пустое состояние

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Документ не открыт")
                .font(.title3.weight(.semibold))
            Text("Откройте PDF: ⌘O, перетащите файл в окно\nили запустите Folio с путём к файлу.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Открыть PDF…") { model.presentOpenPanel() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Одна страница в скролле

struct PageCard: View {
    let model: ReaderModel
    let page: Int

    var body: some View {
        let size = model.pageSize(page)
        let zoom = model.zoom
        let layout = model.pageLayouts[page]
        let selection = model.selection?.page == page ? model.selection : nil
        let searchRects = model.searchRects(for: page)
        let frameWidth = max(size.width * zoom, 1)
        let frameHeight = max(size.height * zoom, 1)

        PageView(model: model,
                 pageIndex: page,
                 pageSize: size,
                 zoom: zoom,
                 layout: layout,
                 selection: selection,
                 searchRects: searchRects,
                 debugMode: model.debugMode,
                 renderScale: model.renderScale,
                 documentIdentity: model.docIdentity)
            .frame(width: frameWidth, height: frameHeight)
            .background(
                Rectangle()
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: Color.black.opacity(0.22), radius: 9, x: 0, y: 2)
            )
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: PageFramesKey.self,
                                           value: [page: geo.frame(in: .named(ScrollCoordinateSpace.pages))])
                }
            )
            .help("Страница \(page + 1)")
            .task(id: model.docIdentity + ":" + String(page)) {
                model.requestLayout(page)
                model.prefetch(around: page)
            }
    }
}
