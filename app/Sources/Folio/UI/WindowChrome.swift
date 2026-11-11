import AppKit

/// Normalizes the system window chrome to the look the reader needs.
///
/// 1. SwiftUI adds its own sidebar-toggle button to the toolbar
///    (`com.apple.SwiftUI.navigationSplitView.toggleSidebar`). The
///    `.toolbar(removing: .sidebarToggle)` modifier does not take effect when a
///    custom toolbar is declared on `NavigationSplitView` (verified by dumping
///    `NSToolbar.items`), so the system button is removed at the AppKit level —
///    otherwise the toolbar has two sidebar buttons: ours and the system one.
@MainActor
enum WindowChrome {
    private static let systemSidebarToggleIdentifier = "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
    private static var observers: [NSObjectProtocol] = []
    private static var installed = false

    /// Subscribes to the events after which SwiftUI may rebuild the toolbar.
    static func install() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                            object: nil, queue: .main) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                if let window { suppress(in: window) }
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeMainNotification,
                                            object: nil, queue: .main) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                if let window { suppress(in: window) }
            }
        })
    }

    /// Removes the button now and once more on the next runloop tick: SwiftUI
    /// rebuilds the toolbar after the sidebar visibility changes.
    static func suppressSoon() {
        if let window = inKeyWindow() { suppress(in: window) }
        Task { @MainActor in
            if let window = inKeyWindow() { suppress(in: window) }
        }
    }

    static func suppress(in window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        var removed = 0
        while let index = toolbar.items.firstIndex(where: {
            $0.itemIdentifier.rawValue == systemSidebarToggleIdentifier
        }) {
            toolbar.removeItem(at: index)
            removed += 1
        }
        if removed > 0 {
            folioLog("toolbar: removed \(removed) system sidebar button(s)")
        }
    }

    private static func inKeyWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }
}
