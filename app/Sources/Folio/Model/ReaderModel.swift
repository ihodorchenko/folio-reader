import Foundation
import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

// MARK: - Вкладки sidebar

/// Режим debug-оверлея: выключен / блоки (kind+level+confidence) / рамки каждого слова.
enum DebugOverlayMode: String, CaseIterable, Identifiable {
    case off
    case blocks
    case words

    var id: String { rawValue }

    var titleRu: String {
        switch self {
        case .off: return "Разметка выключена"
        case .blocks: return "Разметка блоков"
        case .words: return "Рамки слов"
        }
    }
}

enum SidebarMode: String, CaseIterable, Identifiable {
    case structure
    case thumbnails
    case search

    var id: String { rawValue }

    var titleRu: String {
        switch self {
        case .structure: return "Структура"
        case .thumbnails: return "Страницы"
        case .search: return "Поиск"
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

// MARK: - Элемент дерева структуры

struct HeadingRow: Identifiable, Hashable {
    let id: String
    let level: Int
    let title: String
    let page: Int
    let bbox: PcRect
}

// MARK: - Запрос прокрутки

struct ScrollRequest: Equatable {
    let page: Int
    let bbox: PcRect?
    let token: Int
}

// MARK: - Модель ридера

/// Вся логика состояния окна: документ, структура, страницы, зум, поиск, выделение.
/// Рендер/парсинг — на фоне (`Task.detached`), мутации — на главном акторе.
@Observable
@MainActor
final class ReaderModel {
    /// Все живые модели (по одной на окно). Слабые ссылки: моделью владеет сцена.
    @MainActor static let registry = NSHashTable<ReaderModel>.weakObjects()

    /// Модель активного окна — для ⌘C/⌘D из мониторов событий и пунктов меню.
    @MainActor static var active: ReaderModel? {
        if let window = NSApp.keyWindow, let model = model(for: window) { return model }
        return registry.allObjects.first
    }

    /// Модель, привязанная к конкретному окну (каждое окно — свой документ).
    @MainActor static func model(for window: NSWindow?) -> ReaderModel? {
        guard let window else { return nil }
        return registry.allObjects.first { $0.window === window }
    }

    // MARK: Сервисы: настройки, озвучка, перевод

    /// Пользовательские настройки (озвучка выключена по умолчанию, пара EN → RU).
    let settings = SettingsStore.shared
    /// Синтез речи для выделенного текста.
    let speech = SpeechService.shared
    /// Состояние перевода выделенного фрагмента (сессию создаёт SwiftUI-хост).
    let translation = TranslationController()

    // MARK: Окно

    /// Окно, в котором живёт эта модель (проставляется через `WindowAccessor`).
    private(set) weak var window: NSWindow?
    private var windowCloseObserver: NSObjectProtocol?

    // MARK: Документ

    private(set) var doc: (any DocumentProviding)?
    private(set) var documentURL: URL?
    private(set) var isMock = false
    private(set) var isLoading = false
    var errorMessage: String?
    private(set) var docIdentity: String = ""

    // MARK: Структура и страницы

    var structure: PcDocumentStructure?
    var pageLayouts: [Int: PcPageLayout] = [:]
    var pageSizes: [CGSize] = []
    var currentPage = 0
    /// 0…1 — насколько далеко прокручена текущая страница (для активного заголовка).
    private(set) var currentPageProgress: Double = 0

    // MARK: Отображение

    var zoom: Double = 1.0
    var fitWidth = true
    var backingScale: CGFloat = 2.0
    private var availableWidth: CGFloat = 900
    var sidebarMode: SidebarMode = .structure
    var debugMode: DebugOverlayMode = .off
    var columnVisibility: NavigationSplitViewVisibility = .all
    var selectedHeadingID: String?

    // MARK: Поиск

    var searchQuery = ""
    var searchHits: [PcSearchHit] = []
    var isSearching = false
    var activeHitIndex: Int?
    var focusSearchRequest = 0

    // MARK: Выделение

    var selection: Selection?

    // MARK: Снапшот/приёмка

    /// Только для `--snapshot`: документ готов, страницы и layout первой страницы загружены.
    private(set) var snapshotMode = false

    // MARK: Служебное

    private var loadTask: Task<Void, Never>?
    private var loadToken = UUID()
    private var layoutRequests = Set<Int>()
    private var geometryCache: [Int: PageTextGeometry] = [:]
    private var scrollToken = 0
    var scrollRequest: ScrollRequest?
    private var searchTask: Task<Void, Never>?
    private var didBootstrap = false
    /// Восстановление последней книги — только один раз за запуск приложения.
    private static var hasRestoredLastDocument = false
    private var positionSaveTask: Task<Void, Never>?
    private var pendingRestorePosition: ReadingPosition?
    private var windowAttached = false

    // MARK: - Инициализация

    init() {
        Self.registry.add(self)
    }

    /// Окно стало активным: именно эту книгу восстанавливать при следующем запуске.
    func activate() {
        guard let url = documentURL else { return }
        ReadingPositionStore.setLastDocument(url)
    }

    /// Привязка к окну: нужно для мониторов ⌘C/⌘D, сохранения позиции и отчётов.
    func attach(window: NSWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window
        // Свои окна не отдаём системному восстановлению: иначе при следующем
        // запуске macOS поднимает столько окон, сколько было открыто.
        window.isRestorable = false
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ReaderModel.model(for: window)?.persistReadingPosition()
            }
        }
        if !windowAttached {
            windowAttached = true
            folioLog("window: окно привязано к модели, документ=\(documentURL?.lastPathComponent ?? "—")")
        }
    }

    /// Префиксы ключей кэша рендера: в ключе есть отпечаток документа,
    /// чтобы после открытия другого PDF не показать чужую страницу.
    var pageRenderPrefix: String { "page:\(docIdentity)" }
    var thumbnailPrefix: String { "thumb:\(docIdentity)" }

    // MARK: - Производные значения

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
        if isLoading { return "Загрузка…" }
        guard doc != nil else { return errorMessage == nil ? "Нет документа" : "Ошибка открытия" }
        var parts: [String] = []
        if isMock {
            parts.append("демо-документ (ядро не собрано)")
        } else {
            parts.append(CoreLibrary.shared()?.versionString ?? "pdfcore")
        }
        parts.append("\(pageCount) стр.")
        if let structure {
            parts.append("заголовков: \(structure.headings.count)")
            if structure.tagged { parts.append("tagged PDF") }
        }
        return parts.joined(separator: " • ")
    }

