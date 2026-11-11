import AppKit
import SwiftUI

/// Headless-режим для приёмки без разрешения Screen Recording:
///
///     Folio --snapshot <outdir> [pdf] [--snapshot-dictionary] [--snapshot-debug]
///                    [--snapshot-translate]   # реальный системный перевод (нужны модели языка)
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
        /// Реальный системный перевод (нужны скачанные языковые модели), а не заглушка.
        var liveTranslation: Bool = false
        /// Реальная озвучка через AVSpeechSynthesizer (в headless-среде будет тишина).
        var liveSpeech: Bool = false
    }

    // MARK: - Разбор аргументов

    static func parseOptions() -> Options? {
        let args = CommandLine.arguments
        guard args.contains("--snapshot") else { return nil }
        var positional: [String] = []
        var zoom: Double?
        var switchPdf: URL?
        var liveTranslation = false
        var liveSpeech = false
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
            case "--snapshot-translate":
                liveTranslation = true
                index += 1
            case "--snapshot-speech":
                liveSpeech = true
                index += 1
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
        return Options(outDir: outDir, pdf: pdf, zoom: zoom, switchPdf: switchPdf,
                       liveTranslation: liveTranslation,
                       liveSpeech: liveSpeech)
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

        guard let window = waitForMainWindow(timeout: 20) else {
            folioLog("snapshot: ОКНО НЕ ПОЯВИЛОСЬ")
            try? "error: окно не создано\n".write(to: options.outDir.appendingPathComponent("summary.txt"),
                                               atomically: true, encoding: .utf8)
            exit(4)
        }
        guard let model = ReaderModel.registry.allObjects.first else {
            folioLog("snapshot: ОШИБКА — модель ридера не создалась")
            exit(5)
        }
        model.configureForSnapshot()
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
        WindowChrome.suppressSoon()
        pump(0.4)
        logToolbar(window: window, label: "после чистки хрома")

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
        runInteractionSelfTests(model: model, window: window, options: options)

        // 6b. Настройки, озвучка, перевод: значения по умолчанию, персистентность, меню
        runFeatureSelfTests(model: model, window: window, options: options)

        // Проверка инвалидации кэша при смене документа
        if let switchPdf = options.switchPdf {
            runDocumentSwitchTest(model: model, window: window, options: options, nextPdf: switchPdf)
        }

        logToolbar(window: window, label: "финал")
        writeSummary(model: model, options: options, extra: [:])
        folioLog("snapshot: ФАЙЛЫ В \(options.outDir.path): \(listFiles(options.outDir).joined(separator: ", "))")
        folioLog("snapshot: готово, чистый выход с кодом 0")
        fflush(stdout)
        fflush(stderr)
        // _exit — намеренно: обычный exit(0) запускает teardown AppKit/SwiftUI
        // (NSHostingView/NSWindow/словарная панель) и иногда падает с NSException.
        _exit(0)
    }

    private static func runInteractionSelfTests(model: ReaderModel, window: NSWindow, options: Options) {
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
        model.performLookUp()
        pump(0.3)
        pageView.copy(nil) // тот же путь, что ⌘C через responder chain
        pump(0.15)
        let pasted = NSPasteboard.general.string(forType: .string) ?? "<пусто>"
        folioLog("snapshot: в буфере обмена после copy: «\(String(pasted.prefix(140)))»")
    }

    // MARK: - Самотесты настроек, озвучки и перевода

    /// Проверяет продуктовые требования без интерактивного участия:
    /// озвучка выключена по умолчанию, пара EN(US)→RU, изменение выбора переживает
    /// «перезапуск», в контекстном меню есть словарь/перевод/озвучка/настройки.
    private static func runFeatureSelfTests(model: ReaderModel, window: NSWindow, options: Options) {
        let settings = model.settings
        folioLog("snapshot: настройки — озвучка=\(settings.speechEnabled ? "вкл" : "выкл"), пара=\(settings.translationPairTitle), скорость=\(String(format: "%.2f", settings.speechRate))")

        // Значения по умолчанию и персистентность — на отдельном suite,
        // чтобы не менять настройки пользователя этого Mac.
        let suiteName = "Folio.snapshot.settings"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            folioLog("snapshot: ОШИБКА — не удалось создать временный UserDefaults suite")
            return
        }
        suite.removePersistentDomain(forName: suiteName)

        let fresh = SettingsStore(defaults: suite)
        folioLog("snapshot: по умолчанию — озвучка=\(fresh.speechEnabled), пара=\(fresh.translationPairTitle)")
        if fresh.speechEnabled {
            folioLog("snapshot: ОШИБКА — озвучка должна быть выключена по умолчанию")
        }
        if fresh.translateSourceID != SettingsStore.defaultSourceID
            || fresh.translateTargetID != SettingsStore.defaultTargetID {
            folioLog("snapshot: ОШИБКА — пара по умолчанию \(fresh.translationPairTitle), ожидали EN(US)→RU")
        }

        // Пользователь изменил выбор — он должен сохраниться.
        fresh.translateSourceID = "en-GB"
        fresh.translateTargetID = "de-DE"
        fresh.speechEnabled = true
        fresh.speechRate = 0.42
        let reopened = SettingsStore(defaults: suite)
        let saved = reopened.reloadFromDisk()
        folioLog("snapshot: после изменения и повторного открытия — источник=\(saved.source), цель=\(saved.target), озвучка=\(saved.speechEnabled), скорость=\(String(format: "%.2f", saved.speechRate))")
        if saved.source != "en-GB" || saved.target != "de-DE"
            || !saved.speechEnabled || abs(saved.speechRate - 0.42) > 0.001 {
            folioLog("snapshot: ОШИБКА — выбор пользователя не сохранился")
        }
        suite.removePersistentDomain(forName: suiteName)
        folioLog("snapshot: проверка сохранения выбора языков завершена")

        // Выключенная озвучка не должна читать текст.
        let originalSpeechEnabled = settings.speechEnabled
        settings.speechEnabled = false
        let blocked = model.speech.speak("snapshot speech guard")
        folioLog("snapshot: speak() при выключенном флаге = \(blocked) (ожидаем false)")
        if blocked {
            folioLog("snapshot: ОШИБКА — озвучка сработала при выключенном флаге")
        }
        folioLog("snapshot: системных голосов \(model.speech.availableVoices.count), по умолчанию: \(model.speech.defaultVoiceDescription)")

        // Реальная озвучка — только по флагу: в обычном прогоне не шумим звуком.
        if options.liveSpeech {
            settings.speechEnabled = true
            let started = model.speech.speak("Folio. Проверка озвучки выделенного текста.")
            folioLog("snapshot: озвучка started=\(started), isSpeaking=\(model.speech.isSpeaking)")
            pump(1.5)
            folioLog("snapshot: озвучка во время чтения isSpeaking=\(model.speech.isSpeaking)")
            model.speech.stop()
            pump(0.3)
            folioLog("snapshot: озвучка остановлена isSpeaking=\(model.speech.isSpeaking)")
        }
        settings.speechEnabled = originalSpeechEnabled

        // Недавние документы: MRU-порядок, дедупликация, лимит, очистка.
        // Проверяем на временном UserDefaults suite — реальный список не трогаем.
        let recentsSuite = "Folio.snapshot.recents"
        if let recentsDefaults = UserDefaults(suiteName: recentsSuite) {
            recentsDefaults.removePersistentDomain(forName: recentsSuite)
            let store = RecentDocumentsStore(defaults: recentsDefaults)
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let attention = root.appendingPathComponent("samples/attention.pdf")
            let russian = root.appendingPathComponent("samples/sample-ru.pdf")
            let noText = root.appendingPathComponent("samples/no-text.pdf")

            store.note(attention)
            store.note(russian)
            store.note(noText)
            folioLog("snapshot: недавние (MRU) = \(store.documents.map(\.title))")
            store.note(attention)
            folioLog("snapshot: после повторного открытия = \(store.documents.map(\.title))")
            if store.documents.first?.url.standardizedFileURL != attention.standardizedFileURL {
                folioLog("snapshot: ОШИБКА — повторно открытый документ не поднялся в начало списка")
            }
            if Set(store.documents.map(\.id)).count != store.documents.count {
                folioLog("snapshot: ОШИБКА — в недавних есть дубликаты")
            }

            // Лимит: создаём 20 временных файлов и проверяем усечение списка.
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("folio-recents-test")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            for index in 0..<20 {
                let file = tempDir.appendingPathComponent("doc-\(index).pdf")
                FileManager.default.createFile(atPath: file.path, contents: Data())
                store.note(file)
            }
            folioLog("snapshot: лимит недавних — \(store.documents.count) из 20 добавленных (лимит \(RecentDocumentsStore.limit))")
            if store.documents.count != RecentDocumentsStore.limit {
                folioLog("snapshot: ОШИБКА — лимит недавних не соблюдается")
            }
            try? FileManager.default.removeItem(at: tempDir)
            store.clear()
            folioLog("snapshot: после очистки — \(store.documents.count) документов")
            recentsDefaults.removePersistentDomain(forName: recentsSuite)
        }

        // Подменю «Открыть недавние» должно быть в главном меню (Файл → Открыть недавние).
        if let recentMenu = RecentDocumentsMenu.submenu() {
            folioLog("snapshot: меню «Открыть недавние» найдено, пунктов: \(recentMenu.items.count)")
        } else {
            folioLog("snapshot: ОШИБКА — в главном меню нет «Открыть недавние»")
        }

        // Главное меню: команды приложения (Перевод, Озвучка, Настройки).
        let menuTitles = NSApp.mainMenu?.items.map { $0.title } ?? []
        folioLog("snapshot: главное меню = \(menuTitles.joined(separator: " | "))")
        for expected in ["Перевод", "Озвучка"] where !menuTitles.contains(expected) {
            folioLog("snapshot: ОШИБКА — в главном меню нет «\(expected)»")
        }
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           !appMenu.items.contains(where: { $0.title.contains("Настройки") }) {
            folioLog("snapshot: ОШИБКА — в меню приложения нет пункта «Настройки…»")
        }

        // Контекстное меню: словарь, перевод, озвучка, настройки.
        if let pageView = findPageView(in: window, page: 0) {
            let wordTitles = pageView.debugContextMenuTitles(atWord: 9)
            folioLog("snapshot: контекстное меню (слово) = \(wordTitles.joined(separator: " | "))")
            for expected in ["словаре", "Перевести", "Озвучить", "Настройки…"]
            where !wordTitles.contains(where: { $0.contains(expected) }) {
                folioLog("snapshot: ОШИБКА — в контекстном меню нет пункта «\(expected)»")
            }
            if let selection = model.selection, !selection.isEmpty, let first = selection.wordIndices.first {
                let selectionTitles = pageView.debugContextMenuTitles(atWord: first)
                folioLog("snapshot: контекстное меню (выделение) = \(selectionTitles.joined(separator: " | "))")
                if !selectionTitles.contains(where: { $0.contains("выделение") }) {
                    folioLog("snapshot: ОШИБКА — для выделения меню не предлагает действия с выделением")
                }
            }
        }

        // Окно настроек — настоящее окно, снимок для документации.
        SettingsWindow.shared.show()
        pump(0.9)
        if let settingsWindow = NSApp.windows.first(where: { $0.title == "Настройки Folio" }) {
            capture(window: settingsWindow, name: "settings.png", options: options)
            settingsWindow.orderOut(nil)
            folioLog("snapshot: окно настроек снято (settings.png)")
        } else {
            folioLog("snapshot: ОШИБКА — окно настроек не появилось")
        }
        pump(0.3)

        // Панель перевода. С --snapshot-translate идём настоящим путём:
        // выделение → TranslationController.request → .translationTask → системный перевод.
        var translationIsLive = false
        if options.liveTranslation {
            if let pageView = findPageView(in: window, page: 0) {
                pageView.debugSelectFirstWords(16)
                pump(0.3)
                if let selection = model.selection, !selection.isEmpty {
                    model.translation.request(text: selection.text,
                                              sourceID: "en-US",
                                              targetID: "ru-RU",
                                              origin: "выделения")
                    let finished = waitUntil(timeout: 40) {
                        model.translation.phase == .done || {
                            if case .failed = model.translation.phase { return true }
                            return false
                        }()
                    }
                    folioLog("snapshot: системный перевод — завершён=\(finished), фаза=\(model.translation.phase)")
                    if case .done = model.translation.phase {
                        translationIsLive = true
                        folioLog("snapshot: перевод системы: «\(String(model.translation.translatedText.prefix(140)))»")
                    } else if case .failed(let message) = model.translation.phase {
                        folioLog("snapshot: перевод системы не удался: \(message) — показываю заглушку")
                    }
                }
            }
        }
        if !translationIsLive {
            model.translation.debugInjectResult(
                source: "Attention is all you need. The dominant sequence transduction models are based on complex recurrent or convolutional neural networks.",
                translated: "Внимание — это всё, что нужно. Доминирующие модели преобразования последовательностей основаны на сложных рекуррентных или свёрточных нейронных сетях.",
                sourceID: "en-US",
                targetID: "ru-RU"
            )
        }
        pump(1.2)
        if let sheet = window.attachedSheet {
            capture(window: sheet, name: "translation-panel.png", options: options)
            folioLog("snapshot: панель перевода снята (translation-panel.png, \(translationIsLive ? "реальный системный перевод" : "текст-заглушка"))")
        } else {
            folioLog("snapshot: ВНИМАНИЕ — панель перевода не появилась как sheet")
        }
        model.translation.isPanelPresented = false
        pump(0.6)
    }

    /// Диагностика тулбара: какие элементы реально стоят в `NSToolbar` и где они.
    /// Нужна, чтобы ловить дубли вроде двух кнопок боковой панели.
    private static func logToolbar(window: NSWindow, label: String) {
        guard let toolbar = window.toolbar else {
            folioLog("snapshot: toolbar (\(label)) — нет тулбара")
            return
        }
        let items = toolbar.items.map { item -> String in
            var parts = [item.itemIdentifier.rawValue]
            if !item.label.isEmpty { parts.append("label=«\(item.label)»") }
            if let view = item.view {
                parts.append("view=\(type(of: view))")
                let rect = view.convert(view.bounds, to: nil)
                parts.append("frame=(x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height)))")
            }
            if !item.isVisible { parts.append("hidden") }
            return parts.joined(separator: " ")
        }
        let bounds = window.contentView?.superview?.bounds ?? .zero
        folioLog("snapshot: toolbar (\(label)) \(items.count) items, chrome w=\(Int(bounds.width)) = \(items.joined(separator: " | "))")
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
        lines.append("speech: enabled=\(model.settings.speechEnabled) (default off), rate=\(String(format: "%.2f", model.settings.speechRate)), voices=\(model.speech.availableVoices.count)")
        let translationFramework = {
            if #available(macOS 15.0, *) { return "available (macOS 15+)" }
            return "unavailable"
        }()
        lines.append("translation: pair=\(model.settings.translationPairTitle), framework=\(translationFramework)")
        lines.append("contextMenu: словарь/тезаурус (showDefinition), перевод выделения, озвучка, копировать, настройки, разметка")
        lines.append("translationPanel: \(options.liveTranslation ? "реальный системный перевод (--snapshot-translate)" : "демонстрационный текст — реальный перевод требует системных моделей")")
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
