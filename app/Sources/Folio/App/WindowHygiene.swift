import AppKit

/// Brings the number of windows in line with expectations at launch and on file open.
///
/// SwiftUI creates a window for every open event (Finder → «Open With»), and on
/// restart macOS restores previously open windows — together that produced
/// «two copies of the app» instead of one. Rules:
///
/// 1. **Launch**: exactly one window remains after startup (with the document if
///    a file arrived; otherwise an empty one, into which the last book is then restored).
/// 2. **Opening a file in a running app**: extra *empty* windows created as a side
///    effect of the open event are closed; windows with books are left alone —
///    every book lives in its own window.
@MainActor
enum WindowHygiene {
    private static var launchCleanupScheduled = false

    // MARK: - Launch

    /// Leave a single window after the app starts.
    static func scheduleLaunchCleanup() {
        guard !launchCleanupScheduled else { return }
        launchCleanupScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            collapseToSingleWindow(reason: "launch")
        }
    }

    /// Close every reader window except one — preferably the one with a document.
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
            folioLog("windows: \(reason) — closed extra windows: \(closed), kept «\(keep.title)»")
        }
    }

    // MARK: - Opening files

    /// Remove empty windows created as a side effect of the open event.
    /// Windows with documents are never closed: other books live in them.
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
            folioLog("windows: closed \(closed) empty windows after the open event")
        }
    }

    // MARK: - Internals

    private static func readerWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible
                && !window.isMiniaturized
                && ReaderModel.model(for: window) != nil
        }
    }
}
