import AppKit
import CoreGraphics

/// Страница документа: рисует растровый рендер ядра, оверлей текста
/// (hover/drag-выделение), debug-разметку блоков и обрабатывает сильное нажатие.
///
/// Координаты: NSView «перевёрнут» (isFlipped == true), поэтому page-координаты
/// (origin — левый верхний угол страницы, y вниз) совпадают с view при делении на zoom.
final class PageCanvasView: NSView {
    /// Последняя страница, получившая фокус/наведение — для ⌘D из меню.
    static weak var active: PageCanvasView?

    let pageIndex: Int
    weak var model: ReaderModel?

    // Геометрия страницы
    private(set) var pageSize: CGSize = CGSize(width: 612, height: 792)
    private(set) var zoom: CGFloat = 1
    private(set) var renderScale: CGFloat = 2
    private(set) var layoutInfo: PcPageLayout?
    private(set) var geometry: PageTextGeometry?
    /// Отпечаток документа: при смене документа сбрасываем растровый кэш страницы.
    private(set) var documentIdentity = ""

    // Отрисовка
    private var image: CGImage?
    private var imageScale: CGFloat = .nan
    private var pendingScale: CGFloat = .nan
    /// Масштаб, на котором рендер уже провалился — не повторяем бесконечно.
    private var failedScale: CGFloat = .nan
    var selection: Selection? { didSet { needsDisplay = true } }
    var searchRects: [PcRect] = [] { didSet { needsDisplay = true } }
    var debugMode: DebugOverlayMode = .off { didSet { needsDisplay = true } }

    // Интерактивность
    private var trackingAreaRef: NSTrackingArea?
    private var hoverWordIndex: Int?
    private var lastHoverPoint: CGPoint?
    private var contextPoint: CGPoint?
    private var mouseDownPoint: CGPoint?
    private var dragStartWord: Int?
    private var isDragging = false

    private static let fontSizeForMock: CGFloat = 1.0

    // MARK: - Init

