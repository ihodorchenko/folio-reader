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
    private func installEventMonitors() {
        let copyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard AppDelegate.isCommandKey(event, "c") else { return event }
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                return event // пусть системный Copy обработает поле ввода
            }
            guard let selection = ReaderModel.shared.selection, !selection.isEmpty else { return event }
            _ = ReaderModel.shared.copySelection()
            return nil
        }
        let dictionaryMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard AppDelegate.isCommandKey(event, "d") else { return event }
            ReaderModel.shared.performLookUp()
            return nil
        }
        eventMonitors = [copyMonitor, dictionaryMonitor]
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

// MARK: - Меню

struct AppCommands: Commands {
    let model: ReaderModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Открыть…") { model.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
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
    }
}
