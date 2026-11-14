import AppKit
import SwiftUI

/// Headless mode for acceptance without the Screen Recording permission:
///
///     Folio --snapshot <outdir> [pdf] [--snapshot-dictionary] [--snapshot-debug]
///                    [--snapshot-translate]   # real system translation (language models required)
///
/// Opens the document in a real SwiftUI window (so the unified toolbar renders),
/// waits for the pages to load and saves PNGs to `<outdir>`. Then runs self-tests:
/// the dictionary (the same path as force click stage 2 / ⌘D) and copying (⌘C).
@MainActor
enum SnapshotRunner {
    static let isSnapshotMode: Bool = CommandLine.arguments.contains("--snapshot")

    struct Options {
        var outDir: URL
        var pdf: URL
        var width: CGFloat = 1280
        var height: CGFloat = 900
        /// nil — fit-width mode; otherwise a fixed zoom (1.0 = 100%).
        var zoom: Double?
        /// Second document: checks cache invalidation when the file changes.
        var switchPdf: URL?
        /// Real system translation (downloaded language models required), not a stub.
        var liveTranslation: Bool = false
        /// Real speech through AVSpeechSynthesizer (silent in a headless environment).
        var liveSpeech: Bool = false
    }

    // MARK: - Argument parsing

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

    // MARK: - Run

    // Never returns, but is declared as Void: otherwise Swift 6.0 conflicts over T
    // in MainActor.assumeIsolated { ... } at the call site.
    static func runAndExit() {
        guard let options = parseOptions() else {
            folioLog("snapshot: failed to parse arguments")
            exit(2)
        }
        // Diagnostics: if an NSException still happens on exit, we will see why.
        NSSetUncaughtExceptionHandler { exception in
            folioLog("snapshot: NSException \(exception.name.rawValue): \(exception.reason ?? "—")")
            folioLog("snapshot: stack: \(exception.callStackSymbols.prefix(12).joined(separator: " | "))")
            fflush(stderr)
        }
        // Hang guard: the snapshot must finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            folioLog("snapshot: WATCHDOG — forcing exit (code 3)")
            exit(3)
        }

        try? FileManager.default.createDirectory(at: options.outDir, withIntermediateDirectories: true)
        let coreVersion = CoreLibrary.shared()?.versionString ?? "none (mock)"
        let corePath = CoreLibrary.locateDylib() ?? "—"
        folioLog("snapshot: start. out=\(options.outDir.path), pdf=\(options.pdf.path), core=\(coreVersion), dylib=\(corePath)")

        RenderStore.shared.synchronous = true

