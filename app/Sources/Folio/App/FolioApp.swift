import SwiftUI
import AppKit

// MARK: - Entry point

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Window = book. The `URL?` value comes from Finder/`open` when a file is
        // opened, so every window has its own `ReaderModel` and its own document.
        WindowGroup("Folio", id: ReaderScene.windowGroupID, for: URL.self) { $documentURL in
            ReaderScene(documentURL: documentURL)
        }
        .defaultSize(width: 1280, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands() }
    }
}

// MARK: - Application delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var eventMonitors: [Any?] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The app restores its own reading positions; AppKit window restoration is
        // disabled. Without this, a stale SwiftUI window-restoration record (for the
        // same bundle id) can suppress the first window in Xcode-built binaries.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        WindowReport.event("willFinishLaunching")
        NSApp.setActivationPolicy(SnapshotRunner.isSnapshotMode ? .accessory : .regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowReport.event("didFinishLaunching, windows=\(NSApp.windows.count)")
        installSelectionBarMenuObservers()
        if SnapshotRunner.isSnapshotMode {
            // IMPORTANT: start via Timer, not DispatchQueue.main.async.
            // Inside a main-queue block a nested RunLoop cannot wake
            // Swift Concurrency (the main queue is busy), and the model never loads.
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

    /// We restore windows ourselves: the last book plus the reading position. System
    /// window restoration is disabled — it was what raised extra windows at launch.
    func applicationShouldSaveApplicationState(_ application: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ application: NSApplication) -> Bool { false }

    /// Double-click a PDF in Finder / «Open With → Folio».
    /// Every file opens in its own window; already open books are not changed.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !SnapshotRunner.isSnapshotMode else { return }
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        WindowReport.event("open event: \(urls.map(\.lastPathComponent)), windows=\(NSApp.windows.count)")
        for url in (pdfs.isEmpty ? urls : pdfs) {
            folioLog("launchservices: opening \(url.path)")
            WindowRouter.shared.openDocument(url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowReport.event("shouldHandleReopen hasVisibleWindows=\(flag) windows=\(NSApp.windows.count)")
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        // SwiftUI may rebuild the main menu — put our delegate back.
        RecentDocumentsMenu.shared.refresh()
    }

    /// Persist the reading position in every window before quitting.
    func applicationWillTerminate(_ notification: Notification) {
        guard !SnapshotRunner.isSnapshotMode else { return }
        for model in ReaderModel.registry.allObjects {
            model.persistReadingPosition()
        }
    }

    /// The floating selection bar must not fight with menus: hide it while any menu
    /// (menu bar or context menu) is tracking and bring it back when the menu closes.
    private func installSelectionBarMenuObservers() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for model in ReaderModel.registry.allObjects {
                    model.suppressSelectionBarForMenu()
                }
            }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for model in ReaderModel.registry.allObjects {
                    model.restoreSelectionBarAfterMenu()
                }
            }
        }
    }

    /// ⌘C / ⌘D over the page: the page is not an NSTextView, so we handle them ourselves.
    ///
    /// Local event monitors run on the main thread, but their closures are not
    /// MainActor-isolated. We pass the event through an `@unchecked Sendable` wrapper
    /// (the event only lives inside the main-thread call) and return a plain `Bool` —
    /// «event handled» — so NSEvent never crosses the isolation boundary.
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

    /// ⌘C: the page is not an NSTextView, so we copy the selection ourselves.
    /// Returns `true` when the event is handled and the system Copy is not needed.
    @MainActor
    private static func handleCopyKey(_ event: NSEvent) -> Bool {
        guard isCommandKey(event, "c") else { return false }
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
            return false // let the system Copy handle the text field
        }
        guard let model = ReaderModel.active,
              let selection = model.selection, !selection.isEmpty else { return false }
        _ = model.copySelection()
        return true
    }

    /// ⌘D: dictionary for the selection / under the cursor in the active window.
    @MainActor
    private static func handleDictionaryKey(_ event: NSEvent) -> Bool {
        guard isCommandKey(event, "d") else { return false }
        // Holding ⌘D must not open the dictionary again.
        guard !event.isARepeat else { return true }
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

/// Wrapper for passing `NSEvent` across the isolation boundary to the main actor.
/// Safe: the event never leaves the main thread and is used only inside the call.
private struct MainThreadEvent: @unchecked Sendable {
    let event: NSEvent
    init(_ event: NSEvent) { self.event = event }
}

// MARK: - Menu

/// Commands operate on the active window's model: every window has its own book.
struct AppCommands: Commands {
    @FocusedValue(\.readerModel) private var focusedModel: ReaderModel?

    /// The model of the focused scene; before focus appears, the active window's model.
    private var model: ReaderModel? { focusedModel ?? ReaderModel.active }

    /// The system translation framework appeared in macOS 15 — disable the items before that.
    private var translationAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private var hasSelection: Bool {
        !(model?.selection?.isEmpty ?? true)
    }

    /// Recent documents: the submenu is always built from the current list.
    private var recents: RecentDocumentsStore { RecentDocumentsStore.shared }

    /// A recent document opens in the current window (like «Open…»);
    /// if there is no window yet, the router creates the first one.
    private func openRecent(_ url: URL) {
        if let model {
            model.open(url: url)
        } else {
            WindowRouter.shared.openDocument(url)
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.t("New Window")) { WindowRouter.shared.openNewWindow() }
                .keyboardShortcut("n", modifiers: .command)
            Button(L10n.t("Open…")) { model?.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Menu(L10n.t("Open Recent")) {
                if recents.documents.isEmpty {
                    Text(L10n.t("No Recent Documents"))
                } else {
                    ForEach(recents.documents) { document in
                        Button(document.title) { openRecent(document.url) }
                    }
                    Divider()
                    Button(L10n.t("Clear Menu")) { recents.clear() }
                }
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button(L10n.t("Settings…")) { model?.presentSettings() ?? SettingsWindow.shared.show() }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu(L10n.t("View")) {
            Button(L10n.t("Zoom In")) { model?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button(L10n.t("Zoom Out")) { model?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button(L10n.t("Actual Size (100%)")) { model?.actualSize() }
                .keyboardShortcut("1", modifiers: .command)
            Button(L10n.t("Fit Width")) { model?.toggleFitWidth() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button(model?.debugMode == .blocks ? L10n.t("Hide Element Layout") : L10n.t("Element Layout")) {
                guard let model else { return }
                model.setDebugMode(model.debugMode == .blocks ? .off : .blocks)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Button(model?.debugMode == .words ? L10n.t("Hide Word Boxes") : L10n.t("Word Boxes")) {
                guard let model else { return }
                model.setDebugMode(model.debugMode == .words ? .off : .words)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            Button(L10n.t("Export Structure → JSON…")) { model?.exportStructureJSON() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model?.structure == nil)
        }

        CommandMenu(L10n.t("Page")) {
            Button(L10n.t("Next Page")) { model?.nextPage() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button(L10n.t("Previous Page")) { model?.previousPage() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Divider()
            Button(L10n.t("Find…")) { model?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu(L10n.t("Dictionary")) {
            Button(L10n.t("Look Up in Dictionary")) { model?.performLookUp() }
                .keyboardShortcut("d", modifiers: .command)
            Button(L10n.t("Copy Selection Text")) { _ = model?.copySelection() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!hasSelection)
        }

        CommandMenu(L10n.t("Translation")) {
            Button(L10n.t("Translate Selection…")) { model?.translateSelection() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!hasSelection || !translationAvailable)
            Button(L10n.t("Translate Again")) { model?.translation.retry() }
                .disabled(!(model?.translation.canRetry ?? false) || !translationAvailable)
            Divider()
            Button(L10n.t("Translation Settings…")) { model?.presentSettings() ?? SettingsWindow.shared.show() }
                .keyboardShortcut(",", modifiers: [.command, .option])
        }

        CommandMenu(L10n.t("Speech")) {
            Button((model?.speech.isSpeaking ?? false) ? L10n.t("Stop Speaking") : L10n.t("Speak Selection")) {
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
            Button(L10n.t("Speech Settings…")) { model?.presentSettings() ?? SettingsWindow.shared.show() }
        }
    }
}
