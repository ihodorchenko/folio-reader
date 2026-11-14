import Foundation
import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

// MARK: - Sidebar tabs

/// Debug overlay mode: off / elements (kind+level+confidence) / boxes around each word.
enum DebugOverlayMode: String, CaseIterable, Identifiable {
    case off
    case blocks
    case words

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .off: return L10n.t("Layout off")
        case .blocks: return L10n.t("Element layout")
        case .words: return L10n.t("Word boxes")
        }
    }
}

enum SidebarMode: String, CaseIterable, Identifiable {
    case structure
    case thumbnails
    case search

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .structure: return L10n.t("Structure")
        case .thumbnails: return L10n.t("Pages")
        case .search: return L10n.t("Search")
        }
    }

    var symbol: String {
        switch self {
        case .structure: return "list.bullet.indent"
        case .thumbnails: return "square.grid.2x2"
        case .search: return "magnifyingglass"
        }
    }
}

// MARK: - Structure tree item

struct HeadingRow: Identifiable, Hashable {
    let id: String
    let level: Int
    let title: String
    let page: Int
    let bbox: PcRect
}

// MARK: - Scroll request

struct ScrollRequest: Equatable {
    let page: Int
    let bbox: PcRect?
    let token: Int
}

// MARK: - Reader model

/// All window state logic: document, structure, pages, zoom, search, selection.
/// Rendering/parsing runs in the background (`Task.detached`); mutations run on the main actor.
@Observable
@MainActor
final class ReaderModel {
    /// All live models (one per window). Weak references: the scene owns the model.
    @MainActor static let registry = NSHashTable<ReaderModel>.weakObjects()

    /// Model of the active window — for ⌘C/⌘D from the event monitors and menu items.
    @MainActor static var active: ReaderModel? {
        if let window = NSApp.keyWindow, let model = model(for: window) { return model }
        return registry.allObjects.first
    }

    /// Model bound to a specific window (each window has its own document).
    @MainActor static func model(for window: NSWindow?) -> ReaderModel? {
        guard let window else { return nil }
        return registry.allObjects.first { $0.window === window }
    }

    // MARK: Services: settings, speech, translation

    /// User settings (speech off by default, pair EN → RU).
    let settings = SettingsStore.shared
    /// Speech synthesis for selected text.
    let speech = SpeechService.shared
    /// State of the selected-fragment translation (the SwiftUI host creates the session).
    let translation = TranslationController()

    // MARK: Window

    /// Window this model lives in (set through `WindowAccessor`).
    private(set) weak var window: NSWindow?
    private var windowCloseObserver: NSObjectProtocol?
    private var windowResignObserver: NSObjectProtocol?
    private var windowBecomeObserver: NSObjectProtocol?

    // MARK: Document

    private(set) var doc: (any DocumentProviding)?
    private(set) var documentURL: URL?
    private(set) var isMock = false
    private(set) var isLoading = false
    var errorMessage: String?
    private(set) var docIdentity: String = ""

    // MARK: Structure and pages

    var structure: PcDocumentStructure?
    var pageLayouts: [Int: PcPageLayout] = [:]
    var pageSizes: [CGSize] = []
    var currentPage = 0
    /// 0…1 — how far the current page is scrolled (for the active heading).
    private(set) var currentPageProgress: Double = 0

    // MARK: Display

    var zoom: Double = 1.0
    var fitWidth = true
    var backingScale: CGFloat = 2.0
    private var availableWidth: CGFloat = 900
    var sidebarMode: SidebarMode = .structure
    var debugMode: DebugOverlayMode = .off
    var columnVisibility: NavigationSplitViewVisibility = .all
    var selectedHeadingID: String?

    // MARK: Search

    var searchQuery = ""
    var searchHits: [PcSearchHit] = []
    var isSearching = false
    var activeHitIndex: Int?
    var focusSearchRequest = 0

    // MARK: Selection

    var selection: Selection?

    // MARK: Snapshot/acceptance

    /// `--snapshot` only: the document is ready, the pages and the first page's layout are loaded.
    private(set) var snapshotMode = false

    // MARK: Internals

