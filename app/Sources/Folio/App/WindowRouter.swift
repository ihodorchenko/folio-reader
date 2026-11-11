import SwiftUI

/// Routing «open file» between windows.
///
/// Rules:
/// 1. If there is a window without a document (app just launched) — open in it.
/// 2. If there are no windows yet (the file arrived before the scene was created) — remember it and hand it to the first scene.
/// 3. Otherwise open a **new window** with this file: the other windows keep their books.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    private var openWindowAction: OpenWindowAction?
    private var pendingURL: URL?

    func register(_ action: OpenWindowAction) {
        openWindowAction = action
    }

    /// Request from outside: Finder «Open With → Folio», `open -a Folio file.pdf`.
    func openDocument(_ url: URL) {
        guard url.isFileURL else { return }
        let models = ReaderModel.registry.allObjects
        folioLog("router: request to open \(url.lastPathComponent); model windows=\(models.count)")
        WindowReport.event("router.openDocument \(url.lastPathComponent): models=\(models.count), windows=\(NSApp.windows.count)")

        // 1. Empty window (cold start) — use it so we don't pile up duplicates.
        if let blank = models.first(where: { $0.documentURL == nil && $0.window != nil }) {
            folioLog("router: opening in the empty window")
            WindowReport.event("router → empty window")
            blank.open(url: url)
            WindowHygiene.scheduleBlankWindowCleanup()
            return
        }
        // 2. No windows yet — the first scene will take the URL when it appears.
        if models.isEmpty {
            folioLog("router: no windows — remembered the file for the first scene")
            WindowReport.event("router → waiting for the first scene")
            pendingURL = url
            WindowHygiene.scheduleBlankWindowCleanup()
            return
        }
        // 3. There are windows with documents — open a new window.
        openNewWindow(with: url)
        // SwiftUI may create another empty window in response to the open event.
        WindowHygiene.scheduleBlankWindowCleanup()
    }

    func openNewWindow(with url: URL? = nil) {
        guard let openWindowAction else {
            pendingURL = url
            folioLog("router: no openWindow action — remembered the file")
            return
        }
        WindowReport.event("router → new window \(url?.lastPathComponent ?? "—")")
        if let url {
            openWindowAction(id: ReaderScene.windowGroupID, value: url)
        } else {
            openWindowAction(id: ReaderScene.windowGroupID)
        }
    }

    func takePendingURL() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }
}