        guard let window = waitForMainWindow(timeout: 20) else {
            folioLog("snapshot: WINDOW DID NOT APPEAR")
            try? "error: window not created\n".write(to: options.outDir.appendingPathComponent("summary.txt"),
                                                    atomically: true, encoding: .utf8)
            exit(4)
        }
        guard let model = ReaderModel.registry.allObjects.first else {
            folioLog("snapshot: ERROR — the reader model was not created")
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
        folioLog("snapshot: window \(Int(window.frame.width))×\(Int(window.frame.height)) px, backingScale=\(window.backingScaleFactor)")
        WindowChrome.suppressSoon()
        pump(0.4)
        logToolbar(window: window, label: "after chrome cleanup")

        model.open(url: options.pdf)
        let ready = waitUntil(timeout: 25) { model.snapshotReady }
        if let zoom = options.zoom {
            model.setZoom(zoom)
        } else {
            model.applyFitWidth()
        }
        folioLog("snapshot: document ready=\(ready); pages=\(model.pageCount); headings=\(model.headingRows.count); zoom=\(String(format: "%.2f", model.zoom)); mock=\(model.isMock)")
        if !PdfCore.isMockMode && model.isMock {
            folioLog("snapshot: WARNING — dylib found, but the document was opened by the mock provider (check the open log)")
        }
        logPageCountConsistency(model: model, label: "attention")
        pump(0.8)

        // Make sure the layout of the visible pages is loaded (needed for the debug
        // overlay and for word boxes: without it the overlay simply won't draw).
        let visibleLayoutCount = min(3, model.pageCount)
        for page in 0..<visibleLayoutCount { model.requestLayout(page) }
        let layoutsReady = waitUntil(timeout: 15) {
            (0..<visibleLayoutCount).allSatisfy { model.pageLayouts[$0] != nil }
        }
        folioLog("snapshot: visible page layout ready=\(layoutsReady) (\(model.pageLayouts.count) items)")
        pump(0.5)
        forceLayout(window)

        // 1. Main view
        capture(window: window, name: "root.png", options: options)

        // 2. Block debug overlay
        model.setDebugMode(.blocks)
        pump(0.6)
        forceLayout(window)
        capture(window: window, name: "debug.png", options: options)

        // 3. Boxes around every word — verify the overlay aligns with the glyphs
        model.setDebugMode(.words)
        pump(0.5)
        forceLayout(window)
        capture(window: window, name: "debug-words.png", options: options)

        // From here on we capture without overlays — cleaner for review.
        model.setDebugMode(.off)
        pump(0.35)
        forceLayout(window)

        // 4. Collapsed sidebar
        model.columnVisibility = .detailOnly
        pump(0.6)
        forceLayout(window)
        capture(window: window, name: "sidebar-hidden.png", options: options)
        model.columnVisibility = .all
        pump(0.5)
        forceLayout(window)

        // 5. Sidebar tabs
        model.sidebarMode = .thumbnails
        pump(1.5)
        forceLayout(window)
        capture(window: window, name: "thumbnails.png", options: options)

        model.sidebarMode = .search
        model.searchQuery = model.isMock ? "PDF" : "attention"
        model.scheduleSearch()
        pump(2.0)
        forceLayout(window)
        capture(window: window, name: "search.png", options: options)

        // 6. Back to structure + jump to a heading
        model.sidebarMode = .structure
        model.searchQuery = ""
        model.scheduleSearch()
        if let heading = model.headingRows.last, model.headingRows.count > 1 {
            folioLog("snapshot: jumping to heading «\(heading.title)» (page \(heading.page + 1))")
            model.scrollTo(page: heading.page, bbox: heading.bbox)
            pump(0.8)
            forceLayout(window)
            capture(window: window, name: "scroll.png", options: options)
        }

        // 7. Dark theme
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

        // 6. Dictionary and copy self-tests
        runInteractionSelfTests(model: model, window: window, options: options)

        // 6b. Settings, speech, translation: defaults, persistence, menus
        runFeatureSelfTests(model: model, window: window, options: options)

        // Cache invalidation check when the document changes
        if let switchPdf = options.switchPdf {
            runDocumentSwitchTest(model: model, window: window, options: options, nextPdf: switchPdf)
        }

        logToolbar(window: window, label: "final")
        writeSummary(model: model, options: options, extra: [:])
        folioLog("snapshot: FILES IN \(options.outDir.path): \(listFiles(options.outDir).joined(separator: ", "))")
        folioLog("snapshot: done, clean exit with code 0")
        fflush(stdout)
        fflush(stderr)
        // _exit is intentional: a regular exit(0) runs AppKit/SwiftUI teardown
        // (NSHostingView/NSWindow/dictionary panel) and sometimes crashes with an NSException.
        _exit(0)
    }

