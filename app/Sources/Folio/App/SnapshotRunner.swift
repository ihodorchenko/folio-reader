import AppKit
import SwiftUI

/// Headless-режим для приёмки без разрешения Screen Recording:
///
///     Folio --snapshot <outdir> [pdf] [--snapshot-dictionary] [--snapshot-debug]
///
/// Открывает документ в настоящем окне SwiftUI (чтобы отрисовался unified toolbar),
/// ждёт загрузки страниц и сохраняет PNG в `<outdir>`. Затем прогоняет самотесты:
/// словарь (тот же путь, что force click stage 2 / ⌘D) и копирование (⌘C).
@MainActor
enum SnapshotRunner {
    static let isSnapshotMode: Bool = CommandLine.arguments.contains("--snapshot")

    struct Options {
        var outDir: URL
        var pdf: URL
        var width: CGFloat = 1280
        var height: CGFloat = 900
        /// nil — режим «по размеру ширины» (fit width); иначе фиксированный зум (1.0 = 100%).
        var zoom: Double?
        /// Второй документ: проверка инвалидации кэша при смене файла.
        var switchPdf: URL?
    }

    // MARK: - Разбор аргументов

    static func parseOptions() -> Options? {
        let args = CommandLine.arguments
        guard args.contains("--snapshot") else { return nil }
        var positional: [String] = []
        var zoom: Double?
        var switchPdf: URL?
        var index = 1
        while index < args.count {
            let argument = args[index]
            switch argument {
            case "--snapshot", "--snapshot-debug", "--snapshot-dictionary":
                index += 1
            case "--zoom":
                if index + 1 < args.count {
                    let value = args[index + 1]
                    zoom = value.lowercased() == "fit" ? nil : Double(value)
                    index += 2
                } else {
                    index += 1
                }
            case "--switch":
                if index + 1 < args.count {
                    switchPdf = URL(fileURLWithPath: args[index + 1])
                    index += 2
                } else {
                    index += 1
                }
            default:
                if argument.hasPrefix("--") {
                    index += 1
                } else {
                    positional.append(argument)
                    index += 1
                }
            }
        }
        let outDir: URL
        if let first = positional.first {
            outDir = URL(fileURLWithPath: first)
        } else {
            outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("folio-snapshot")
        }
        let pdf: URL
        if positional.count > 1 {
            pdf = URL(fileURLWithPath: positional[1])
        } else {
            pdf = defaultDocument()
        }
        return Options(outDir: outDir, pdf: pdf, zoom: zoom, switchPdf: switchPdf)
    }

