import SwiftUI
import AppKit

// MARK: - Точка входа

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Окно = книга. Значение `URL?` приходит из Finder/`open` при открытии файла,
        // поэтому у каждого окна своя `ReaderModel` и свой документ.
        WindowGroup("Folio", id: ReaderScene.windowGroupID, for: URL.self) { $documentURL in
            ReaderScene(documentURL: documentURL)
        }
        .defaultSize(width: 1280, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands() }
    }
}

// MARK: - Делегат приложения

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var eventMonitors: [Any?] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        WindowReport.event("willFinishLaunching")
        NSApp.setActivationPolicy(SnapshotRunner.isSnapshotMode ? .accessory : .regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowReport.event("didFinishLaunching, окон=\(NSApp.windows.count)")
        if SnapshotRunner.isSnapshotMode {
            // ВАЖНО: запускать через Timer, а не DispatchQueue.main.async.
            // Внутри блока main-queue вложенный RunLoop не может разбудить
            // Swift Concurrency (main queue занят), и модель не загрузится.
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
                MainActor.assumeIsolated {
                    SnapshotRunner.runAndExit()
                }
            }
            return
        }
        installEventMonitors()
        WindowChrome.install()
        WindowChrome.suppressSoon()
        WindowHygiene.scheduleLaunchCleanup()
        RecentDocumentsMenu.shared.install()
        WindowReport.startIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Окна восстанавливаем сами: последняя книга + место чтения. Системное
    /// восстановление окон отключено — именно оно поднимало лишние окна при запуске.
    func applicationShouldSaveApplicationState(_ application: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ application: NSApplication) -> Bool { false }

    /// Двойной клик по PDF в Finder / «Открыть с помощью → Folio».
    /// Каждый файл открывается в своём окне; уже открытые книги не меняются.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !SnapshotRunner.isSnapshotMode else { return }
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        WindowReport.event("open-событие: \(urls.map(\.lastPathComponent)), окон=\(NSApp.windows.count)")
        for url in (pdfs.isEmpty ? urls : pdfs) {
            folioLog("launchservices: открываем \(url.path)")
            WindowRouter.shared.openDocument(url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowReport.event("shouldHandleReopen hasVisibleWindows=\(flag) окон=\(NSApp.windows.count)")
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        // SwiftUI может пересобрать главное меню — возвращаем наш делегат.
        RecentDocumentsMenu.shared.refresh()
    }

    /// Перед выходом сохраняем место чтения во всех окнах.
    func applicationWillTerminate(_ notification: Notification) {
        guard !SnapshotRunner.isSnapshotMode else { return }
        for model in ReaderModel.registry.allObjects {
            model.persistReadingPosition()
        }
    }

    /// ⌘C / ⌘D над страницей: страница — не NSTextView, поэтому обрабатываем сами.
    ///
    /// Локальные мониторы событий вызываются на главном потоке, но их замыкания
    /// не изолированы на MainActor. Событие передаём через `@unchecked Sendable`
    /// обёртку (событие живёт только внутри вызова на главном потоке), а наружу
    /// возвращаем `Bool` — «событие обработано», чтобы не тащить NSEvent через границу.
    private func installEventMonitors() {
        let copyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let box = MainThreadEvent(event)
            let handled = MainActor.assumeIsolated { AppDelegate.handleCopyKey(box.event) }
            return handled ? nil : event
        }
        let dictionaryMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let box = MainThreadEvent(event)
            let handled = MainActor.assumeIsolated { AppDelegate.handleDictionaryKey(box.event) }
            return handled ? nil : event
        }
        eventMonitors = [copyMonitor, dictionaryMonitor]
    }

    /// ⌘C: страница — не NSTextView, поэтому копируем выделение сами.
    /// Возвращает `true`, если событие обработано и системный Copy не нужен.
    @MainActor
    private static func handleCopyKey(_ event: NSEvent) -> Bool {
        guard isCommandKey(event, "c") else { return false }
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
            return false // пусть системный Copy обработает поле ввода
        }
        guard let model = ReaderModel.active,
              let selection = model.selection, !selection.isEmpty else { return false }
        _ = model.copySelection()
        return true
    }

    /// ⌘D: словарь по выделению / под курсором в активном окне.
    @MainActor
    private static func handleDictionaryKey(_ event: NSEvent) -> Bool {
        guard isCommandKey(event, "d") else { return false }
        guard let model = ReaderModel.active else { return false }
        model.performLookUp()
        return true
    }

    private static func isCommandKey(_ event: NSEvent, _ character: String) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.shift),
              !flags.contains(.option),
              !flags.contains(.control) else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == character
    }
}

