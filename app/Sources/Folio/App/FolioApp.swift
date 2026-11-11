import SwiftUI
import AppKit

// MARK: - Точка входа

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // В снапшот-режиме документ открывает SnapshotRunner, а не bootstrap
        // из `.task` (иначе документ грузится дважды).
        if SnapshotRunner.isSnapshotMode {
            ReaderModel.shared.configureForSnapshot()
        }
    }

    var body: some Scene {
        WindowGroup("Folio") {
            RootView(model: ReaderModel.shared)
                .frame(minWidth: 900, minHeight: 600)
                .task { ReaderModel.shared.bootstrapIfNeeded() }
        }
        .defaultSize(width: 1280, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(model: ReaderModel.shared) }
    }
}

// MARK: - Делегат приложения

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var eventMonitors: [Any?] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(SnapshotRunner.isSnapshotMode ? .accessory : .regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Двойной клик по PDF в Finder / «Открыть с помощью → Folio».
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !SnapshotRunner.isSnapshotMode else { return }
        let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) ?? urls.first
        guard let pdf else { return }
        MainActor.assumeIsolated {
            folioLog("launchservices: открываем \(pdf.path)")
            ReaderModel.shared.openFromFinder(pdf)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
        guard let selection = ReaderModel.shared.selection, !selection.isEmpty else { return false }
        _ = ReaderModel.shared.copySelection()
        return true
    }

    /// ⌘D: словарь по выделению / под курсором.
    @MainActor
    private static func handleDictionaryKey(_ event: NSEvent) -> Bool {
        guard isCommandKey(event, "d") else { return false }
        ReaderModel.shared.performLookUp()
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

struct AppCommands: Commands {
    let model: ReaderModel

    /// Системный перевод появился в macOS 15 — до этого пункты отключаем.
    private var translationAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private var hasSelection: Bool {
        !(model.selection?.isEmpty ?? true)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Открыть…") { model.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Настройки…") { model.presentSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Вид") {
            Button("Увеличить") { model.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Уменьшить") { model.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Фактический размер (100%)") { model.actualSize() }
                .keyboardShortcut("1", modifiers: .command)
            Button("По размеру ширины") { model.toggleFitWidth() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button(model.debugMode == .blocks ? "Скрыть разметку блоков" : "Разметка блоков") {
                model.setDebugMode(model.debugMode == .blocks ? .off : .blocks)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Button(model.debugMode == .words ? "Скрыть рамки слов" : "Рамки слов") {
                model.setDebugMode(model.debugMode == .words ? .off : .words)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            Button("Экспорт структуры → JSON…") { model.exportStructureJSON() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.structure == nil)
        }

        CommandMenu("Страница") {
            Button("Следующая страница") { model.nextPage() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Предыдущая страница") { model.previousPage() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Divider()
            Button("Найти…") { model.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("Словарь") {
            Button("Найти в словаре") { model.performLookUp() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Копировать текст выделения") { _ = model.copySelection() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.selection?.isEmpty ?? true)
        }

        CommandMenu("Перевод") {
            Button("Перевести выделение…") { model.translateSelection() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!hasSelection || !translationAvailable)
            Button("Повторить перевод") { model.translation.retry() }
                .disabled(!model.translation.canRetry || !translationAvailable)
            Divider()
            Button("Настройки перевода…") { model.presentSettings() }
                .keyboardShortcut(",", modifiers: [.command, .option])
        }

        CommandMenu("Озвучка") {
            Button(model.speech.isSpeaking ? "Остановить озвучку" : "Озвучить выделение") {
                if model.speech.isSpeaking {
                    model.stopSpeaking()
                } else {
                    model.speakSelection()
                }
            }
            .keyboardShortcut(.escape, modifiers: .option)
            .disabled(!hasSelection && !model.speech.isSpeaking)
            Divider()
            Button("Настройки озвучки…") { model.presentSettings() }
        }
    }
}