    private static func runInteractionSelfTests(model: ReaderModel, window: NSWindow, options: Options) {
        guard let pageView = findPageView(in: window, page: 0) else {
            folioLog("snapshot: page 1 PageCanvasView NOT FOUND — self-tests skipped")
            return
        }
        folioLog("snapshot: found the page 1 PageCanvasView; checking the dictionary and copying")
        pageView.debugTriggerForceClickPath()
        pump(0.3)

        pageView.debugSelectFirstWords(6)
        pageView.debugHoverWord(9)
        pump(0.3)
        forceLayout(window)
        capture(window: window, name: "selection.png", options: options)

        // Force Touch sends several stage 2 events in a row — the dictionary must open once.
        pageView.debugResetLookUpState()
        pageView.debugFeedPressureStages([1, 2, 2, 2, 2, 2])
        let singleGestureCalls = pageView.lookUpCallCount
        folioLog("snapshot: pressure stages (1,2,2,2,2,2) — dictionary calls=\(singleGestureCalls) (expected 1)")
        if singleGestureCalls != 1 {
            folioLog("snapshot: ERROR — repeated stage 2 opens the dictionary more than once")
        }

        // Two gestures in a row within the cooldown must not reload the panel.
        pageView.debugResetLookUpState()
        pageView.debugFeedPressureStages([1, 2])
        pageView.debugFeedPressureStages([1, 2])
        folioLog("snapshot: two gestures in a row — calls=\(pageView.lookUpCallCount) (expected 1, cooldown \(PageCanvasView.lookUpCooldown) s)")
        if pageView.lookUpCallCount != 1 {
            folioLog("snapshot: ERROR — the dictionary cooldown did not work")
        }
        pump(PageCanvasView.lookUpCooldown + 0.25)
        pageView.debugFeedPressureStages([1, 2])
        folioLog("snapshot: after the pause — calls=\(pageView.lookUpCallCount) (expected 2)")
        if pageView.lookUpCallCount != 2 {
            folioLog("snapshot: ERROR — the dictionary did not open after the pause")
        }

        // ⌘D with a selection must take the word from the selection, not from hover.
        // Let the dictionary cooldown expire, otherwise the ⌘D check gets throttled.
        pump(PageCanvasView.lookUpCooldown + 0.25)
        PageCanvasView.active = pageView
        folioLog("snapshot: checking ⌘D with a selection (expected: a word from the selection, source=selection)")
        model.performLookUp()
        pump(0.3)
        pageView.copy(nil) // the same path as ⌘C through the responder chain
        pump(0.15)
        let pasted = NSPasteboard.general.string(forType: .string) ?? "<empty>"
        folioLog("snapshot: pasteboard after copy: «\(String(pasted.prefix(140)))»")

        // Structure of the fragment: the text is rebuilt from the layout, so the visual line
        // breaks inside a paragraph never reach the translation (the system translator segments
        // on them, and a sentence split over two lines came out as two paragraphs).
        pageView.debugSelectFirstBlock()
        pump(0.2)
        if let selection = model.selection {
            let withoutParagraphs = selection.text.replacingOccurrences(of: "\n\n", with: "")
            folioLog("snapshot: whole-block selection: unit=\(selection.unit.rawValue) (expected sentence), text: «\(selection.text)»")
            if selection.unit != .sentence {
                folioLog("snapshot: ERROR — the whole block should be detected as a sentence")
            }
            if withoutParagraphs.contains("\n") {
                folioLog("snapshot: ERROR — the selection keeps a visual line break inside a paragraph")
            }
            if selection.text.contains("  ") {
                folioLog("snapshot: ERROR — the selection text has doubled spaces")
            }
        } else {
            folioLog("snapshot: ERROR — no selection for the structure check")
        }

        // Selection action bar: appears for more than one word and yields to any other action.
        pageView.debugSelectFirstWords(6)
        pump(0.2)
        folioLog("snapshot: action bar for a 6-word selection = \(model.isSelectionBarVisible) (expected true)")
        if !model.isSelectionBarVisible {
            folioLog("snapshot: ERROR — the action bar did not appear for a multi-word selection")
        }
        pageView.debugSelectFirstWords(1)
        pump(0.1)
        folioLog("snapshot: action bar for a single word = \(model.isSelectionBarVisible) (expected false)")
        if model.isSelectionBarVisible {
            folioLog("snapshot: ERROR — the action bar appeared for a single word")
        }
        pageView.debugSelectFirstWords(6)
        pump(0.1)
        model.beginPointerSelection()
        if model.isSelectionBarVisible {
            folioLog("snapshot: ERROR — the action bar is visible during a drag")
        }
        model.endPointerSelection()
        if !model.isSelectionBarVisible {
            folioLog("snapshot: ERROR — the action bar did not return after the drag")
        }
        window.makeKey()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        folioLog("snapshot: action bar while a menu is tracked = \(model.isSelectionBarVisible) (expected false)")
        if model.isSelectionBarVisible {
            folioLog("snapshot: ERROR — the action bar stayed while a menu was tracked")
        }
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        folioLog("snapshot: action bar after the menu closed = \(model.isSelectionBarVisible) (expected true, window key = \(window.isKeyWindow))")
        if !model.isSelectionBarVisible {
            folioLog("snapshot: ERROR — the action bar did not return after the menu closed")
        }
        _ = model.copySelection()
        folioLog("snapshot: action bar after copy = \(model.isSelectionBarVisible) (expected false)")
        if model.isSelectionBarVisible {
            folioLog("snapshot: ERROR — the action bar stayed after copy")
        }
    }

