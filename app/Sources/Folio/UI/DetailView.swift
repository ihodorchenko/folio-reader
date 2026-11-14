import SwiftUI
import AppKit

enum ScrollCoordinateSpace {
    static let pages = "folio.pages"
}

/// Coordinates of the bottom/top edges of pages inside the scroll (for currentPage).
struct PageFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Continuous vertical page scroll with lazy loading.
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

    // MARK: - Page scrolling

    private var pageScrollView: some View {
        ScrollViewReader { proxy in
            // Both axes: when zoomed beyond fit-width the page must scroll
            // horizontally too (like Preview), otherwise the right edge is clipped.
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
        folioLog("scroll: page \(page + 1), fraction \(String(format: "%.2f", fraction)), token=\(request.token)")
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
        // The active heading is determined by the upper part of the viewport (≈25% of its height) —
        // so it matches what the reader sees on screen rather than the center.
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L10n.t("No Document Open"))
                .font(.title3.weight(.semibold))
            Text(L10n.t("Open a PDF with ⌘O, drag a file into the window,\nor launch Folio with a file path."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.t("Open PDF…")) { model.presentOpenPanel() }
                .controlSize(.large)
                .padding(.top, 4)

            let recent = RecentDocumentsStore.shared.documents
            if !recent.isEmpty {
                VStack(spacing: 4) {
                    Text(L10n.t("Recent"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(recent.prefix(6)) { document in
                        Button {
                            model.open(url: document.url)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 11))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(document.title)
                                        .font(.system(size: 11.5))
                                        .lineLimit(1)
                                    Text(document.folder)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .frame(maxWidth: 360, alignment: .leading)
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - One page in the scroll

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
            .overlay(alignment: .topLeading) {
                if model.isSelectionBarVisible, let selection, selection.page == page, !selection.rects.isEmpty {
                    GeometryReader { geometry in
                        SelectionActionBar(model: model)
                            .fixedSize()
                            .position(x: barCenterX(selection: selection, pageWidth: geometry.size.width),
                                      y: barCenterY(selection: selection, pageHeight: geometry.size.height))
                    }
                }
            }
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
            .help(L10n.t("Page %ld", page + 1))
            // Translation bubble: a system popover anchored to the translated fragment, like the
            // Look Up / Translation bubble of the system apps — Esc or a click outside dismisses it.
            .popover(isPresented: translationBinding,
                     attachmentAnchor: .rect(.rect(translationAnchorRect)),
                     arrowEdge: .trailing) {
                TranslationPopover(model: model)
            }
            .task(id: model.docIdentity + ":" + String(page)) {
                model.requestLayout(page)
                model.prefetch(around: page)
            }
    }

    // MARK: - Translation popover anchor

    /// Only the page the translated fragment lives on presents the bubble.
    private var translationBinding: Binding<Bool> {
        Binding(
            get: { model.translation.isPanelPresented && model.translation.anchorPage == page },
            set: { isPresented in
                if !isPresented { model.translation.isPanelPresented = false }
            }
        )
    }

    /// Union of the selection rects in the page's own coordinate space (zoomed), so the popover
    /// arrow points at the words that were translated.
    private var translationAnchorRect: CGRect {
        guard model.translation.anchorPage == page else { return .zero }
        let zoom = model.zoom
        let rects = model.translation.anchorRects
        guard !rects.isEmpty else {
            // No rects (for example an explanation on older systems) — point at the page top.
            return CGRect(x: 24, y: 40, width: 2, height: 20)
        }
        let union = PcRect.union(rects)
        return CGRect(x: CGFloat(union.x) * zoom,
                      y: CGFloat(union.y) * zoom,
                      width: max(CGFloat(union.w) * zoom, 2),
                      height: max(CGFloat(union.h) * zoom, 2))
    }

    /// Horizontal center of the action bar: above the selection, kept inside the page.
    private func barCenterX(selection: Selection, pageWidth: CGFloat) -> CGFloat {
        let rect = PcRect.union(selection.rects)
        let raw = CGFloat(rect.midX) * model.zoom
        let half = SelectionActionBar.estimatedWidth / 2 + 6
        return min(max(raw, half), max(pageWidth - half, half))
    }

    /// Vertical center of the action bar: just above the selection, or below it near the page top.
    private func barCenterY(selection: Selection, pageHeight: CGFloat) -> CGFloat {
        let rect = PcRect.union(selection.rects)
        let top = CGFloat(rect.y) * model.zoom
        let bottom = CGFloat(rect.maxY) * model.zoom
        let half: CGFloat = 16
        let above = top - half - 10
        if above >= half { return above }
        return min(bottom + half + 10, max(pageHeight - half, half))
    }
}