    init(pageIndex: Int) {
        self.pageIndex = pageIndex
        super.init(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: NSEvent.PressureBehavior.primaryDeepClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    deinit {
        if PageCanvasView.active === self { PageCanvasView.active = nil }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    // MARK: - Конфигурация из SwiftUI

    func configure(pageSize: CGSize,
                   zoom: Double,
                   layout: PcPageLayout?,
                   selection: Selection?,
                   searchRects: [PcRect],
                   debugMode: DebugOverlayMode,
                   renderScale: CGFloat,
                   documentIdentity: String) {
        let sizeChanged = self.pageSize != pageSize || self.zoom != CGFloat(zoom)
        if documentIdentity != self.documentIdentity {
            self.documentIdentity = documentIdentity
            image = nil
            imageScale = .nan
            pendingScale = .nan
            failedScale = .nan
            // Другой документ — геометрия и выделение от прежнего невалидны.
            layoutInfo = nil
            geometry = nil
            hoverWordIndex = nil
            self.selection = nil
            self.searchRects = []
        }
        self.pageSize = pageSize
        self.zoom = CGFloat(max(zoom, 0.05))
        self.renderScale = max(renderScale, 0.1)
        if geometry == nil || layoutInfo?.index != layout?.index {
            layoutInfo = layout
            rebuildGeometry()
        }
        self.selection = selection
        self.searchRects = searchRects
        self.debugMode = debugMode
        if sizeChanged { needsDisplay = true }
        needsDisplay = true
    }

    private func rebuildGeometry() {
        if let layoutInfo {
            geometry = PageTextGeometry(layout: layoutInfo)
            if let hoverWordIndex, hoverWordIndex >= (geometry?.words.count ?? 0) {
                self.hoverWordIndex = nil
            }
        } else {
            geometry = nil
        }
    }

    // MARK: - Изображение страницы

    func ensureImage() {
        guard let doc = model?.doc, pageSize.width > 1, pageSize.height > 1 else { return }
        let scale = renderScale
        if image != nil, abs(imageScale - scale) < 0.05 { return }
        if image != nil, abs(pendingScale - scale) < 0.05 { return }
        if abs(failedScale - scale) < 0.05 { return }
        let prefix = "page:\(documentIdentity)"
        let key = RenderStore.key(prefix, pageIndex, Double(scale))
        if let cached = RenderStore.shared.cached(key) {
            setImage(cached, scale: scale)
            return
        }
        pendingScale = scale
        let requested = scale
        let page = pageIndex
        let immediate = RenderStore.shared.image(page: page, scale: Double(scale), provider: doc, prefix: prefix) { [weak self] rendered in
            guard let self else { return }
            self.pendingScale = .nan
            guard let rendered else {
                self.failedScale = requested
                folioLog("render: страница \(page + 1) не отрендерилась (scale \(String(format: "%.2f", Double(requested))))")
                return
            }
            self.failedScale = .nan
            self.setImage(rendered, scale: requested)
            if abs(self.renderScale - requested) > 0.05 {
                self.ensureImage()
            }
        }
        // Синхронный режим (снапшот): изображение готово сразу.
        if let immediate {
            pendingScale = .nan
            setImage(immediate, scale: scale)
        }
    }

    private func setImage(_ image: CGImage, scale: CGFloat) {
        self.image = image
        self.imageScale = scale
        needsDisplay = true
    }

    // MARK: - Отрисовка

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let paper = bounds.insetBy(dx: 0.5, dy: 0.5)

        // Тень страницы (рисуем в перевёрнутой системе координат: +y — вниз).
        ctx.saveGState()
        if image != nil {
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 9,
                          color: NSColor.black.withAlphaComponent(0.20).cgColor)
        }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(paper)
        ctx.restoreGState()

        if let image {
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        } else {
            drawLoadingPlaceholder(ctx)
        }

        // Для мока пишем настоящий текст из layout поверх «полос» мок-рендера:
        // так снапшоты читаются как документ, а хит-тест совпадает с картинкой.
        if model?.isMock == true {
            drawMockText(ctx)
        }

        // Подсветка поиска — под выделением и hover.
        if !searchRects.isEmpty {
            fill(pageRects: searchRects, color: NSColor.systemYellow.withAlphaComponent(0.35))
            stroke(pageRects: searchRects, color: NSColor.systemOrange.withAlphaComponent(0.55), width: 1)
        }

        // Выделение (объединяем по строкам, как это делает Preview).
        if let selection, selection.page == pageIndex, !selection.rects.isEmpty {
            let active = window?.isKeyWindow ?? true
            let color = active ? NSColor.controlAccentColor.withAlphaComponent(0.26)
                               : NSColor.secondaryLabelColor.withAlphaComponent(0.18)
            fill(pageRects: selection.rects, color: color)
        }

        // Hover слова.
        if let hoverWordIndex, let word = geometry?.word(at: hoverWordIndex) {
            let rect = viewRect(word.bbox)
            fill(viewRects: [rect], color: NSColor.controlAccentColor.withAlphaComponent(0.16))
            NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
            let underline = NSBezierPath()
            underline.lineWidth = max(1, 1.0 * zoom)
            underline.move(to: CGPoint(x: rect.minX, y: rect.maxY + 0.5))
            underline.line(to: CGPoint(x: rect.maxX, y: rect.maxY + 0.5))
            underline.stroke()
        }

        // Рамка листа.
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(paper)
        ctx.restoreGState()

        // Debug-оверлей: блоки (kind/level/confidence) или рамки отдельных слов.
        switch debugMode {
        case .off: break
        case .blocks: drawDebugOverlay(ctx)
        case .words: drawWordBoxes(ctx)
        }

        // Рамка фокуса для клавиатурных сценариев не нужна — ридер не редактируемый.
    }

    private func drawLoadingPlaceholder(_ ctx: CGContext) {
        let text = "Рендер страницы \(pageIndex + 1)…"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let point = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    private func drawMockText(_ ctx: CGContext) {
        guard let layoutInfo else { return }
        // Мок-рендер — цветные полосы вместо глифов, поэтому поверх пишем реальный
        // текст строк из layout. Цвет фиксированный: бумага всегда белая, в тёмной
        // теме labelColor стал бы белым и текст исчез.
        _ = ctx
        let textColor = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
        for block in layoutInfo.blocks {
            for line in block.lines {
                let word = line.words.first
                let size = max(CGFloat(word?.size ?? block.font.size) * zoom, 1)
                let bold = word?.bold ?? block.font.bold
                let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor
                ]
                let origin = NSPoint(x: CGFloat(line.bbox.x) * zoom, y: CGFloat(line.bbox.y) * zoom)
                (line.text as NSString).draw(at: origin, withAttributes: attributes)
            }
        }
    }

    /// Тонкие рамки вокруг КАЖДОГО слова — основной инструмент проверки
    /// совпадения оверлея с реальными глифами PDFium.
    private func drawWordBoxes(_ ctx: CGContext) {
        guard let layoutInfo else { return }
        ctx.saveGState()
        ctx.setLineWidth(0.6)
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor)
        for block in layoutInfo.blocks {
            for line in block.lines {
                for word in line.words {
                    let rect = viewRect(word.bbox)
                    guard rect.width > 0.3, rect.height > 0.3 else { continue }
                    ctx.stroke(rect)
                }
            }
        }
        ctx.restoreGState()
    }

