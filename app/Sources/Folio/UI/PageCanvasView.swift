import AppKit
import CoreGraphics

/// Document page: draws the core raster render, the text overlay
/// (hover/drag selection), the debug block layout, and handles force click.
///
/// Coordinates: the NSView is flipped (isFlipped == true), so page coordinates
/// (origin at the top-left corner of the page, y downward) match the view when divided by zoom.
final class PageCanvasView: NSView {
    /// The last page that received focus/hover — for ⌘D from the menu.
    static weak var active: PageCanvasView?

    /// The page in a specific (usually active) window: with several windows ⌘D
    /// must work with the window that has focus, not with the last hovered one.
    static func active(in window: NSWindow?) -> PageCanvasView? {
        guard let window, let root = window.contentView else { return nil }
        var found: PageCanvasView?
        func walk(_ view: NSView) {
            if found != nil { return }
            if let pageView = view as? PageCanvasView {
                found = pageView
                return
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return found
    }

    let pageIndex: Int
    weak var model: ReaderModel?

    // Page geometry
    private(set) var pageSize: CGSize = CGSize(width: 612, height: 792)
    private(set) var zoom: CGFloat = 1
    private(set) var renderScale: CGFloat = 2
    private(set) var layoutInfo: PcPageLayout?
    private(set) var geometry: PageTextGeometry?
    /// Document fingerprint: reset the page raster cache when the document changes.
    private(set) var documentIdentity = ""

    // Drawing
    private var image: CGImage?
    private var imageScale: CGFloat = .nan
    private var pendingScale: CGFloat = .nan
    /// Scale at which rendering already failed — do not retry endlessly.
    private var failedScale: CGFloat = .nan
    /// Scales that have already had one retry after a failure.
    private var retriedScales = Set<CGFloat>()
    /// The "no document" log is written once so opening does not flood the console.
    private var loggedMissingDocument = false
    var selection: Selection? { didSet { needsDisplay = true } }
    var searchRects: [PcRect] = [] { didSet { needsDisplay = true } }
    var debugMode: DebugOverlayMode = .off { didSet { needsDisplay = true } }

    // Interactivity
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
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if PageCanvasView.active === self { PageCanvasView.active = nil }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    // MARK: - Configuration from SwiftUI

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
            retriedScales = []
            loggedMissingDocument = false
            // Another document — the geometry and selection from the previous one are invalid.
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

    // MARK: - Page image

    func ensureImage() {
        guard let doc = model?.doc, pageSize.width > 1, pageSize.height > 1 else {
            if !loggedMissingDocument {
                loggedMissingDocument = true
                folioLog("render: page \(pageIndex + 1) is waiting for a document/size (doc=\(model?.doc != nil), size=\(pageSize))")
            }
            return
        }
        let scale = renderScale
        if image != nil, abs(imageScale - scale) < 0.05 { return }
        if image != nil, abs(pendingScale - scale) < 0.05 { return }
        if abs(failedScale - scale) < 0.05 {
            folioLog("render: skipping page \(pageIndex + 1) — the previous attempt at scale=\(scale) failed")
            return
        }
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
                folioLog("render: page \(page + 1) failed to render (scale \(String(format: "%.2f", Double(requested))))")
                // Transient failure (for example, the document was changing) — one retry.
                if !self.retriedScales.contains(requested) {
                    self.retriedScales.insert(requested)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard abs(self.failedScale - requested) < 0.05 else { return }
                        self.failedScale = .nan
                        self.ensureImage()
                    }
                }
                return
            }
            self.failedScale = .nan
            self.setImage(rendered, scale: requested)
            if abs(self.renderScale - requested) > 0.05 {
                self.ensureImage()
            }
        }
        // Synchronous mode (snapshot): the image is ready immediately.
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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let paper = bounds.insetBy(dx: 0.5, dy: 0.5)

        // Page shadow (drawn in the flipped coordinate system: +y is down).
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

        // For the mock, draw the real text from the layout over the mock "bars":
        // this way snapshots read like a document and hit-testing matches the picture.
        if model?.isMock == true {
            drawMockText(ctx)
        }