    // MARK: - Settings, speech and translation self-tests

    /// Checks product requirements without interactive input:
    /// speech is off by default, the pair is EN(US)→RU, a changed selection survives
    /// a «restart», and the context menu has dictionary/translation/speech/settings.
    private static func runFeatureSelfTests(model: ReaderModel, window: NSWindow, options: Options) {
        let settings = model.settings
        folioLog("snapshot: settings — speech=\(settings.speechEnabled ? "on" : "off"), pair=\(settings.translationPairTitle), rate=\(String(format: "%.2f", settings.speechRate))")

        // Defaults and persistence — on a separate suite,
        // so we don't change the settings of this Mac's user.
        let suiteName = "Folio.snapshot.settings"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            folioLog("snapshot: ERROR — could not create the temporary UserDefaults suite")
            return
        }
        suite.removePersistentDomain(forName: suiteName)

        let fresh = SettingsStore(defaults: suite)
        folioLog("snapshot: defaults — speech=\(fresh.speechEnabled), pair=\(fresh.translationPairTitle)")
        if fresh.speechEnabled {
            folioLog("snapshot: ERROR — speech must be off by default")
        }
        if fresh.translateSourceID != SettingsStore.defaultSourceID
            || fresh.translateTargetID != SettingsStore.defaultTargetID {
            folioLog("snapshot: ERROR — default pair \(fresh.translationPairTitle), expected EN(US)→RU")
        }

        // The user changed the selection — it must be saved.
        fresh.translateSourceID = "en-GB"
        fresh.translateTargetID = "de-DE"
        fresh.speechEnabled = true
        fresh.speechRate = 0.42
        let reopened = SettingsStore(defaults: suite)
        let saved = reopened.reloadFromDisk()
        folioLog("snapshot: after change and reopen — source=\(saved.source), target=\(saved.target), speech=\(saved.speechEnabled), rate=\(String(format: "%.2f", saved.speechRate))")
        if saved.source != "en-GB" || saved.target != "de-DE"
            || !saved.speechEnabled || abs(saved.speechRate - 0.42) > 0.001 {
            folioLog("snapshot: ERROR — the user's selection was not saved")
        }
        suite.removePersistentDomain(forName: suiteName)
        folioLog("snapshot: language selection persistence check finished")

        // Disabled speech must not read anything.
        let originalSpeechEnabled = settings.speechEnabled
        settings.speechEnabled = false
        let blocked = model.speech.speak("snapshot speech guard")
        folioLog("snapshot: speak() with the flag off = \(blocked) (expected false)")
        if blocked {
            folioLog("snapshot: ERROR — speech ran while the flag was off")
        }
        folioLog("snapshot: system voices \(model.speech.availableVoices.count), default: \(model.speech.defaultVoiceDescription)")

        // Real speech only with the flag: a normal run does not make noise.
        if options.liveSpeech {
            settings.speechEnabled = true
            let started = model.speech.speak("Folio. Speech check for the selected text.")
            folioLog("snapshot: speech started=\(started), isSpeaking=\(model.speech.isSpeaking)")
            pump(1.5)
            folioLog("snapshot: speech while reading isSpeaking=\(model.speech.isSpeaking)")
            model.speech.stop()
            pump(0.3)
            folioLog("snapshot: speech stopped isSpeaking=\(model.speech.isSpeaking)")
        }
        settings.speechEnabled = originalSpeechEnabled