    /// Оценка размера страницы, пока реальные размеры не загрузились.
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

    /// Масштаб рендера в пикселях на точку: зум × backing scale, с ограничением ~4096 px по ширине.
    var renderScale: CGFloat {
        let base = zoom * Double(backingScale)
        let width = Double(estimatedPageSize.width)
        guard width > 1 else { return CGFloat(base) }
        let maxPixelWidth = 4096.0
        return CGFloat(min(base, maxPixelWidth / width))
    }

    // MARK: - Структура sidebar

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

    // MARK: - Открытие документа

    /// Старт сцены: документ из значения окна, из отложенной очереди или последний открытый.
    func start(documentURL: URL?) {
        guard !didBootstrap, !snapshotMode else { return }
        didBootstrap = true
        WindowReport.event("model.start value=\(documentURL?.lastPathComponent ?? "—")")

        // 1. Документ, с которым создано окно (Finder «Открыть с помощью» / ⌘N с файлом).
        if let url = documentURL {
            open(url: url)
            return
        }
        // 2. Файл, пришедший до появления первого окна.
        if let pending = WindowRouter.shared.takePendingURL() {
            open(url: pending)
            return
        }
        // 3. PDF из аргументов командной строки (запуск из терминала).
        //    Берём только *.pdf: у флагов вроде --window-report тоже есть значения.
        let candidates = CommandLine.arguments.dropFirst().filter {
            !$0.hasPrefix("-") && $0.lowercased().hasSuffix(".pdf")
        }
        if let path = candidates.first, FileManager.default.fileExists(atPath: path) {
            open(url: URL(fileURLWithPath: path))
            return
        }
        // 4. Последний открытый документ — восстанавливаем с небольшой задержкой:
        //    open-событие из Finder приходит в первые ~100 мс, и тогда старая книга
        //    не нужна (иначе получалось две версии приложения).
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.documentURL == nil, !Self.hasRestoredLastDocument else { return }
            Self.hasRestoredLastDocument = true
            guard let last = ReadingPositionStore.lastDocument() else { return }
            folioLog("restore: открываю последний документ \(last.path)")
            WindowReport.event("restore последнего документа")
            self.open(url: last)
        }
        // 5. Если ничего не пришло — пустое состояние с кнопкой «Открыть…».
    }

    func open(url: URL) {
        WindowReport.event("model.open \(url.lastPathComponent)")
        // Место в текущем документе не теряем при переходе к другой книге.
        persistReadingPosition()
        let savedPosition = snapshotMode ? nil : ReadingPositionStore.load(for: url)
        pendingRestorePosition = savedPosition
        ReadingPositionStore.setLastDocument(url)

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
        folioLog("open: \(url.path) mode=\(PdfCore.isMockMode ? "mock (ядро не найдено)" : "core")")

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let provider = try await Task.detached(priority: .userInitiated) {
                    try PdfCore.open(url: url)
                }.value
                guard self.isCurrent(token) else { return }

                // Ядро есть, но файл не открылся → оно вернуло мок. В реальном
                // режиме это ошибка, а не «демо-документ».
                if provider.isMock, !PdfCore.isMockMode {
                    throw PdfCoreError.openFailed("ядро не смогло открыть файл")
                }

                self.doc = provider
                self.isMock = provider.isMock
                self.docIdentity = provider.fingerprint
                folioLog("open: документ \(provider.isMock ? "МОК" : "ядро"), страниц \(provider.pageCount)")

                // Размеры страниц — быстрыми вызовами отдельно, чтобы страницы
                // появились сразу, не дожидаясь анализа структуры.
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
                folioLog("open: размеры страниц получены (\(loadedSizes.count))")

                let loadedStructure = try await Task.detached(priority: .userInitiated) {
                    try provider.structure()
                }.value
                guard self.isCurrent(token) else { return }
                self.structure = loadedStructure
                self.selectedHeadingID = self.computedActiveHeadingID
                folioLog("open: структура — заголовков \(loadedStructure.headings.count), tagged=\(loadedStructure.tagged)")

                if let position = self.pendingRestorePosition {
                    self.pendingRestorePosition = nil
                    self.applyReadingPosition(position)
                }

                // Кэш последнего документа нужен только интерактивному режиму.
                if !self.snapshotMode {
                    ReadingPositionStore.setLastDocument(url)
                }
            } catch {
                guard self.isCurrent(token) else { return }
                self.isLoading = false
                self.doc = nil
                self.errorMessage = "Не удалось открыть «\(url.lastPathComponent)»: \(error.localizedDescription)"
                folioLog("open: ОШИБКА \(error.localizedDescription)")
            }
        }
    }

    private func isCurrent(_ token: UUID) -> Bool { token == loadToken }

    // MARK: - Layout страниц

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
                folioLog("layout: страница \(page) недоступна (ядро не отдало layout)")
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

    /// Тёплая подгрузка страниц вокруг текущей (видимые ±2).
    func prefetch(around page: Int) {
        guard let doc else { return }
        for offset in -2...2 {
            let neighbor = page + offset
            guard neighbor >= 0, neighbor < pageCount else { continue }
            requestLayout(neighbor)
            RenderStore.shared.prefetch(page: neighbor, scale: Double(renderScale), provider: doc, prefix: pageRenderPrefix)
        }
    }

    // MARK: - Прокрутка и текущая страница

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

    // MARK: - Зум

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

    // MARK: - Разметка / экспорт

    var showDebugOverlay: Bool { debugMode != .off }

    func setDebugMode(_ mode: DebugOverlayMode) {
        debugMode = mode
        folioLog("разметка: \(mode.titleRu)")
    }

    /// Кнопка в тулбаре: включить разметку блоков / выключить.
    func toggleDebugOverlay() {
        setDebugMode(showDebugOverlay ? .off : .blocks)
    }

    /// Отдельный тумблер «слова»: рамки вокруг каждого слова.
    func toggleWordBoxes() {
        setDebugMode(debugMode == .words ? .off : .words)
    }

    func exportStructureJSON() {
        guard let structure else {
            folioLog("export: структура ещё не загружена")
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let base = (documentURL?.deletingPathExtension().lastPathComponent) ?? "folio"
        panel.nameFieldStringValue = "\(base)-structure.json"
        panel.message = "Экспорт структуры документа в JSON"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(structure)
            try data.write(to: url)
            folioLog("export: структура сохранена в \(url.path) (\(data.count) байт)")
        } catch {
            errorMessage = "Не удалось сохранить структуру: \(error.localizedDescription)"
            folioLog("export: ошибка \(error.localizedDescription)")
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Выберите PDF-документ"
        panel.prompt = "Открыть"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    // MARK: - Поиск

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
            // debounce 250 мс — не дёргаем ядро на каждое нажатие
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            let hits = (try? await Task.detached(priority: .userInitiated) {
                try doc.search(query)
            }.value) ?? []
            guard !Task.isCancelled else { return }
            self.searchHits = hits
            self.isSearching = false
            self.activeHitIndex = hits.isEmpty ? nil : 0
            folioLog("поиск: «\(query)» — найдено \(hits.count)")
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

    // MARK: - Выделение и словарь

    func setSelection(_ selection: Selection?) {
        let wasEmpty = self.selection?.isEmpty ?? true
        self.selection = selection
        // Не логируем каждый шаг протяжки — только начало нового выделения.
        if wasEmpty, let selection, !selection.isEmpty {
            folioLog("выделение: стр. \(selection.page + 1), слов \(selection.rects.count), «\(String(selection.text.prefix(80)))»")
        }
    }

    func clearSelection() {
        if selection != nil { selection = nil }
    }

    @discardableResult
    func copySelection() -> Bool {
        guard let selection, !selection.isEmpty else {
            folioLog("copy: нет выделения — нечего копировать")
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(selection.text, forType: .string)
        folioLog("copy: \(ok ? "скопировано" : "ОШИБКА") \(selection.text.count) символов: «\(String(selection.text.prefix(120)))»")
        return ok
    }

    // MARK: - Озвучка и перевод

    /// Озвучить произвольный фрагмент (выделение, слово под курсором, перевод).
    /// Молча отказывается, если озвучка выключена в настройках.
    @discardableResult
    func speak(_ text: String, origin: String = "выделения") -> Bool {
        let ok = speech.speak(text)
        if !ok, !settings.speechEnabled {
            folioLog("speech: \(origin) — озвучка выключена, подсказываю настройки")
        }
        return ok
    }

    /// «Озвучить выделение» из меню/контекстного меню.
    func speakSelection() {
        guard let selection, !selection.isEmpty else {
            folioLog("speech: нет выделения — читать нечего")
            NSSound.beep()
            return
        }
        guard settings.speechEnabled else {
            folioLog("speech: озвучка выключена — открываю настройки")
            NSSound.beep()
            presentSettings()
            return
        }
        speak(selection.text, origin: "выделения")
    }

    func stopSpeaking() {
        speech.stop()
    }

    /// Перевести текст (выделение или слово) и показать панель перевода.
    func translate(_ text: String, origin: String = "выделения") {
        guard #available(macOS 15.0, *) else {
            translation.unavailableOnThisSystem()
            return
        }
        translation.request(text: text,
                            sourceID: settings.translateSourceID,
                            targetID: settings.translateTargetID,
                            origin: origin)
    }

    /// «Перевести выделение» из меню/контекстного меню.
    func translateSelection() {
        guard let selection, !selection.isEmpty else {
            folioLog("translate: нет выделения — переводить нечего")
            NSSound.beep()
            return
        }
        translate(selection.text, origin: "выделения")
    }

    /// Открыть окно настроек (⌘,).
    func presentSettings() {
        SettingsWindow.shared.show()
    }

    /// ⌘D и пункт меню «Найти в словаре»: активная страница активного окна.
    func performLookUp() {
        let pageView = PageCanvasView.active(in: window) ?? PageCanvasView.active
        guard let pageView else {
            folioLog("lookup: нет активной страницы (сначала кликните по странице)")
            NSSound.beep()
            return
        }
        pageView.lookUpAtHover()
    }

    // MARK: - Позиция чтения

    /// Сохранить страницу/прокрутку/зум текущего документа.
    func persistReadingPosition() {
        guard !snapshotMode, let url = documentURL, pageCount > 0, !isLoading else { return }
        let position = ReadingPosition(page: currentPage,
                                       progress: currentPageProgress,
                                       zoom: zoom,
                                       fitWidth: fitWidth)
        ReadingPositionStore.save(position, for: url)
    }

    /// Сохранение с задержкой: прокрутка меняет позицию десятки раз в секунду.
    private func schedulePositionSave() {
        guard !snapshotMode else { return }
        positionSaveTask?.cancel()
        positionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.persistReadingPosition()
        }
    }

    /// Применить сохранённую позицию после загрузки структуры документа.
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
        folioLog("restore: страница \(page + 1) из \(pageCount), прокрутка \(String(format: "%.0f", currentPageProgress * 100))%, зум \(String(format: "%.2f", zoom))")
        // Даём DetailView появиться, иначе onChange(scrollRequest) не сработает.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            self.scrollTo(page: page, bbox: bbox)
            self.updateVisiblePage(page, progress: position.progress)
        }
    }

    // MARK: - Снапшот-режим

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