    private var loadTask: Task<Void, Never>?
    private var loadToken = UUID()
    private var layoutRequests = Set<Int>()
    private var geometryCache: [Int: PageTextGeometry] = [:]
    private var scrollToken = 0
    var scrollRequest: ScrollRequest?
    private var searchTask: Task<Void, Never>?
    private var didBootstrap = false
    /// Restoring the last book — only once per application launch.
    private static var hasRestoredLastDocument = false
    private var positionSaveTask: Task<Void, Never>?
    private var pendingRestorePosition: ReadingPosition?
    private var windowAttached = false

    // MARK: - Initialization

    init() {
        Self.registry.add(self)
    }

    /// The window became active: this is the book to restore on the next launch.
    func activate() {
        guard let url = documentURL else { return }
        ReadingPositionStore.setLastDocument(url)
    }

    /// Bind to the window: needed for the ⌘C/⌘D monitors, position saving and reports.
    func attach(window: NSWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window
        // Do not hand our windows to system restoration: otherwise on the next
        // launch macOS raises as many windows as were open.
        window.isRestorable = false
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
        }
        if let windowBecomeObserver {
            NotificationCenter.default.removeObserver(windowBecomeObserver)
        }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ReaderModel.model(for: window)?.persistReadingPosition()
            }
        }
        // The selection bar is a foreground affordance: hide it when the window goes away
        // and bring it back after the window becomes key again.
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ReaderModel.model(for: window)?.suppressSelectionBarForWindow()
            }
        }
        windowBecomeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ReaderModel.model(for: window)?.restoreSelectionBarAfterWindow()
            }
        }
        if !windowAttached {
            windowAttached = true
            folioLog("window: attached to model, document=\(documentURL?.lastPathComponent ?? "—")")
        }
    }

    /// Render cache key prefixes: the key carries the document fingerprint,
    /// so that after opening another PDF we do not show someone else's page.
    var pageRenderPrefix: String { "page:\(docIdentity)" }
    var thumbnailPrefix: String { "thumb:\(docIdentity)" }

    // MARK: - Derived values

    var pageCount: Int {
        if let doc { return doc.pageCount }
        return structure?.pageCount ?? 0
    }

    var documentTitle: String {
        if let title = structure?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let url = documentURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return "Folio"
    }

    var statusText: String {
        if isLoading { return L10n.t("Loading…") }
        guard doc != nil else { return errorMessage == nil ? L10n.t("No document") : L10n.t("Open failed") }
        var parts: [String] = []
        if isMock {
            parts.append(L10n.t("Core not built — demo document shown"))
        } else {
            parts.append(CoreLibrary.shared()?.versionString ?? "pdfcore")
        }
        parts.append(L10n.t("%ld pages", pageCount))
        if let structure {
            parts.append(L10n.t("headings: %ld", structure.headings.count))
            if structure.tagged { parts.append(L10n.t("tagged PDF")) }
        }
        return parts.joined(separator: " • ")
    }

    /// Page size estimate until the real sizes are loaded.
    var estimatedPageSize: CGSize {
        if let first = pageSizes.first, first.width > 1, first.height > 1 {
            return first
        }
        if let layout = pageLayouts[0], layout.width > 1, layout.height > 1 {
            return CGSize(width: layout.width, height: layout.height)
        }
        return CGSize(width: 612, height: 792)
    }

    func pageSize(_ index: Int) -> CGSize {
        guard index >= 0 else { return estimatedPageSize }
        if index < pageSizes.count {
            let size = pageSizes[index]
            if size.width > 1, size.height > 1 { return size }
        }
        return estimatedPageSize
    }

    /// Render scale in pixels per point: zoom × backing scale, capped at ~4096 px in width.
    var renderScale: CGFloat {
        let base = zoom * Double(backingScale)
        let width = Double(estimatedPageSize.width)
        guard width > 1 else { return CGFloat(base) }
        let maxPixelWidth = 4096.0
        return CGFloat(min(base, maxPixelWidth / width))
    }

    // MARK: - Sidebar structure

    var headingRows: [HeadingRow] {
        guard let structure else { return [] }
        return structure.headings.enumerated().map { index, heading in
            let id = heading.id.isEmpty ? "h-\(heading.page)-\(index)" : heading.id
            return HeadingRow(id: id,
                              level: max(1, min(heading.level, 6)),
                              title: heading.title.trimmingCharacters(in: .whitespacesAndNewlines),
                              page: heading.page,
                              bbox: heading.bbox)
        }
    }

    var computedActiveHeadingID: String? {
        let rows = headingRows
        guard !rows.isEmpty else { return nil }
        var result = rows[0].id
        for row in rows {
            if row.page < currentPage {
                result = row.id
                continue
            }
            guard row.page == currentPage else { continue }
            let height = max(Double(pageSize(row.page).height), 1)
            let fraction = Double(row.bbox.y) / height
            if fraction <= currentPageProgress + 0.02 {
                result = row.id
            }
        }
        return result
    }

    // MARK: - Opening a document

    /// Scene start: the document from the window value, from the pending queue, or the last opened one.
    func start(documentURL: URL?) {
        guard !didBootstrap, !snapshotMode else { return }
        didBootstrap = true
        WindowReport.event("model.start value=\(documentURL?.lastPathComponent ?? "—")")

        // 1. The document the window was created with (Finder "Open With" / ⌘N with a file).
        if let url = documentURL {
            open(url: url)
            return
        }
        // 2. A file that arrived before the first window appeared.
        if let pending = WindowRouter.shared.takePendingURL() {
            open(url: pending)
            return
        }
        // 3. A PDF from the command-line arguments (launched from a terminal).
        //    Take only *.pdf: flags like --window-report have values too.
        let candidates = CommandLine.arguments.dropFirst().filter {
            !$0.hasPrefix("-") && $0.lowercased().hasSuffix(".pdf")
        }
        if let path = candidates.first, FileManager.default.fileExists(atPath: path) {
            open(url: URL(fileURLWithPath: path))
            return
        }
        // 4. The last opened document — restore it with a small delay:
        //    the open event from Finder arrives within the first ~100 ms, and then the old book
        //    is not wanted (otherwise we got two app instances).
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.documentURL == nil, !Self.hasRestoredLastDocument else { return }
            Self.hasRestoredLastDocument = true
            guard let last = ReadingPositionStore.lastDocument() else { return }
            folioLog("restore: opening the last document \(last.path)")
            WindowReport.event("restore last document")
            self.open(url: last)
        }
        // 5. If nothing arrived — the empty state with the "Open…" button.
    }

    func open(url: URL) {
        WindowReport.event("model.open \(url.lastPathComponent)")
        // Do not lose the current document's position when switching to another book.
        persistReadingPosition()
        let savedPosition = snapshotMode ? nil : ReadingPositionStore.load(for: url)
        pendingRestorePosition = savedPosition
        ReadingPositionStore.setLastDocument(url)
        if !snapshotMode {
            RecentDocumentsStore.shared.note(url)
        }

        loadTask?.cancel()
        searchTask?.cancel()
        let token = UUID()
        loadToken = token

        documentURL = url
        doc = nil
        isMock = false
        docIdentity = ""
        structure = nil
        pageLayouts = [:]
        pageSizes = []
        geometryCache = [:]
        layoutRequests = []
        currentPage = 0
        selectedHeadingID = nil
        selection = nil
        searchQuery = ""
        searchHits = []
        activeHitIndex = nil
        scrollRequest = nil
        errorMessage = nil
        isLoading = true
        docIdentity = "loading:\(url.lastPathComponent)"
        RenderStore.shared.removeAll()
        folioLog("open: \(url.path) mode=\(PdfCore.isMockMode ? "mock (core not found)" : "core")")

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let provider = try await Task.detached(priority: .userInitiated) {
                    try PdfCore.open(url: url)
                }.value
                guard self.isCurrent(token) else { return }

                // The core is present but the file did not open → it returned a mock. In real
                // mode this is an error, not a "demo document".
                if provider.isMock, !PdfCore.isMockMode {
                    throw PdfCoreError.openFailed(L10n.t("the core could not open the file"))
                }

                self.doc = provider
                self.isMock = provider.isMock
                self.docIdentity = provider.fingerprint
                folioLog("open: document \(provider.isMock ? "MOCK" : "core"), pages \(provider.pageCount)")

                // Page sizes come from fast calls, separately, so the pages
                // appear immediately without waiting for structure analysis.
                let loadedSizes = await Task.detached(priority: .userInitiated) { () -> [CGSize] in
                    let fallback = CGSize(width: 612, height: 792)
                    var result: [CGSize] = []
                    result.reserveCapacity(provider.pageCount)
                    for index in 0..<provider.pageCount {
                        result.append((try? provider.pageSize(index)) ?? fallback)
                    }
                    return result
                }.value
                guard self.isCurrent(token) else { return }
                self.pageSizes = loadedSizes
                self.isLoading = false
                if let first = loadedSizes.first { self.applyFitWidth(pageWidth: first.width) }
                self.requestLayout(0)
                self.scrollTo(page: 0, bbox: nil)
                folioLog("open: page sizes received (\(loadedSizes.count))")

                let loadedStructure = try await Task.detached(priority: .userInitiated) {
                    try provider.structure()
                }.value
                guard self.isCurrent(token) else { return }
                self.structure = loadedStructure
                self.selectedHeadingID = self.computedActiveHeadingID
                folioLog("open: structure — headings \(loadedStructure.headings.count), tagged=\(loadedStructure.tagged)")

                if let position = self.pendingRestorePosition {
                    self.pendingRestorePosition = nil
                    self.applyReadingPosition(position)
                }

                // The last-document entry is only needed in interactive mode.
                if !self.snapshotMode {
                    ReadingPositionStore.setLastDocument(url)
                }
            } catch {
                guard self.isCurrent(token) else { return }
                self.isLoading = false
                self.doc = nil
                self.errorMessage = L10n.t("Could Not Open “%@”: %@", url.lastPathComponent, error.localizedDescription)
                folioLog("open: ERROR \(error.localizedDescription)")
            }
        }
    }

    private func isCurrent(_ token: UUID) -> Bool { token == loadToken }

    // MARK: - Page layout

    func requestLayout(_ page: Int) {
        guard let doc, page >= 0, page < pageCount else { return }
        if pageLayouts[page] != nil || layoutRequests.contains(page) { return }
        layoutRequests.insert(page)

        Task { [weak self] in
            guard let self else { return }
            let layout = try? await Task.detached(priority: .userInitiated) {
                try doc.pageLayout(page)
            }.value
            self.layoutRequests.remove(page)
            guard let layout else {
                folioLog("layout: page \(page) unavailable (the core did not return a layout)")
                return
            }
            var updated = self.pageLayouts
            updated[page] = layout
            self.pageLayouts = updated
            if page < self.pageSizes.count, self.pageSizes[page].width < 1 {
                var sizes = self.pageSizes
                sizes[page] = CGSize(width: layout.width, height: layout.height)
                self.pageSizes = sizes
            }
        }
    }

    func geometry(for page: Int) -> PageTextGeometry? {
        if let cached = geometryCache[page] { return cached }
        guard let layout = pageLayouts[page] else { return nil }
        let geometry = PageTextGeometry(layout: layout)
        geometryCache[page] = geometry
        return geometry
    }

    /// Warm up pages around the current one (visible ±2).
    func prefetch(around page: Int) {
        guard let doc else { return }
        for offset in -2...2 {
            let neighbor = page + offset
            guard neighbor >= 0, neighbor < pageCount else { continue }
            requestLayout(neighbor)
            RenderStore.shared.prefetch(page: neighbor, scale: Double(renderScale), provider: doc, prefix: pageRenderPrefix)
        }
    }

    // MARK: - Scrolling and the current page

    func scrollTo(page: Int, bbox: PcRect?) {
        guard pageCount > 0 else { return }
        let target = min(max(page, 0), pageCount - 1)
        scrollToken += 1
        scrollRequest = ScrollRequest(page: target, bbox: bbox, token: scrollToken)
        currentPage = target
        selectedHeadingID = computedActiveHeadingID
    }

    func updateVisiblePage(_ page: Int, progress: Double = 0) {
        let clampedProgress = min(max(progress, 0), 1)
        guard page != currentPage || abs(clampedProgress - currentPageProgress) > 0.01 else { return }
        guard page >= 0, page < pageCount else { return }
        currentPage = page
        currentPageProgress = clampedProgress
        if let id = computedActiveHeadingID {
            selectedHeadingID = id
        }
        schedulePositionSave()
    }

    func goToPage(_ page: Int) {
        scrollTo(page: page, bbox: nil)
    }

    func nextPage() { goToPage(currentPage + 1) }
    func previousPage() { goToPage(currentPage - 1) }

    // MARK: - Zoom

    private static let zoomSteps: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0]

    func updateAvailableWidth(_ width: CGFloat) {
        guard width > 40 else { return }
        guard abs(width - availableWidth) > 0.5 else { return }
        availableWidth = width
        if fitWidth { applyFitWidth(pageWidth: estimatedPageSize.width) }
    }

    func applyFitWidth(pageWidth: Double? = nil) {
        let width = pageWidth ?? estimatedPageSize.width
        guard width > 1 else { return }
        let usable = max(Double(availableWidth) - 96, 120)
        zoom = min(max(usable / width, 0.25), 4.0)
        fitWidth = true
    }

    func setZoom(_ value: Double) {
        fitWidth = false
        zoom = min(max(value, 0.25), 4.0)
    }

    func zoomIn() {
        let current = zoom
        let next = Self.zoomSteps.first { $0 > current + 0.001 } ?? 4.0
        setZoom(next)
    }

    func zoomOut() {
        let current = zoom
        let next = Self.zoomSteps.last { $0 < current - 0.001 } ?? 0.25
        setZoom(next)
    }

    func actualSize() { setZoom(1.0) }

    func toggleFitWidth() {
        if fitWidth {
            fitWidth = false
        } else {
            applyFitWidth()
        }
    }

    // MARK: - Overlay / export

    var showDebugOverlay: Bool { debugMode != .off }

    func setDebugMode(_ mode: DebugOverlayMode) {
        debugMode = mode
        folioLog("overlay: \(mode.localizedTitle)")
    }

    /// Toolbar button: turn the element overlay on / off.
    func toggleDebugOverlay() {
        setDebugMode(showDebugOverlay ? .off : .blocks)
    }

    /// Separate "words" toggle: boxes around every word.
    func toggleWordBoxes() {
        setDebugMode(debugMode == .words ? .off : .words)
    }

    func exportStructureJSON() {
        guard let structure else {
            folioLog("export: structure is not loaded yet")
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let base = (documentURL?.deletingPathExtension().lastPathComponent) ?? "folio"
        panel.nameFieldStringValue = "\(base)-structure.json"
        panel.message = L10n.t("Export Document Structure as JSON")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(structure)
            try data.write(to: url)
            folioLog("export: structure saved to \(url.path) (\(data.count) bytes)")
        } catch {
            errorMessage = L10n.t("Could Not Save the Structure: %@", error.localizedDescription)
            folioLog("export: error \(error.localizedDescription)")
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L10n.t("Choose a PDF document")
        panel.prompt = L10n.t("Open")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    // MARK: - Search

    func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doc, !query.isEmpty else {
            searchHits = []
            isSearching = false
            activeHitIndex = nil
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            // 250 ms debounce — do not hit the core on every keystroke
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            let hits = (try? await Task.detached(priority: .userInitiated) {
                try doc.search(query)
            }.value) ?? []
            guard !Task.isCancelled else { return }
            self.searchHits = hits
            self.isSearching = false
            self.activeHitIndex = hits.isEmpty ? nil : 0
            folioLog("search: \"\(query)\" — \(hits.count) found")
            if let first = hits.first {
                self.scrollTo(page: first.page, bbox: first.rects.first)
            }
        }
    }

    func searchRects(for page: Int) -> [PcRect] {
        guard !searchHits.isEmpty else { return [] }
        var rects: [PcRect] = []
        for hit in searchHits where hit.page == page {
            rects.append(contentsOf: hit.rects)
        }
        return rects
    }

    func goToHit(_ index: Int) {
        guard !searchHits.isEmpty else { return }
        let clamped = min(max(index, 0), searchHits.count - 1)
        activeHitIndex = clamped
        let hit = searchHits[clamped]
        scrollTo(page: hit.page, bbox: hit.rects.first)
    }

    func nextHit() {
        guard let index = activeHitIndex else { goToHit(0); return }
        goToHit(index + 1)
    }

    func previousHit() {
        guard let index = activeHitIndex else { goToHit(0); return }
        goToHit(index - 1)
    }

    func focusSearch() {
        sidebarMode = .search
        focusSearchRequest += 1
    }

    // MARK: - Selection action bar

    /// True while the pointer is down (the drag is in progress): the bar must not pop up mid-drag.
    private(set) var isPointerSelecting = false
    /// Set when another action takes over (menu, copy, lookup, translation…); cleared for a new selection.
    private(set) var selectionBarDismissed = false

    /// The floating action bar shows for a selection of more than one word and only while no
    /// other action has taken over.
    var isSelectionBarVisible: Bool {
        guard let selection, !selection.isEmpty, selection.wordIndices.count > 1 else { return false }
        return !isPointerSelecting && !selectionBarDismissed
    }

    func beginPointerSelection() { isPointerSelecting = true }

    func endPointerSelection() { isPointerSelecting = false }

    /// Hide the bar until the next selection (menus, drag, copy, lookup, translation…).
    func dismissSelectionBar() { selectionBarDismissed = true }

    /// Bring the bar back when the interfering action (e.g. a menu) is over.
    func restoreSelectionBar() { selectionBarDismissed = false }

    private var barSuppressedForMenu = false
    private var barSuppressedForWindow = false

    /// A menu (context or menu bar) opened: hide the bar, remembering whether it was visible,
    /// so it comes back only where it actually was.
    func suppressSelectionBarForMenu() {
        barSuppressedForMenu = isSelectionBarVisible
        dismissSelectionBar()
    }

    func restoreSelectionBarAfterMenu() {
        guard barSuppressedForMenu else { return }
        barSuppressedForMenu = false
        restoreSelectionBar()
    }

    /// The window lost key status (another window or app took over).
    func suppressSelectionBarForWindow() {
        barSuppressedForWindow = isSelectionBarVisible
        dismissSelectionBar()
    }

    func restoreSelectionBarAfterWindow() {
        guard barSuppressedForWindow else { return }
        barSuppressedForWindow = false
        restoreSelectionBar()
    }

    // MARK: - Selection and dictionary

    func setSelection(_ selection: Selection?) {
        let wasEmpty = self.selection?.isEmpty ?? true
        self.selection = selection
        if let selection, !selection.isEmpty {
            // A new selection always brings the action bar back.
            selectionBarDismissed = false
        }
        // Do not log every drag step — only the start of a new selection.
        if wasEmpty, let selection, !selection.isEmpty {
            folioLog("selection: page \(selection.page + 1), words \(selection.rects.count), \"\(String(selection.text.prefix(80)))\"")
        }
    }

    func clearSelection() {
        if selection != nil { selection = nil }
        selectionBarDismissed = false
    }

    @discardableResult
    func copySelection() -> Bool {
        guard let selection, !selection.isEmpty else {
            folioLog("copy: no selection — nothing to copy")
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(selection.text, forType: .string)
        folioLog("copy: \(ok ? "copied" : "ERROR") \(selection.text.count) characters: \"\(String(selection.text.prefix(120)))\"")
        dismissSelectionBar()
        return ok
    }

    // MARK: - Speech and translation

    /// Speak an arbitrary fragment (selection, word under the cursor, translation).
    /// Silently refuses if speech is disabled in settings.
    @discardableResult
    func speak(_ text: String, origin: String = "selection") -> Bool {
        let ok = speech.speak(text)
        if !ok, !settings.speechEnabled {
            folioLog("speech: \(origin) — speech disabled, suggesting settings")
        }
        return ok
    }

    /// "Speak Selection" from the menu/context menu.
    func speakSelection() {
        guard let selection, !selection.isEmpty else {
            folioLog("speech: no selection — nothing to read")
            NSSound.beep()
            return
        }
        guard settings.speechEnabled else {
            folioLog("speech: speech disabled — opening settings")
            NSSound.beep()
            presentSettings()
            return
        }
        speak(selection.text, origin: "selection")
    }

    func stopSpeaking() {
        speech.stop()
    }

    /// Translate text (selection or word) and show the translation bubble anchored to it.
    ///
    /// The page/rects are the popover's anchor: the bubble points at the translated fragment the
    /// same way the system Translation bubble does. They default to the current selection.
    func translate(_ text: String,
                   origin: String = "selection",
                   page anchorPage: Int? = nil,
                   rects anchorRects: [PcRect] = []) {
        dismissSelectionBar()
        var selectionAnchor: Selection?
        if let selection, !selection.isEmpty { selectionAnchor = selection }
        let page = anchorPage ?? selectionAnchor?.page ?? currentPage
        let rects = anchorRects.isEmpty ? (selectionAnchor?.rects ?? []) : anchorRects
        guard #available(macOS 15.0, *) else {
            translation.unavailableOnThisSystem(page: page, rects: rects)
            return
        }
        translation.request(text: text,
                            sourceID: settings.translateSourceID,
                            targetID: settings.translateTargetID,
                            origin: origin,
                            page: page,
                            rects: rects)
    }

    /// "Translate Selection" from the menu/context menu.
    func translateSelection() {
        guard let selection, !selection.isEmpty else {
            folioLog("translate: no selection — nothing to translate")
            NSSound.beep()
            return
        }
        translate(selection.text, origin: "selection")
    }

    /// Open the settings window (⌘,).
    func presentSettings() {
        SettingsWindow.shared.show()
    }

    /// ⌘D and the "Look Up in Dictionary" menu item: the active page of the active window.
    func performLookUp() {
        let pageView = PageCanvasView.active(in: window) ?? PageCanvasView.active
        guard let pageView else {
            folioLog("lookup: no active page (click a page first)")
            NSSound.beep()
            return
        }
        dismissSelectionBar()
        pageView.lookUpAtHover()
    }

    /// "Dictionary" from the selection action bar: look up the selected word(s).
    func lookUpSelection() {
        guard let selection, !selection.isEmpty else {
            folioLog("lookup: no selection — nothing to look up")
            NSSound.beep()
            return
        }
        dismissSelectionBar()
        guard let pageView = PageCanvasView.active(in: window) ?? PageCanvasView.active else {
            folioLog("lookup: no page view for the selection")
            NSSound.beep()
            return
        }
        pageView.lookUpAtHover()
    }

    // MARK: - Reading position

    /// Save the current document's page/scroll/zoom.
    func persistReadingPosition() {
        guard !snapshotMode, let url = documentURL, pageCount > 0, !isLoading else { return }
        let position = ReadingPosition(page: currentPage,
                                       progress: currentPageProgress,
                                       zoom: zoom,
                                       fitWidth: fitWidth)
        ReadingPositionStore.save(position, for: url)
    }

    /// Delayed saving: scrolling changes the position dozens of times a second.
    private func schedulePositionSave() {
        guard !snapshotMode else { return }
        positionSaveTask?.cancel()
        positionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.persistReadingPosition()
        }
    }

    /// Apply the saved position after the document structure has loaded.
    private func applyReadingPosition(_ position: ReadingPosition) {
        let page = min(max(position.page, 0), max(pageCount - 1, 0))
        if position.fitWidth {
            applyFitWidth(pageWidth: pageSize(page).width)
        } else {
            setZoom(position.zoom)
        }
        currentPage = page
        currentPageProgress = min(max(position.progress, 0), 1)
        selectedHeadingID = computedActiveHeadingID
        let height = Double(pageSize(page).height)
        let y = currentPageProgress * max(height, 1)
        let bbox = PcRect(x: 0, y: y, w: 1, h: 1)
        folioLog("restore: page \(page + 1) of \(pageCount), scroll \(String(format: "%.0f", currentPageProgress * 100))%, zoom \(String(format: "%.2f", zoom))")
        folioLog("restore: applying position — page \(page + 1), fraction \(String(format: "%.2f", currentPageProgress)), zoom \(String(format: "%.2f", zoom))")
        // Let DetailView appear, otherwise onChange(scrollRequest) will not fire.
        // After a zoom change LazyVStack rebuilds, so check that we actually
        // reached the page and repeat the scroll when needed.
        Task { [weak self] in
            for attempt in 0..<3 {
                try? await Task.sleep(nanoseconds: attempt == 0 ? 200_000_000 : 450_000_000)
                guard let self, self.documentURL != nil else { return }
                self.scrollTo(page: page, bbox: bbox)
                try? await Task.sleep(nanoseconds: 400_000_000)
                if self.currentPage == page {
                    folioLog("restore: page \(page + 1) in place (attempt \(attempt + 1))")
                    return
                }
                folioLog("restore: page \(page + 1) not reached (showing \(self.currentPage + 1)), retry \(attempt + 2)")
            }
        }
    }

    // MARK: - Snapshot mode

    func configureForSnapshot() {
        snapshotMode = true
        fitWidth = true
        sidebarMode = .structure
    }

    var snapshotReady: Bool {
        guard snapshotMode || !isLoading else { return false }
        guard !isLoading, let doc else { return false }
        guard pageSizes.count >= min(doc.pageCount, 1) else { return false }
        guard pageLayouts[0] != nil else { return false }
        return true
    }
}