        // Prefetch/render race: a page requested during prefetch must receive
        // its image through the callback instead of staying white.
        if let doc = model.doc {
            RenderStore.shared.synchronous = false
            let scale = 1.5
            // Pick a page that exists in this document (the Russian sample has only 3 pages).
            let testPage = max(0, min(1, model.pageCount - 1))
            let prefix = "race-test:\(UUID().uuidString)"
            RenderStore.shared.prefetch(page: testPage, scale: scale, provider: doc, prefix: prefix)
            var receivedSize: CGSize?
            RenderStore.shared.image(page: testPage, scale: scale, provider: doc, prefix: prefix) { image in
                receivedSize = image.map { CGSize(width: $0.width, height: $0.height) }
            }
            let gotImage = waitUntil(timeout: 6) { receivedSize != nil }
            folioLog("snapshot: prefetch/render race — image received=\(gotImage), size=\(String(describing: receivedSize))")
            if !gotImage {
                folioLog("snapshot: ERROR — a page requested during prefetch did not get an image")
            }
            RenderStore.shared.synchronous = true
        }

        // Recent documents: MRU order, deduplication, limit, clearing.
        // Checked against a temporary UserDefaults suite — the real list is untouched.
        let recentsSuite = "Folio.snapshot.recents"
        if let recentsDefaults = UserDefaults(suiteName: recentsSuite) {
            recentsDefaults.removePersistentDomain(forName: recentsSuite)
            let store = RecentDocumentsStore(defaults: recentsDefaults)
            // The fixtures directory comes from the open document, not from the cwd:
            // the app may be launched from any directory (e.g. «/» as Finder does).
            let samplesDir = model.documentURL?.deletingLastPathComponent()
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("samples")
            let attention = samplesDir.appendingPathComponent("attention.pdf")
            let russian = samplesDir.appendingPathComponent("sample-ru.pdf")
            let noText = samplesDir.appendingPathComponent("no-text.pdf")

            guard FileManager.default.fileExists(atPath: attention.path),
                  FileManager.default.fileExists(atPath: russian.path),
                  FileManager.default.fileExists(atPath: noText.path) else {
                folioLog("snapshot: recents check skipped — no fixtures in \(samplesDir.path)")
                recentsDefaults.removePersistentDomain(forName: recentsSuite)
                return
            }

            store.note(attention)
            store.note(russian)
            store.note(noText)
            folioLog("snapshot: recent documents (MRU) = \(store.documents.map(\.title))")
            store.note(attention)
            folioLog("snapshot: after reopening = \(store.documents.map(\.title))")
            if store.documents.first?.url.standardizedFileURL != attention.standardizedFileURL {
                folioLog("snapshot: ERROR — a reopened document did not move to the top of the list")
            }
            if Set(store.documents.map(\.id)).count != store.documents.count {
                folioLog("snapshot: ERROR — the recent documents contain duplicates")
            }

            // Limit: create 20 temporary files and check that the list is truncated.
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("folio-recents-test")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            for index in 0..<20 {
                let file = tempDir.appendingPathComponent("doc-\(index).pdf")
                FileManager.default.createFile(atPath: file.path, contents: Data())
                store.note(file)
            }
            folioLog("snapshot: recent documents limit — \(store.documents.count) of 20 added (limit \(RecentDocumentsStore.limit))")
            if store.documents.count != RecentDocumentsStore.limit {
                folioLog("snapshot: ERROR — the recent documents limit is not enforced")
            }
            try? FileManager.default.removeItem(at: tempDir)
            store.clear()
            folioLog("snapshot: after clearing — \(store.documents.count) documents")
            recentsDefaults.removePersistentDomain(forName: recentsSuite)
        }

        // The «Open Recent» submenu must be in the main menu (File → Open Recent).
        if let recentMenu = RecentDocumentsMenu.submenu() {
            folioLog("snapshot: «Open Recent» menu found, items: \(recentMenu.items.count)")
        } else {
            folioLog("snapshot: ERROR — the main menu has no «Open Recent»")
        }

