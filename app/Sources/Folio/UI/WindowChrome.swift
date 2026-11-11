import AppKit

/// Приведение системного хрома окна к виду, который нужен ридеру.
///
/// 1. SwiftUI сам добавляет в тулбар кнопку боковой панели
///    (`com.apple.SwiftUI.navigationSplitView.toggleSidebar`). Модификатор
///    `.toolbar(removing: .sidebarToggle)` при объявленном своём toolbar на
///    `NavigationSplitView` не срабатывает (проверено дампом `NSToolbar.items`),
///    поэтому системную кнопку убираем на уровне AppKit — иначе в тулбаре две
///    кнопки панели: наша и системная.
@MainActor
enum WindowChrome {
    private static let systemSidebarToggleIdentifier = "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
    private static var observers: [NSObjectProtocol] = []
    private static var installed = false

    /// Подписка на события, после которых SwiftUI может пересобрать тулбар.
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

    /// Убирает кнопку сейчас и ещё раз на следующем тике runloop: SwiftUI
    /// пересобирает тулбар после смены видимости панели.
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
            folioLog("toolbar: убрал системную кнопку боковой панели (\(removed) шт.)")
        }
    }

    private static func inKeyWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }
}