        // Search highlights — below the selection and hover.
        if !searchRects.isEmpty {
            fill(pageRects: searchRects, color: NSColor.systemYellow.withAlphaComponent(0.35))
            stroke(pageRects: searchRects, color: NSColor.systemOrange.withAlphaComponent(0.55), width: 1)
        }

        // Selection (merged by lines, the way Preview does it).
        if let selection, selection.page == pageIndex, !selection.rects.isEmpty {
            let active = window?.isKeyWindow ?? true
            let color = active ? NSColor.controlAccentColor.withAlphaComponent(0.26)
                               : NSColor.secondaryLabelColor.withAlphaComponent(0.18)
            fill(pageRects: selection.rects, color: color)
        }

        // Word hover.
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

        // Page border.
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(paper)
        ctx.restoreGState()

        // Debug overlay: blocks (kind/level/confidence) or boxes around individual words.
        switch debugMode {
        case .off: break
        case .blocks: drawDebugOverlay(ctx)
        case .words: drawWordBoxes(ctx)
        }

        // No focus ring for keyboard scenarios — the reader is not editable.
    }

    private func drawLoadingPlaceholder(_ ctx: CGContext) {
        let text = L10n.t("Rendering page %ld…", pageIndex + 1)
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
        // The mock render uses colored bars instead of glyphs, so the real line text
        // from the layout is drawn on top. The color is fixed: the paper is always white,
        // and in dark mode labelColor would turn white and the text would disappear.
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

    /// Thin boxes around EVERY word — the main tool for checking that the overlay
    /// matches the real PDFium glyphs.
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
            // The badge is placed ABOVE the block so it does not cover the text (inside if there is no room).
            let labelY = blockRect.minY > 12 ? blockRect.minY - 11.5 : blockRect.minY + 0.5
            let badgeRect = CGRect(x: blockRect.minX, y: labelY,
                                   width: labelSize.width + 6, height: 11.5)
            nsColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(rect: badgeRect).fill()
            (label as NSString).draw(at: CGPoint(x: badgeRect.minX + 3, y: badgeRect.minY + 0.5),
                                     withAttributes: [.font: labelFont, .foregroundColor: NSColor.white])
        }
    }

    // MARK: - Coordinates

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
        activateIfKeyWindow()
    }

    override func mouseMoved(with event: NSEvent) {
        activateIfKeyWindow()
        updateHover(atWindowPoint: event.locationInWindow)
    }

    private func activateIfKeyWindow() {
        guard window?.isKeyWindow ?? true else { return }
        PageCanvasView.active = self
    }

    override func mouseExited(with event: NSEvent) {
        lastPressureStage = 0
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

    // MARK: - Mouse: selection

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        activateIfKeyWindow()
        lastPressureStage = 0
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
            lastPressureStage = 0
            needsDisplay = true
        }
        guard !isDragging else { return }
        // Click without dragging — clear the selection (the cursor is in the text).
        model?.clearSelection()
    }

    // MARK: - Force click → system dictionary

    /// Pause between dictionary invocations: force click, ⌘D and the context menu can
    /// arrive almost simultaneously, and every `showDefinition` reloads the panel.
    static let lookUpCooldown: TimeInterval = 0.5

    /// The last pressure stage. Force Touch keeps sending events at the same stage
    /// while the finger presses, so the gesture must fire only on the transition to stage 2.
    private var lastPressureStage = 0
    /// Time of the last actual dictionary opening (systemUptime).
    private var lastLookUpTime: TimeInterval = 0
    /// How many times `showDefinition` was actually called — for acceptance checks.
    private(set) var lookUpCallCount = 0

    override func pressureChange(with event: NSEvent) {
        folioLog("force-click: pressureChange stage=\(event.stage) pressure=\(String(format: "%.2f", event.pressure)) page=\(pageIndex + 1)")
        handlePressureStage(event.stage, pressure: Double(event.pressure))
    }

    /// One gesture — one dictionary: react only to the transition to stage 2.
    func handlePressureStage(_ stage: Int, pressure: Double = 0) {
        let previous = lastPressureStage
        lastPressureStage = stage
        guard stage == 2 else { return }
        guard previous != 2 else {
            folioLog("force-click: repeated stage 2 (pressure=\(String(format: "%.2f", pressure))) — gesture already handled")
            return
        }
        handleDeepClick()
    }

    /// Common "force click" path: used both from pressureChange(stage 2)
    /// and from the programmatic emulation in snapshot mode (Force Touch is not available on CI).
    private func handleDeepClick() {
        guard let point = mouseDownPoint ?? lastHoverPoint else {
            folioLog("force-click: no click point")
            return
        }
        lookUp(at: point)
    }

    /// Point from force click / the context menu: the word strictly under the point.
    func lookUp(at pagePoint: CGPoint) {
        guard let geometry, !geometry.isEmpty else {
            folioLog("lookup: page \(pageIndex + 1) has no text layer")
            NSSound.beep()
            return
        }
        guard let index = geometry.wordIndex(at: pagePoint, tolerance: 10)
                ?? geometry.nearestWordIndex(to: pagePoint) else {
            folioLog("lookup: no word found at point (\(String(format: "%.1f", pagePoint.x)), \(String(format: "%.1f", pagePoint.y)))")
            NSSound.beep()
            return
        }
        presentLookUp(index: index, point: pagePoint, source: "point")
    }

    /// ⌘D / the "Look Up in Dictionary" menu item: selection first, then hover, then the first word.
    func lookUpAtHover() {
        guard let geometry, !geometry.isEmpty else {
            folioLog("lookup: page \(pageIndex + 1) has no text layer")
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
        folioLog("lookup: no word to look up")
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

    /// Single entry point for the system dictionary (force click, ⌘D, context menu).
    private func presentLookUp(index: Int, point: CGPoint?, source: String) {
        guard let geometry, index >= 0, index < geometry.words.count else { return }
        let ref = geometry.words[index]
        let text = ref.word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            folioLog("lookup: empty word under the cursor")
            return
        }
        // The word's baseline point in view coordinates: for a flipped NSView y = pageY * zoom.
        let baseline = CGPoint(x: CGFloat(ref.word.bbox.midX) * zoom,
                               y: CGFloat(ref.baselineY) * zoom)
        let clamped = CGPoint(x: min(max(baseline.x, 0), max(bounds.width - 1, 0)),
                              y: min(max(baseline.y, 0), max(bounds.height - 1, 0)))
        // One dictionary per short interval: several sources (force click,
        // ⌘D, context menu) must not reload the panel several times.
        let now = ProcessInfo.processInfo.systemUptime
        let sinceLast = now - lastLookUpTime
        if sinceLast < Self.lookUpCooldown {
            folioLog("lookup: skipping repeated call (source=\(source), \(String(format: "%.2f", sinceLast)) s since the last one)")
            return
        }
        lastLookUpTime = now
        lookUpCallCount += 1

        let pageX = point.map { String(format: "%.1f", $0.x) } ?? "-"
        let pageY = point.map { String(format: "%.1f", $0.y) } ?? "-"
        folioLog("lookup: page=\(pageIndex + 1) word=«\(text)» point=(\(pageX), \(pageY)) baseline=(\(String(format: "%.1f", clamped.x)), \(String(format: "%.1f", clamped.y))) source=\(source) → showDefinition(for:at:)")
        let attributed = NSAttributedString(string: text,
                                            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        showDefinition(for: attributed, at: clamped)
    }

    // MARK: - Copy (⌘C through the responder chain)

    /// The standard Edit ▸ Copy action: NSResponder does not declare `copy:`,
    /// so this is a regular @objc action for the responder chain.
    @objc func copy(_ sender: Any?) {
        model?.copySelection()
    }

    override func selectAll(_ sender: Any?) {
        guard let geometry, !geometry.isEmpty else { return }
        model?.setSelection(geometry.selection(from: 0, to: geometry.words.count - 1))
        needsDisplay = true
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        let point = pagePoint(from: local)
        contextPoint = point
        lastHoverPoint = point
        hoverWordIndex = geometry?.wordIndex(at: point, tolerance: 4)
        needsDisplay = true
        return makeContextMenu()
    }

    /// The menu is built separately from the event: this way its content can be checked
    /// in the headless acceptance run (the right-click event is not synthesized there).
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "")
        let onSelection = selectionIsUnderContextPoint()
        let speechOn = model?.settings.speechEnabled ?? false

        // 1. System dictionary/thesaurus — the same path as force click (showDefinition).
        let lookUpItem = NSMenuItem(title: onSelection ? L10n.t("Look Up Selection in Dictionary") : L10n.t("Look Up in Dictionary"),
                                    action: #selector(contextLookUp(_:)), keyEquivalent: "d")
        lookUpItem.keyEquivalentModifierMask = .command
        lookUpItem.target = self
        menu.addItem(lookUpItem)

        // 2. Translating the selection/word (the system Translation framework).
        let translateItem = NSMenuItem(title: onSelection ? L10n.t("Translate Selection…") : L10n.t("Translate Word…"),
                                       action: #selector(contextTranslate(_:)), keyEquivalent: "t")
        translateItem.keyEquivalentModifierMask = [.command, .option]
        translateItem.target = self
        translateItem.toolTip = L10n.t("Language pair: %@ (change it in Settings ⌘,)", model?.settings.translationPairTitle ?? "—")
        menu.addItem(translateItem)

        // 3. Speech (off by default — the item is then disabled and explains what to do).
        let speakItem = NSMenuItem(title: onSelection ? L10n.t("Speak Selection") : L10n.t("Speak Word"),
                                   action: #selector(contextSpeak(_:)), keyEquivalent: "")
        speakItem.target = self
        speakItem.toolTip = speechOn
            ? L10n.t("Read the text aloud (AVSpeechSynthesizer)")
            : L10n.t("Speech is off — enable it in Settings (⌘,)")
        menu.addItem(speakItem)

        menu.addItem(.separator())

        let selectWordItem = NSMenuItem(title: L10n.t("Select Word"), action: #selector(contextSelectWord(_:)), keyEquivalent: "")
        selectWordItem.target = self
        menu.addItem(selectWordItem)

        let copyItem = NSMenuItem(title: L10n.t("Copy"), action: #selector(contextCopy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: L10n.t("Settings…"), action: #selector(contextSettings(_:)), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        let debugItem = NSMenuItem(title: model?.showDebugOverlay == true ? L10n.t("Hide Layout") : L10n.t("Show Layout"),
                                   action: #selector(contextToggleDebug(_:)), keyEquivalent: "")
        debugItem.target = self
        menu.addItem(debugItem)

        return menu
    }

    /// The text the right click refers to: the selection (if the click is inside it) or the word.
    private func contextText() -> String? {
        if selectionIsUnderContextPoint(), let selection, !selection.text.isEmpty {
            return selection.text
        }
        guard let geometry, let point = contextPoint ?? lastHoverPoint else { return nil }
        let index = geometry.wordIndex(at: point, tolerance: 10) ?? geometry.nearestWordIndex(to: point)
        guard let index, let word = geometry.word(at: index) else { return nil }
        let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The right click landed on the selection (with a 6 pt tolerance — the mouse rarely hits a glyph exactly).
    private func selectionIsUnderContextPoint() -> Bool {
        guard let selection, selection.page == pageIndex, !selection.isEmpty else { return false }
        guard let point = contextPoint ?? lastHoverPoint else { return true }
        return selection.rects.contains { PageTextGeometry.distanceToRect(point, $0) <= 6 }
    }

    @objc private func contextLookUp(_ sender: Any?) {
        // Dictionary for the selection: take a word from the selection, not the "nearest to the pixel" one.
        if selectionIsUnderContextPoint() {
            lookUpAtHover()
            return
        }
        let point = contextPoint ?? lastHoverPoint ?? CGPoint(x: bounds.midX, y: bounds.midY)
        lookUp(at: point)
    }

    @objc private func contextTranslate(_ sender: Any?) {
        guard let text = contextText() else {
            folioLog("translate: no text under the cursor")
            NSSound.beep()
            return
        }
        model?.translate(text, origin: selectionIsUnderContextPoint() ? "selection" : "word")
    }

    @objc private func contextSpeak(_ sender: Any?) {
        guard let text = contextText() else {
            folioLog("speech: no text under the cursor")
            NSSound.beep()
            return
        }
        guard model?.settings.speechEnabled == true else {
            folioLog("speech: speech is off — opening settings")
            model?.presentSettings()
            return
        }
        model?.speak(text, origin: selectionIsUnderContextPoint() ? "selection" : "word")
    }

    @objc private func contextSettings(_ sender: Any?) {
        model?.presentSettings()
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

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc — clear the selection
            model?.clearSelection()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Self-tests for snapshot acceptance

    /// Programmatically selects the first N words of the page (checks drag selection and ⌘C).
    func debugSelectFirstWords(_ count: Int) {
        guard let geometry, !geometry.isEmpty else {
            folioLog("selftest: no geometry to select from")
            return
        }
        let last = max(0, min(count - 1, geometry.words.count - 1))
        let selection = geometry.selection(from: 0, to: last)
        model?.setSelection(selection)
        needsDisplay = true
        folioLog("selftest: selected \(selection.rects.count) words: «\(String(selection.text.prefix(140)))»")
    }

    /// Size of the rendered raster — for checking that on document change
    /// the page is really re-rendered rather than taken from the old file's cache.
    var debugImagePixelSize: CGSize? {
        guard let image else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    var currentDocumentIdentity: String { documentIdentity }

    /// Page render state on one line — for the debug report.
    var debugSummary: String {
        let pixels = debugImagePixelSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
        return "page=\(pageIndex + 1) image=\(pixels) layout=\(layoutInfo != nil) zoom=\(String(format: "%.2f", zoom)) lookups=\(lookUpCallCount) doc=\(documentIdentity.prefix(18))"
    }

    /// Word highlight as if hovered by the mouse (for a snapshot).
    func debugHoverWord(_ index: Int) {
        guard let geometry, !geometry.isEmpty else { return }
        let clamped = min(max(index, 0), geometry.words.count - 1)
        hoverWordIndex = clamped
        lastHoverPoint = CGPoint(x: geometry.words[clamped].word.bbox.midX,
                                 y: geometry.words[clamped].word.bbox.midY)
        needsDisplay = true
        folioLog("selftest: hover on word «\(geometry.words[clamped].word.text)» (p. \(pageIndex + 1))")
    }

    /// Programmatically invokes exactly the same path as force click stage 2.
    func debugTriggerForceClickPath() {
        guard let geometry, let first = geometry.words.first else {
            folioLog("selftest: the page has no words for the dictionary")
            return
        }
        let point = CGPoint(x: first.word.bbox.midX, y: first.word.bbox.midY)
        mouseDownPoint = point
        lastHoverPoint = point
        folioLog("selftest: emulating force-click (stage 2) at point (\(String(format: "%.1f", point.x)), \(String(format: "%.1f", point.y))) — calling the same handleDeepClick → lookUp")
        handleDeepClick()
    }
    /// Snapshot acceptance only: reset the gesture state and the dictionary counter.
    func debugResetLookUpState() {
        lastPressureStage = 0
        lastLookUpTime = 0
        lookUpCallCount = 0
    }

    /// Snapshot acceptance only: feed a sequence of pressure stages.
    func debugFeedPressureStages(_ stages: [Int]) {
        for stage in stages {
            handlePressureStage(stage, pressure: stage == 2 ? 1.0 : 0.5)
        }
    }

    /// Snapshot acceptance only: the context-menu items at the word's point.
    func debugContextMenuTitles(atWord index: Int) -> [String] {
        guard let geometry, !geometry.isEmpty else { return [] }
        let clamped = min(max(index, 0), geometry.words.count - 1)
        let rect = geometry.words[clamped].word.bbox
        contextPoint = CGPoint(x: rect.midX, y: rect.midY)
        lastHoverPoint = contextPoint
        hoverWordIndex = clamped
        let menu = makeContextMenu()
        return menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }
}

extension PageCanvasView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(contextCopy(_:)):
            return !(model?.selection?.isEmpty ?? true)
        case #selector(contextSelectWord(_:)), #selector(contextLookUp(_:)):
            return !(geometry?.isEmpty ?? true)
        case #selector(contextTranslate(_:)):
            if #available(macOS 15.0, *) {
                return contextText() != nil
            }
            return false
        case #selector(contextSpeak(_:)):
            return contextText() != nil && (model?.settings.speechEnabled ?? false)
        default:
            return true
        }
    }
}