        // Main menu: the app's commands (Translation, Speech, Settings).
        let menuTitles = NSApp.mainMenu?.items.map { $0.title } ?? []
        folioLog("snapshot: main menu = \(menuTitles.joined(separator: " | "))")
        for expected in [L10n.t("Translation"), L10n.t("Speech")] where !menuTitles.contains(expected) {
            folioLog("snapshot: ERROR — the main menu has no «\(expected)»")
        }
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           !appMenu.items.contains(where: { $0.title == L10n.t("Settings…") }) {
            folioLog("snapshot: ERROR — the application menu has no «\(L10n.t("Settings…"))» item")
        }

        // Context menu: dictionary, translation, speech, settings.
        if let pageView = findPageView(in: window, page: 0) {
            let wordTitles = pageView.debugContextMenuTitles(atWord: 9)
            folioLog("snapshot: context menu (word) = \(wordTitles.joined(separator: " | "))")
            let wordExpected = [L10n.t("Look Up in Dictionary"), L10n.t("Translate Word…"),
                                L10n.t("Speak Word"), L10n.t("Settings…")]
            for expected in wordExpected where !wordTitles.contains(expected) {
                folioLog("snapshot: ERROR — the context menu has no «\(expected)» item")
            }
            if let selection = model.selection, !selection.isEmpty, let first = selection.wordIndices.first {
                let selectionTitles = pageView.debugContextMenuTitles(atWord: first)
                folioLog("snapshot: context menu (selection) = \(selectionTitles.joined(separator: " | "))")
                let selectionExpected = [L10n.t("Look Up Selection in Dictionary"),
                                         L10n.t("Translate Selection…"),
                                         L10n.t("Speak Selection")]
                if !selectionExpected.contains(where: { selectionTitles.contains($0) }) {
                    folioLog("snapshot: ERROR — the context menu offers no selection actions")
                }
            }
        }

        // Settings window — a real window, captured for documentation.
        SettingsWindow.shared.show()
        pump(0.9)
        if let settingsWindow = NSApp.windows.first(where: { $0.title == L10n.t("Folio Settings") }) {
            capture(window: settingsWindow, name: "settings.png", options: options)
            settingsWindow.orderOut(nil)
            folioLog("snapshot: settings window captured (settings.png)")
        } else {
            folioLog("snapshot: ERROR — the settings window did not appear")
        }
        pump(0.3)