    private static func defaultDocument() -> URL {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["FOLIO_PDF"], !env.isEmpty {
            candidates.append(env)
        }
        let cwd = fm.currentDirectoryPath
        candidates += [
            "\(cwd)/samples/attention.pdf",
            "\(cwd)/pdfreader/samples/attention.pdf",
            "\(cwd)/../pdfreader/samples/attention.pdf",
        ]
        for path in candidates where fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "demo.pdf")
    }

    // MARK: - Запуск

    // Не возвращается, но объявлена как Void: Swift 6.0 иначе конфликтует по T
    // в MainActor.assumeIsolated { ... } на месте вызова.
    static func runAndExit() {
        guard let options = parseOptions() else {
            folioLog("snapshot: не удалось разобрать аргументы")
            exit(2)
        }
        // Диагностика: если на выходе всё-таки случится NSException, увидим причину.
        NSSetUncaughtExceptionHandler { exception in
            folioLog("snapshot: NSException \(exception.name.rawValue): \(exception.reason ?? "—")")
            folioLog("snapshot: stack: \(exception.callStackSymbols.prefix(12).joined(separator: " | "))")
            fflush(stderr)
        }
        // Страховка от зависания: снапшот обязан завершиться.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            folioLog("snapshot: WATCHDOG — принудительное завершение (код 3)")
            exit(3)
        }

        try? FileManager.default.createDirectory(at: options.outDir, withIntermediateDirectories: true)
        let coreVersion = CoreLibrary.shared()?.versionString ?? "нет (мок)"
        let corePath = CoreLibrary.locateDylib() ?? "—"
        folioLog("snapshot: старт. out=\(options.outDir.path), pdf=\(options.pdf.path), ядро=\(coreVersion), dylib=\(corePath)")

        RenderStore.shared.synchronous = true
        let model = ReaderModel.shared
        model.configureForSnapshot()

        guard let window = waitForMainWindow(timeout: 20) else {
            folioLog("snapshot: ОКНО НЕ ПОЯВИЛОСЬ")
            writeSummary(model: model, options: options, extra: ["error": "окно не создано"])
            exit(4)
        }
        window.appearance = NSAppearance(named: .aqua)
        NSApp.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: options.width, height: options.height))
        window.center()
        window.title = "Folio"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pump(0.5)
        model.backingScale = window.backingScaleFactor
        folioLog("snapshot: окно \(Int(window.frame.width))×\(Int(window.frame.height)) px, backingScale=\(window.backingScaleFactor)")

        model.open(url: options.pdf)
        let ready = waitUntil(timeout: 25) { model.snapshotReady }
        if let zoom = options.zoom {
            model.setZoom(zoom)
        } else {
            model.applyFitWidth()
        }
        folioLog("snapshot: документ готов=\(ready); страниц=\(model.pageCount); заголовков=\(model.headingRows.count); зум=\(String(format: "%.2f", model.zoom)); mock=\(model.isMock)")
        if !PdfCore.isMockMode && model.isMock {
            folioLog("snapshot: ВНИМАНИЕ — dylib найден, но документ открылся мок-провайдером (проверьте лог open)")
        }
        logPageCountConsistency(model: model, label: "attention")
        pump(0.8)

        // Убеждаемся, что layout видимых страниц загружен (нужен для debug-оверлея
        // и для word-боксов: без него оверлей просто не нарисуется).
        let visibleLayoutCount = min(3, model.pageCount)
        for page in 0..<visibleLayoutCount { model.requestLayout(page) }
        let layoutsReady = waitUntil(timeout: 15) {
            (0..<visibleLayoutCount).allSatisfy { model.pageLayouts[$0] != nil }
        }
        folioLog("snapshot: layout видимых страниц готов=\(layoutsReady) (\(model.pageLayouts.count) шт.)")
        pump(0.5)
        forceLayout(window)

        // 1. Основной вид
        capture(window: window, name: "root.png", options: options)

        // 2. Debug-разметка блоков
        model.setDebugMode(.blocks)
        pump(0.6)
        forceLayout(window)
        capture(window: window, name: "debug.png", options: options)

        // 3. Рамки каждого слова — проверка совпадения оверлея с глифами
        model.setDebugMode(.words)
        pump(0.5)
        forceLayout(window)
        capture(window: window, name: "debug-words.png", options: options)

        // Дальше снимаем без разметки — чище для ревью.
        model.setDebugMode(.off)
        pump(0.35)
        forceLayout(window)

        // 4. Свёрнутая боковая панель
        model.columnVisibility = .detailOnly
        pump(0.6)
        forceLayout(window)
        capture(window: window, name: "sidebar-hidden.png", options: options)
        model.columnVisibility = .all
        pump(0.5)
        forceLayout(window)

        // 5. Вкладки sidebar
        model.sidebarMode = .thumbnails
        pump(1.5)
        forceLayout(window)
        capture(window: window, name: "thumbnails.png", options: options)

        model.sidebarMode = .search
        model.searchQuery = model.isMock ? "документ" : "attention"
        model.scheduleSearch()
        pump(2.0)
        forceLayout(window)
        capture(window: window, name: "search.png", options: options)

        // 6. Возврат к структуре + переход по заголовку
        model.sidebarMode = .structure
        model.searchQuery = ""
        model.scheduleSearch()
        if let heading = model.headingRows.last, model.headingRows.count > 1 {
            folioLog("snapshot: переход к заголовку «\(heading.title)» (стр. \(heading.page + 1))")
            model.scrollTo(page: heading.page, bbox: heading.bbox)
            pump(0.8)
            forceLayout(window)
            capture(window: window, name: "scroll.png", options: options)
        }

        // 7. Тёмная тема
        window.appearance = NSAppearance(named: .darkAqua)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        pump(0.7)
        forceLayout(window)
        capture(window: window, name: "dark.png", options: options)
        window.appearance = NSAppearance(named: .aqua)
        NSApp.appearance = NSAppearance(named: .aqua)
        model.sidebarMode = .structure
        model.scrollTo(page: 0, bbox: nil)
        if model.showDebugOverlay { model.setDebugMode(.off) }
        pump(0.6)
        forceLayout(window)

        // 6. Самотесты словаря и копирования
        runInteractionSelfTests(window: window, options: options)

        // Проверка инвалидации кэша при смене документа
        if let switchPdf = options.switchPdf {
            runDocumentSwitchTest(model: model, window: window, options: options, nextPdf: switchPdf)
        }

        writeSummary(model: model, options: options, extra: [:])
        folioLog("snapshot: ФАЙЛЫ В \(options.outDir.path): \(listFiles(options.outDir).joined(separator: ", "))")
        folioLog("snapshot: готово, чистый выход с кодом 0")
        fflush(stdout)
        fflush(stderr)
        // _exit — намеренно: обычный exit(0) запускает teardown AppKit/SwiftUI
        // (NSHostingView/NSWindow/словарная панель) и иногда падает с NSException.
        _exit(0)
    }

    private static func runInteractionSelfTests(window: NSWindow, options: Options) {
        guard let pageView = findPageView(in: window, page: 0) else {
            folioLog("snapshot: НЕ НАЙДЕН PageCanvasView страницы 1 — самотесты пропущены")
            return
        }
        folioLog("snapshot: найден PageCanvasView страницы 1; проверяем словарь и копирование")
        pageView.debugTriggerForceClickPath()
        pump(0.3)

        pageView.debugSelectFirstWords(6)
        pageView.debugHoverWord(9)
        pump(0.3)
        forceLayout(window)
        capture(window: window, name: "selection.png", options: options)

        // ⌘D при наличии выделения должен взять слово из выделения, а не из hover.
        PageCanvasView.active = pageView
        folioLog("snapshot: проверяем ⌘D при выделении (ожидаем слово из выделения, source=selection)")
        ReaderModel.shared.performLookUp()
        pump(0.3)
        pageView.copy(nil) // тот же путь, что ⌘C через responder chain
        pump(0.15)
        let pasted = NSPasteboard.general.string(forType: .string) ?? "<пусто>"
        folioLog("snapshot: в буфере обмена после copy: «\(String(pasted.prefix(140)))»")
    }

    // MARK: - Проверки кэша/консистентности

    private static func logPageCountConsistency(model: ReaderModel, label: String) {
        let docPages = model.doc?.pageCount ?? -1
        let structurePages = model.structure?.pageCount ?? -1
        let scrollPages = model.pageCount
        folioLog("snapshot: pageCount [\(label)]: doc=\(docPages), structure=\(structurePages), scroll=\(scrollPages)")
        if docPages != scrollPages || (structurePages > 0 && structurePages != docPages) {
            folioLog("snapshot: ВНИМАНИЕ — pageCount расходится (doc=\(docPages), structure=\(structurePages), scroll=\(scrollPages))")
        }
    }

    private static func runDocumentSwitchTest(model: ReaderModel, window: NSWindow,
                                              options: Options, nextPdf: URL) {
        let beforeIdentity = model.docIdentity
        let beforePixels = findPageView(in: window, page: 0)?.debugImagePixelSize
        folioLog("snapshot: смена документа → \(nextPdf.lastPathComponent); было identity=\(beforeIdentity.prefix(60)), растр=\(String(describing: beforePixels))")

        model.open(url: nextPdf)
        let ready = waitUntil(timeout: 25) { model.snapshotReady }
        for page in 0..<min(3, model.pageCount) { model.requestLayout(page) }
        _ = waitUntil(timeout: 15) {
            (0..<min(3, model.pageCount)).allSatisfy { model.pageLayouts[$0] != nil }
        }
        pump(0.8)
        forceLayout(window)
        let afterIdentity = model.docIdentity
        let afterPixels = findPageView(in: window, page: 0)?.debugImagePixelSize
        folioLog("snapshot: после смены: ready=\(ready), identity=\(afterIdentity.prefix(60)), растр=\(String(describing: afterPixels)), страниц=\(model.pageCount), заголовков=\(model.headingRows.count)")
        if beforeIdentity == afterIdentity {
            folioLog("snapshot: ОШИБКА — identity не изменился")
        }
        if let beforePixels, let afterPixels, beforePixels == afterPixels {
            folioLog("snapshot: ВНИМАНИЕ — растр страницы 1 совпадает с прежним документом (возможен старый кэш)")
        }
        logPageCountConsistency(model: model, label: nextPdf.lastPathComponent)
        capture(window: window, name: "switch.png", options: options)
    }

    // MARK: - Окно

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.contentView != nil &&
            $0.styleMask.contains(.titled) &&
            $0.isVisible &&
            $0.contentView?.bounds.width ?? 0 > 100
        }
    }

    private static func waitForMainWindow(timeout: TimeInterval) -> NSWindow? {
        _ = waitUntil(timeout: timeout) { mainWindow() != nil }
        return mainWindow()
    }

    // MARK: - Захват

    @discardableResult
    private static func capture(window: NSWindow, name: String, options: Options) -> Bool {
        let target = options.outDir.appendingPathComponent(name)

        // Пытаемся захватить вместе с titlebar/toolbar, если не выходит — только контент.
        let chromeView = window.contentView?.superview
        let contentView = window.contentView
        var candidates: [NSView] = []
        if let chromeView { candidates.append(chromeView) }
        if let contentView { candidates.append(contentView) }

        for view in candidates {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard view.bounds.width > 10, view.bounds.height > 10 else { continue }

            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), rep.pixelsWide > 0 {
                view.cacheDisplay(in: view.bounds, to: rep)
                let stats = analyze(rep)
                if !stats.isBlank {
                    save(rep, to: target)
                    folioLog("snapshot: \(name) — cacheDisplay \(stats.summary) (\(Int(rep.pixelsWide))×\(Int(rep.pixelsHigh)) px)")
                    return true
                }
            }

            if let cgImage = renderLayer(view, scale: window.backingScaleFactor) {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                let stats = analyze(rep)
                if !stats.isBlank {
                    save(rep, to: target)
                    folioLog("snapshot: \(name) — layer.render \(stats.summary) (\(rep.pixelsWide)×\(rep.pixelsHigh) px)")
                    return true
                }
                folioLog("snapshot: \(name) — пустой кадр через layer.render (\(stats.summary)), пробую иначе")
            }
        }
        folioLog("snapshot: НЕ УДАЛОСЬ сохранить \(name)")
        return false
    }

    private static func save(_ rep: NSBitmapImageRep, to url: URL) {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            folioLog("snapshot: PNG-кодирование не удалось для \(url.lastPathComponent)")
            return
        }
        do {
            try data.write(to: url)
        } catch {
            folioLog("snapshot: запись \(url.path) — ошибка \(error.localizedDescription)")
        }
    }

    private static func renderLayer(_ view: NSView, scale: CGFloat) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard width > 0, height > 0 else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo) else { return nil }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
    }

    // MARK: - Анализ «пустого» кадра

    private struct Stats {
        var isBlank: Bool
        var summary: String
    }

    private static func analyze(_ rep: NSBitmapImageRep) -> Stats {
        guard let data = rep.bitmapData, rep.bitsPerPixel >= 24 else {
            return Stats(isBlank: true, summary: "нет данных")
        }
        let bytesPerRow = rep.bytesPerRow
        let samplesPerPixel = max(rep.bitsPerPixel / 8, 3)
        var rmin = 255, rmax = 0, gmin = 255, gmax = 0, bmin = 255, bmax = 0
        var count = 0
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                let offset = y * bytesPerRow + x * samplesPerPixel
                if offset + 2 < rep.bytesPerRow * rep.pixelsHigh {
                    let b = Int(data[offset])
                    let g = Int(data[offset + 1])
                    let r = Int(data[offset + 2])
                    rmin = min(rmin, r); rmax = max(rmax, r)
                    gmin = min(gmin, g); gmax = max(gmax, g)
                    bmin = min(bmin, b); bmax = max(bmax, b)
                }
                count += 1
                x += 11
            }
            y += 11
        }
        let spread = max(rmax - rmin, max(gmax - gmin, bmax - bmin))
        let blank = count == 0 || spread < 3
        return Stats(isBlank: blank,
                     summary: "samples=\(count) R[\(rmin)…\(rmax)] G[\(gmin)…\(gmax)] B[\(bmin)…\(bmax)]")
    }

    // MARK: - Поиск NSView по иерархии

    private static func findPageView(in window: NSWindow, page: Int) -> PageCanvasView? {
        guard let root = window.contentView else { return nil }
        var result: PageCanvasView?
        func walk(_ view: NSView) {
            if result != nil { return }
            if let pageView = view as? PageCanvasView, pageView.pageIndex == page {
                result = pageView
                return
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return result
    }

    // MARK: - RunLoop

    private static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private static func forceLayout(_ window: NSWindow) {
        guard let view = window.contentView?.superview else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    // MARK: - Summary

    private static func writeSummary(model: ReaderModel, options: Options, extra: [String: String]) {
        var lines: [String] = []
        lines.append("Folio snapshot")
        lines.append("out: \(options.outDir.path)")
        lines.append("pdf: \(options.pdf.path)")
        lines.append("mock: \(PdfCore.isMockMode)")
        lines.append("core: \(CoreLibrary.shared()?.versionString ?? "нет")")
        lines.append("dylib: \(CoreLibrary.locateDylib() ?? "—")")
        lines.append("status: \(model.statusText)")
        lines.append("pages: \(model.pageCount)")
        lines.append("pageCount: structure=\(model.structure?.pageCount ?? -1) vs scroll=\(model.pageCount) (doc=\(model.doc?.pageCount ?? -1))")
        lines.append("docIdentity: \(model.docIdentity)")
        lines.append("lookupPath: NSView.showDefinition(for:at:), force-click=pressureChange(stage 2) → handleDeepClick → lookUp, ⌘D=performLookUp")
        lines.append("zoom: \(String(format: "%.3f", model.zoom))")
        lines.append("debugMode: \(model.debugMode.rawValue)")
        lines.append("headings: \(model.headingRows.count)")
        for row in model.headingRows.prefix(30) {
            lines.append("  H\(row.level) p\(row.page + 1): \(row.title)")
        }
        if let structure = model.structure {
            lines.append("tagged: \(structure.tagged)")
            lines.append("outline: \(structure.outline.count)")
        }
        for (key, value) in extra {
            lines.append("\(key): \(value)")
        }
        lines.append("files: \(listFiles(options.outDir).joined(separator: ", "))")
        let text = lines.joined(separator: "\n") + "\n"
        let url = options.outDir.appendingPathComponent("summary.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func listFiles(_ directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()) ?? []
    }
}