    private func drawDebugOverlay(_ ctx: CGContext) {
        guard let layoutInfo else { return }
        let labelFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        for block in layoutInfo.blocks {
            let color = block.kind.debugColor
            let nsColor = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)
            ctx.saveGState()
            ctx.setStrokeColor(nsColor.withAlphaComponent(block.kind == .heading ? 0.95 : 0.7).cgColor)
            ctx.setLineWidth(block.kind == .heading ? 2.0 : 1.0)
            ctx.stroke(viewRect(block.bbox))
            ctx.restoreGState()

            var label = "\(block.kind.rawValue)"
            if block.kind == .heading, block.level > 0 { label += " H\(block.level)" }
            if block.confidence > 0 { label += String(format: " %.2f", block.confidence) }
            let blockRect = viewRect(block.bbox)
            let labelSize = (label as NSString).size(withAttributes: [.font: labelFont])
            // Плашку ставим НАД блоком, чтобы не закрывать текст (внутрь — если места нет).
            let labelY = blockRect.minY > 12 ? blockRect.minY - 11.5 : blockRect.minY + 0.5
            let badgeRect = CGRect(x: blockRect.minX, y: labelY,
                                   width: labelSize.width + 6, height: 11.5)
            nsColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(rect: badgeRect).fill()
            (label as NSString).draw(at: CGPoint(x: badgeRect.minX + 3, y: badgeRect.minY + 0.5),
                                     withAttributes: [.font: labelFont, .foregroundColor: NSColor.white])
        }
    }

    // MARK: - Координаты

    private func pagePoint(from viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x / zoom, y: viewPoint.y / zoom)
    }

    private func viewRect(_ rect: PcRect) -> CGRect {
        CGRect(x: rect.x * zoom, y: rect.y * zoom, width: rect.w * zoom, height: rect.h * zoom)
    }

    private func fill(pageRects: [PcRect], color: NSColor) {
        fill(viewRects: pageRects.map(viewRect), color: color)
    }

    private func fill(viewRects: [CGRect], color: NSColor) {
        guard !viewRects.isEmpty else { return }
        color.setFill()
        for rect in viewRects { NSBezierPath(rect: rect).fill() }
    }

    private func stroke(pageRects: [PcRect], color: NSColor, width: CGFloat) {
        guard !pageRects.isEmpty else { return }
        color.setStroke()
        for rect in pageRects {
            let path = NSBezierPath(rect: viewRect(rect))
            path.lineWidth = width
            path.stroke()
        }
    }

    // MARK: - Tracking area / hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseEntered(with event: NSEvent) {
        PageCanvasView.active = self
    }

    override func mouseMoved(with event: NSEvent) {
        PageCanvasView.active = self
        updateHover(atWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        hoverWordIndex = nil
        lastHoverPoint = nil
        needsDisplay = true
    }

    private func updateHover(atWindowPoint windowPoint: CGPoint) {
        let local = convert(windowPoint, from: nil)
        let point = pagePoint(from: local)
        lastHoverPoint = point
        let index = geometry?.wordIndex(at: point, tolerance: 3)
        if index != hoverWordIndex {
            hoverWordIndex = index
            needsDisplay = true
        }
    }

    // MARK: - Мышь: выделение

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        PageCanvasView.active = self
        let local = convert(event.locationInWindow, from: nil)
        let point = pagePoint(from: local)
        mouseDownPoint = point
        lastHoverPoint = point
        let index = geometry?.wordIndex(at: point, tolerance: 6)
        dragStartWord = index
        isDragging = false
        if let index, let geometry {
            model?.setSelection(geometry.selection(from: index, to: index))
        } else {
            model?.clearSelection()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartWord, let geometry, !geometry.isEmpty else { return }
        let local = convert(event.locationInWindow, from: nil)
        let point = pagePoint(from: local)
        lastHoverPoint = point
        guard let index = geometry.wordIndex(at: point, tolerance: 8) else { return }
        if index != start { isDragging = true }
        model?.setSelection(geometry.selection(from: start, to: index))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartWord = nil
            isDragging = false
            needsDisplay = true
        }
        guard !isDragging else { return }
        // Клик без протяжки — снимаем выделение (курсор в тексте).
        model?.clearSelection()
    }

    // MARK: - Force click → системный словарь

    override func pressureChange(with event: NSEvent) {
        folioLog("force-click: pressureChange stage=\(event.stage) pressure=\(String(format: "%.2f", event.pressure)) page=\(pageIndex + 1)")
        guard event.stage == 2 else { return }
        handleDeepClick()
    }

    /// Общий путь «сильное нажатие»: используется и из pressureChange(stage 2),
    /// и из программной эмуляции в снапшот-режиме (Force Touch на CI недоступен).
    private func handleDeepClick() {
        guard let point = mouseDownPoint ?? lastHoverPoint else {
            folioLog("force-click: нет точки нажатия")
            return
        }
        lookUp(at: point)
    }

    /// Точка из force click / контекстного меню: слово строго под точкой.
    func lookUp(at pagePoint: CGPoint) {
        guard let geometry, !geometry.isEmpty else {
            folioLog("lookup: на странице \(pageIndex + 1) нет текстового слоя")
            NSSound.beep()
            return
        }
        guard let index = geometry.wordIndex(at: pagePoint, tolerance: 10)
                ?? geometry.nearestWordIndex(to: pagePoint) else {
            folioLog("lookup: слово не найдено в точке (\(String(format: "%.1f", pagePoint.x)), \(String(format: "%.1f", pagePoint.y)))")
            NSSound.beep()
            return
        }
        presentLookUp(index: index, point: pagePoint, source: "point")
    }

    /// ⌘D / меню «Найти в словаре»: приоритет — выделение, затем hover, затем первое слово.
    func lookUpAtHover() {
        guard let geometry, !geometry.isEmpty else {
            folioLog("lookup: на странице \(pageIndex + 1) нет текстового слоя")
            NSSound.beep()
            return
        }
        if let selection, selection.page == pageIndex, !selection.wordIndices.isEmpty {
            let index = nearestSelectedWord(to: lastHoverPoint, in: selection, geometry: geometry)
            presentLookUp(index: index, point: lastHoverPoint, source: "selection")
            return
        }
        if let point = lastHoverPoint, let index = geometry.wordIndex(at: point, tolerance: 8) {
            presentLookUp(index: index, point: point, source: "hover")
            return
        }
        if let first = geometry.words.first {
            presentLookUp(index: 0,
                          point: CGPoint(x: first.word.bbox.midX, y: first.word.bbox.midY),
                          source: "first")
            return
        }
        folioLog("lookup: нет слова для поиска в словаре")
        NSSound.beep()
    }

    private func nearestSelectedWord(to point: CGPoint?, in selection: Selection,
                                     geometry: PageTextGeometry) -> Int {
        guard let point else { return selection.wordIndices[0] }
        var best = (index: selection.wordIndices[0], distance: CGFloat.greatestFiniteMagnitude)
        for index in selection.wordIndices where index < geometry.words.count {
            let rect = geometry.words[index].word.bbox
            let distance = PageTextGeometry.distanceToRect(point, rect)
            if distance < best.distance { best = (index, distance) }
        }
        return best.index
    }

    /// Единая точка вызова системного словаря (force click, ⌘D, контекстное меню).
    private func presentLookUp(index: Int, point: CGPoint?, source: String) {
        guard let geometry, index >= 0, index < geometry.words.count else { return }
        let ref = geometry.words[index]
        let text = ref.word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            folioLog("lookup: пустое слово под курсором")
            return
        }
        // Точка baseline слова в координатах view: у flipped NSView y = pageY * zoom.
        let baseline = CGPoint(x: CGFloat(ref.word.bbox.midX) * zoom,
                               y: CGFloat(ref.baselineY) * zoom)
        let clamped = CGPoint(x: min(max(baseline.x, 0), max(bounds.width - 1, 0)),
                              y: min(max(baseline.y, 0), max(bounds.height - 1, 0)))
        let pageX = point.map { String(format: "%.1f", $0.x) } ?? "-"
        let pageY = point.map { String(format: "%.1f", $0.y) } ?? "-"
        folioLog("lookup: page=\(pageIndex + 1) word=«\(text)» point=(\(pageX), \(pageY)) baseline=(\(String(format: "%.1f", clamped.x)), \(String(format: "%.1f", clamped.y))) source=\(source) → showDefinition(for:at:)")
        let attributed = NSAttributedString(string: text,
                                            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        showDefinition(for: attributed, at: clamped)
    }

    // MARK: - Копирование (⌘C через responder chain)

    /// Стандартное действие Edit ▸ Copy: NSResponder не объявляет `copy:`,
    /// поэтому это обычный @objc-экшен для responder chain.
    @objc func copy(_ sender: Any?) {
        model?.copySelection()
    }

    override func selectAll(_ sender: Any?) {
        guard let geometry, !geometry.isEmpty else { return }
        model?.setSelection(geometry.selection(from: 0, to: geometry.words.count - 1))
        needsDisplay = true
    }

    // MARK: - Контекстное меню

    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        let point = pagePoint(from: local)
        contextPoint = point
        lastHoverPoint = point
        hoverWordIndex = geometry?.wordIndex(at: point, tolerance: 4)
        needsDisplay = true

        let menu = NSMenu(title: "")

        let lookUpItem = NSMenuItem(title: "Найти в словаре", action: #selector(contextLookUp(_:)), keyEquivalent: "d")
        lookUpItem.keyEquivalentModifierMask = .command
        lookUpItem.target = self
        menu.addItem(lookUpItem)

        let selectWordItem = NSMenuItem(title: "Выделить слово", action: #selector(contextSelectWord(_:)), keyEquivalent: "")
        selectWordItem.target = self
        menu.addItem(selectWordItem)

        let copyItem = NSMenuItem(title: "Копировать", action: #selector(contextCopy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let debugItem = NSMenuItem(title: model?.showDebugOverlay == true ? "Скрыть разметку" : "Показать разметку",
                                   action: #selector(contextToggleDebug(_:)), keyEquivalent: "")
        debugItem.target = self
        menu.addItem(debugItem)

        return menu
    }

    @objc private func contextLookUp(_ sender: Any?) {
        let point = contextPoint ?? lastHoverPoint ?? CGPoint(x: bounds.midX, y: bounds.midY)
        lookUp(at: point)
    }

    @objc private func contextSelectWord(_ sender: Any?) {
        guard let geometry,
              let point = contextPoint ?? lastHoverPoint,
              let index = geometry.wordIndex(at: point, tolerance: 8) else { return }
        model?.setSelection(geometry.selection(from: index, to: index))
        needsDisplay = true
    }

    @objc private func contextCopy(_ sender: Any?) {
        model?.copySelection()
    }

    @objc private func contextToggleDebug(_ sender: Any?) {
        model?.toggleDebugOverlay()
    }

    // MARK: - Клавиатура

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc — снять выделение
            model?.clearSelection()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Самотесты для снапшот-приёмки

    /// Программно выделяет первые N слов страницы (проверка drag-выделения и ⌘C).
    func debugSelectFirstWords(_ count: Int) {
        guard let geometry, !geometry.isEmpty else {
            folioLog("selftest: нет геометрии для выделения")
            return
        }
        let last = max(0, min(count - 1, geometry.words.count - 1))
        let selection = geometry.selection(from: 0, to: last)
        model?.setSelection(selection)
        needsDisplay = true
        folioLog("selftest: выделено \(selection.rects.count) слов: «\(String(selection.text.prefix(140)))»")
    }

    /// Размер отрендеренного растра — для проверки, что при смене документа
    /// страница действительно перерисована, а не взята из кэша старого файла.
    var debugImagePixelSize: CGSize? {
        guard let image else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    var currentDocumentIdentity: String { documentIdentity }

    /// Подсветка слова как при наведении мышью (для снапшота).
    func debugHoverWord(_ index: Int) {
        guard let geometry, !geometry.isEmpty else { return }
        let clamped = min(max(index, 0), geometry.words.count - 1)
        hoverWordIndex = clamped
        lastHoverPoint = CGPoint(x: geometry.words[clamped].word.bbox.midX,
                                 y: geometry.words[clamped].word.bbox.midY)
        needsDisplay = true
        folioLog("selftest: hover на слове «\(geometry.words[clamped].word.text)» (стр. \(pageIndex + 1))")
    }

    /// Программно вызывает ровно тот же путь, что force click stage 2.
    func debugTriggerForceClickPath() {
        guard let geometry, let first = geometry.words.first else {
            folioLog("selftest: на странице нет слов для словаря")
            return
        }
        let point = CGPoint(x: first.word.bbox.midX, y: first.word.bbox.midY)
        mouseDownPoint = point
        lastHoverPoint = point
        folioLog("selftest: эмуляция force-click (stage 2) в точке (\(String(format: "%.1f", point.x)), \(String(format: "%.1f", point.y))) — вызываем тот же handleDeepClick → lookUp")
        handleDeepClick()
    }
}

extension PageCanvasView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(contextCopy(_:)):
            return !(model?.selection?.isEmpty ?? true)
        case #selector(contextSelectWord(_:)), #selector(contextLookUp(_:)):
            return !(geometry?.isEmpty ?? true)
        default:
            return true
        }
    }
}
