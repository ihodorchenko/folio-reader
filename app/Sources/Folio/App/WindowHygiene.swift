import AppKit

/// Приведение количества окон к ожидаемому при запуске и открытии файлов.
///
/// SwiftUI создаёт окно на каждое open-событие (Finder → «Открыть с помощью»),
/// а macOS при перезапуске восстанавливает ранее открытые окна — вместе это давало
/// «две версии приложения» вместо одной. Правила:
///
/// 1. **Запуск**: после старта остаётся ровно одно окно (с документом, если файл
///    пришёл; иначе — пустое, в которое затем восстанавливается последняя книга).
/// 2. **Открытие файла в работающем приложении**: лишние *пустые* окна, появившиеся
///    как побочный эффект open-события, закрываются; окна с книгами не трогаем —
///    каждая книга живёт в своём окне.
@MainActor
enum WindowHygiene {
    private static var launchCleanupScheduled = false

    // MARK: - Запуск

    /// Оставить одно окно после старта приложения.
    static func scheduleLaunchCleanup() {
        guard !launchCleanupScheduled else { return }
        launchCleanupScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            collapseToSingleWindow(reason: "запуск")
        }
    }

    /// Закрыть все окна ридера, кроме одного — предпочтительно с документом.
    static func collapseToSingleWindow(reason: String) {
        let windows = readerWindows()
        guard windows.count > 1 else { return }

        let keep = windows.first { window in
            ReaderModel.model(for: window)?.documentURL != nil
        } ?? NSApp.keyWindow.flatMap { key in windows.first { $0 === key } } ?? windows[0]

        var closed = 0
        for window in windows where window !== keep {
            ReaderModel.model(for: window)?.persistReadingPosition()
            window.close()
            closed += 1
        }
        if closed > 0 {
            folioLog("windows: \(reason) — закрыл лишних окон: \(closed), оставил «\(keep.title)»")
        }
    }

    // MARK: - Открытие файлов

    /// Убрать пустые окна, созданные побочным эффектом open-события.
    /// Окна с документами не закрываются никогда: в них живут другие книги.
    static func scheduleBlankWindowCleanup() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            closeBlankWindows(keepingDocumentWindows: true)
        }
    }

    static func closeBlankWindows(keepingDocumentWindows: Bool) {
        let windows = readerWindows()
        let documentWindows = windows.filter { ReaderModel.model(for: $0)?.documentURL != nil }
        guard keepingDocumentWindows, !documentWindows.isEmpty else { return }

        var closed = 0
        for window in windows where ReaderModel.model(for: window)?.documentURL == nil {
            window.close()
            closed += 1
        }
        if closed > 0 {
            folioLog("windows: закрыл пустых окон после open-события: \(closed)")
        }
    }

    // MARK: - Внутреннее

    private static func readerWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible
                && !window.isMiniaturized
                && ReaderModel.model(for: window) != nil
        }
    }
}