        // Translation panel. With --snapshot-translate we take the real path:
        // selection → TranslationController.request → .translationTask → system translation.
        var translationIsLive = false
        if options.liveTranslation {
            if let pageView = findPageView(in: window, page: 0) {
                pageView.debugSelectFirstBlock()
                pump(0.3)
                if let selection = model.selection, !selection.isEmpty {
                    // Through the model, not the controller: the same path the reader uses,
                    // so the bubble gets its anchor (page + rects) and shows up.
                    model.translate(selection.text, origin: "selection")
                    let finished = waitUntil(timeout: 40) {
                        model.translation.phase == .done || {
                            if case .failed = model.translation.phase { return true }
                            return false
                        }()
                    }
                    folioLog("snapshot: system translation — finished=\(finished), phase=\(model.translation.phase)")
                    if case .done = model.translation.phase {
                        translationIsLive = true
                        folioLog("snapshot: system translation: «\(String(model.translation.translatedText.prefix(140)))»")
                    } else if case .failed(let message) = model.translation.phase {
                        folioLog("snapshot: system translation failed: \(message) — showing the stub")
                    }
                }
            }
        }
        if !translationIsLive {
            // Simulated system translation result — the English source localized to the UI language.
            // The bubble is anchored to the selection, so make sure there is one to point at.
            if model.selection?.isEmpty ?? true, let pageView = findPageView(in: window, page: 0) {
                pageView.debugSelectFirstBlock()
                pump(0.3)
            }
            model.translation.debugInjectResult(
                source: "Attention is all you need. The dominant sequence transduction models are based on complex recurrent or convolutional neural networks.",
                translated: L10n.t("Attention is all you need. The dominant sequence transduction models are based on complex recurrent or convolutional neural networks."),
                sourceID: "en-US",
                targetID: "ru-RU",
                page: model.selection?.page ?? 0,
                rects: model.selection?.rects ?? []
            )
        }
        pump(1.2)
        if captureTranslationPopover(in: window, name: "translation-panel.png", options: options) {
            folioLog("snapshot: translation bubble captured (translation-panel.png, \(translationIsLive ? "real system translation" : "stub text"))")
        } else {
            folioLog("snapshot: WARNING — the translation bubble did not appear as a popover")
        }
        model.translation.isPanelPresented = false
        pump(0.6)
        if popoverWindow() != nil {
            folioLog("snapshot: WARNING — the translation bubble is still on screen after dismissal")
        } else {
            folioLog("snapshot: translation bubble dismissed on request, no lingering window")
        }
    }

    /// Toolbar diagnostics: which items are actually in the `NSToolbar` and where.
    /// Needed to catch duplicates like two sidebar buttons.
    private static func logToolbar(window: NSWindow, label: String) {
        guard let toolbar = window.toolbar else {
            folioLog("snapshot: toolbar (\(label)) — no toolbar")
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

    // MARK: - Cache/consistency checks

    private static func logPageCountConsistency(model: ReaderModel, label: String) {
        let docPages = model.doc?.pageCount ?? -1
        let structurePages = model.structure?.pageCount ?? -1
        let scrollPages = model.pageCount
        folioLog("snapshot: pageCount [\(label)]: doc=\(docPages), structure=\(structurePages), scroll=\(scrollPages)")
        if docPages != scrollPages || (structurePages > 0 && structurePages != docPages) {
            folioLog("snapshot: WARNING — pageCount mismatch (doc=\(docPages), structure=\(structurePages), scroll=\(scrollPages))")
        }
    }

    private static func runDocumentSwitchTest(model: ReaderModel, window: NSWindow,
                                              options: Options, nextPdf: URL) {
        let beforeIdentity = model.docIdentity
        let beforePixels = findPageView(in: window, page: 0)?.debugImagePixelSize
        folioLog("snapshot: switching document → \(nextPdf.lastPathComponent); was identity=\(beforeIdentity.prefix(60)), bitmap=\(String(describing: beforePixels))")

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
        folioLog("snapshot: after the switch: ready=\(ready), identity=\(afterIdentity.prefix(60)), bitmap=\(String(describing: afterPixels)), pages=\(model.pageCount), headings=\(model.headingRows.count)")
        if beforeIdentity == afterIdentity {
            folioLog("snapshot: ERROR — identity did not change")
        }
        if let beforePixels, let afterPixels, beforePixels == afterPixels {
            folioLog("snapshot: WARNING — the page 1 bitmap matches the previous document (stale cache possible)")
        }
        logPageCountConsistency(model: model, label: nextPdf.lastPathComponent)
        capture(window: window, name: "switch.png", options: options)
    }

    // MARK: - Window

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

    // MARK: - Capture

    @discardableResult
    private static func capture(window: NSWindow, name: String, options: Options) -> Bool {
        let target = options.outDir.appendingPathComponent(name)

        // Try to capture with the titlebar/toolbar; if that fails, content only.
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
                folioLog("snapshot: \(name) — blank frame via layer.render (\(stats.summary)), trying another way")
            }
        }
        folioLog("snapshot: FAILED to save \(name)")
        return false
    }

    // MARK: - Popovers

    /// The translation bubble is a system popover: it lives in its own window, so a snapshot of
    /// the reader window alone would miss it. Render both windows and stack them.
    private static func captureTranslationPopover(in mainWindow: NSWindow, name: String,
                                                  options: Options) -> Bool {
        guard let bubble = popoverWindow() else {
            folioLog("snapshot: no popover window — the bubble did not open")
            return false
        }
        guard let bubbleImage = image(of: bubble, includingChrome: false) else {
            folioLog("snapshot: the popover window did not render")
            return capture(window: bubble, name: name, options: options)
        }
        guard let mainImage = image(of: mainWindow, includingChrome: true) else {
            return capture(window: bubble, name: name, options: options)
        }

        let mainFrame = mainWindow.frame
        let bubbleFrame = bubble.frame
        let union = mainFrame.union(bubbleFrame)
        let scale = mainWindow.backingScaleFactor
        let widthPx = Int((union.width * scale).rounded())
        let heightPx = Int((union.height * scale).rounded())
        guard widthPx > 10, heightPx > 10,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: widthPx, pixelsHigh: heightPx,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            return false
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // The bitmap context works in pixels while the windows are measured in points.
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: union.width, height: union.height).fill()
        mainImage.draw(in: NSRect(x: mainFrame.minX - union.minX,
                                  y: mainFrame.minY - union.minY,
                                  width: mainFrame.width, height: mainFrame.height))
        bubbleImage.draw(in: NSRect(x: bubbleFrame.minX - union.minX,
                                    y: bubbleFrame.minY - union.minY,
                                    width: bubbleFrame.width, height: bubbleFrame.height))
        NSGraphicsContext.restoreGraphicsState()

        let stats = analyze(rep)
        guard !stats.isBlank else {
            folioLog("snapshot: popover composite is blank (\(stats.summary))")
            return false
        }
        save(rep, to: options.outDir.appendingPathComponent(name))
        folioLog("snapshot: \(name) — popover composite \(stats.summary) (\(widthPx)×\(heightPx) px)")
        return true
    }

    /// The translation bubble: its own `NSPopover` window, marked by `TranslationPopover`.
    private static func popoverWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && window.identifier?.rawValue == TranslationPopover.windowIdentifier
        }
    }

    /// Window content straight from the window server — materials, rounded corners and alpha
    /// included. Only the app's own windows are read, so no Screen Recording permission is needed.
    private static func screenImage(of window: NSWindow) -> NSImage? {
        guard window.windowNumber > 0 else { return nil }
        guard let cgImage = CGWindowListCreateImage(.null,
                                                    .optionIncludingWindow,
                                                    CGWindowID(window.windowNumber),
                                                    [.boundsIgnoreFraming, .bestResolution]) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: window.frame.size)
    }

    /// Snapshot of a window as an `NSImage` in points (titlebar included when asked).
    private static func image(of window: NSWindow, includingChrome: Bool) -> NSImage? {
        // The window server renders materials, shadows and vibrancy; an offscreen `cacheDisplay`
        // of a SwiftUI popover draws its text but not its translucent background.
        if let screenshot = screenImage(of: window) { return screenshot }

        guard let content = window.contentView else { return nil }
        var candidates: [NSView] = []
        if includingChrome, let chrome = content.superview { candidates.append(chrome) }
        candidates.append(content)

        for view in candidates {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard view.bounds.width > 10, view.bounds.height > 10 else { continue }

            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), rep.pixelsWide > 0 {
                view.cacheDisplay(in: view.bounds, to: rep)
                if !analyze(rep).isBlank {
                    // The rep is in pixels: pin its size to the view's points so that drawing it
                    // into a point-based rectangle does not scale or clip the content.
                    rep.size = view.bounds.size
                    let image = NSImage(size: view.bounds.size)
                    image.addRepresentation(rep)
                    return image
                }
            }
            if let cgImage = renderLayer(view, scale: window.backingScaleFactor),
               !analyze(NSBitmapImageRep(cgImage: cgImage)).isBlank {
                return NSImage(cgImage: cgImage, size: view.bounds.size)
            }
        }
        return nil
    }

    private static func save(_ rep: NSBitmapImageRep, to url: URL) {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            folioLog("snapshot: PNG encoding failed for \(url.lastPathComponent)")
            return
        }
        do {
            try data.write(to: url)
        } catch {
            folioLog("snapshot: writing \(url.path) — error \(error.localizedDescription)")
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

    // MARK: - Blank frame analysis

    private struct Stats {
        var isBlank: Bool
        var summary: String
    }

    private static func analyze(_ rep: NSBitmapImageRep) -> Stats {
        guard let data = rep.bitmapData, rep.bitsPerPixel >= 24 else {
            return Stats(isBlank: true, summary: "no data")
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

    // MARK: - Find NSView in the hierarchy

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
        lines.append("core: \(CoreLibrary.shared()?.versionString ?? "none")")
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
        lines.append("contextMenu: dictionary/thesaurus (showDefinition), translate selection, speak, copy, settings, layout")
        lines.append("translationBubble: \(options.liveTranslation ? "real system translation (--snapshot-translate)" : "demo text — real translation requires system models")")
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