/// Обёртка для передачи `NSEvent` через границу изоляции на главный актор.
/// Безопасно: событие не покидает главный поток и используется только внутри вызова.
private struct MainThreadEvent: @unchecked Sendable {
    let event: NSEvent
    init(_ event: NSEvent) { self.event = event }
}

// MARK: - Меню

/// Команды работают с моделью активного окна: у каждого окна своя книга.
struct AppCommands: Commands {
    @FocusedValue(\.readerModel) private var focusedModel: ReaderModel?

    /// Модель активной сцены; до появления фокуса — модель активного окна.
    private var model: ReaderModel? { focusedModel ?? ReaderModel.active }

    /// Системный перевод появился в macOS 15 — до этого пункты отключаем.
    private var translationAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private var hasSelection: Bool {
        !(model?.selection?.isEmpty ?? true)
    }

    /// Недавние документы: подменю всегда строится из актуального списка.
    private var recents: RecentDocumentsStore { RecentDocumentsStore.shared }

    /// Недавний документ открывается в текущем окне (как «Открыть…»);
    /// если окна ещё нет — маршрутизатор создаст первое.
    private func openRecent(_ url: URL) {
        if let model {
            model.open(url: url)
        } else {
            WindowRouter.shared.openDocument(url)
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новое окно") { WindowRouter.shared.openNewWindow() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Открыть…") { model?.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Открыть недавние") {
                if recents.documents.isEmpty {
                    Text("Нет недавних документов")
                } else {
                    ForEach(recents.documents) { document in
                        Button(document.title) { openRecent(document.url) }
                    }
                    Divider()
                    Button("Очистить меню") { recents.clear() }
                }
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Настройки…") { model?.presentSettings() ?? SettingsWindow.shared.show() }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Вид") {
            Button("Увеличить") { model?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Уменьшить") { model?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Фактический размер (100%)") { model?.actualSize() }
                .keyboardShortcut("1", modifiers: .command)
            Button("По размеру ширины") { model?.toggleFitWidth() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button(model?.debugMode == .blocks ? "Скрыть разметку блоков" : "Разметка блоков") {
                guard let model else { return }
                model.setDebugMode(model.debugMode == .blocks ? .off : .blocks)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Button(model?.debugMode == .words ? "Скрыть рамки слов" : "Рамки слов") {
                guard let model else { return }
                model.setDebugMode(model.debugMode == .words ? .off : .words)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            Button("Экспорт структуры → JSON…") { model?.exportStructureJSON() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model?.structure == nil)
        }

        CommandMenu("Страница") {
            Button("Следующая страница") { model?.nextPage() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Предыдущая страница") { model?.previousPage() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Divider()
            Button("Найти…") { model?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("Словарь") {
            Button("Найти в словаре") { model?.performLookUp() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Копировать текст выделения") { _ = model?.copySelection() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!hasSelection)
        }

        CommandMenu("Перевод") {
            Button("Перевести выделение…") { model?.translateSelection() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!hasSelection || !translationAvailable)
            Button("Повторить перевод") { model?.translation.retry() }
                .disabled(!(model?.translation.canRetry ?? false) || !translationAvailable)
            Divider()
            Button("Настройки перевода…") { model?.presentSettings() ?? SettingsWindow.shared.show() }
                .keyboardShortcut(",", modifiers: [.command, .option])
        }

        CommandMenu("Озвучка") {
            Button((model?.speech.isSpeaking ?? false) ? "Остановить озвучку" : "Озвучить выделение") {
                guard let model else { return }
                if model.speech.isSpeaking {
                    model.stopSpeaking()
                } else {
                    model.speakSelection()
                }
            }
            .keyboardShortcut(.escape, modifiers: .option)
            .disabled(!hasSelection && !(model?.speech.isSpeaking ?? false))
            Divider()
            Button("Настройки озвучки…") { model?.presentSettings() ?? SettingsWindow.shared.show() }
        }
    }
}
