import AppKit

/// Наполняет подменю «Файл → Открыть недавние» из `RecentDocumentsStore`.
///
/// Почему не только SwiftUI: объявленное в `Commands` подменю строится один раз
/// при запуске и не перестраивается при изменении списка, поэтому меню ведёт
/// `NSMenuDelegate` — он заново собирает пункты при каждом открытии меню и по
/// уведомлению об изменении списка (чтобы список был актуален сразу).
@MainActor
final class RecentDocumentsMenu: NSObject, NSMenuDelegate {
    static let shared = RecentDocumentsMenu()

    private var installTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?

    // MARK: - Установка

    /// Подписаться на изменения и найти подменю (SwiftUI строит меню после старта).
    func install() {
        if changeObserver == nil {
            changeObserver = NotificationCenter.default.addObserver(
                forName: .recentDocumentsChanged, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    RecentDocumentsMenu.shared.refresh()
                }
            }
        }
        installTask?.cancel()
        installTask = Task { @MainActor in
            for _ in 0..<20 {
                if attach() { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            folioLog("recent: подменю «Открыть недавние» не найдено в главном меню")
        }
    }

    @discardableResult
    func attach() -> Bool {
        guard let submenu = Self.submenu() else { return false }
        if submenu.delegate !== self {
            submenu.delegate = self
        }
        rebuild(submenu)
        return true
    }

    /// Перестроить пункты немедленно (по изменению списка).
    func refresh() {
        if let submenu = Self.submenu() {
            if submenu.delegate !== self { submenu.delegate = self }
            rebuild(submenu)
        } else {
            attach()
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    // MARK: - Содержимое меню

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let documents = RecentDocumentsStore.shared.documents

        guard !documents.isEmpty else {
            let empty = NSMenuItem(title: "Нет недавних документов", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for document in documents {
            let item = NSMenuItem(title: document.title,
                                  action: #selector(openRecent(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = document.url
            item.toolTip = document.url.path
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Очистить меню", action: #selector(clearRecents(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    // MARK: - Действия

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        folioLog("recent: открываю \(url.path)")
        // Как «Открыть…»: в текущем окне; если окна нет — маршрутизатор создаст первое.
        if let model = ReaderModel.active {
            model.open(url: url)
        } else {
            WindowRouter.shared.openDocument(url)
        }
    }

    @objc private func clearRecents(_ sender: NSMenuItem) {
        RecentDocumentsStore.shared.clear()
    }

    // MARK: - Поиск подменю

    static func submenu() -> NSMenu? {
        findMenu(titled: "Открыть недавние", in: NSApp.mainMenu)
    }

    /// Рекурсивный поиск подменю по заголовку пункта.
    static func findMenu(titled title: String, in menu: NSMenu?) -> NSMenu? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.title == title, let submenu = item.submenu { return submenu }
            if let submenu = item.submenu, let found = findMenu(titled: title, in: submenu) {
                return found
            }
        }
        return nil
    }
}
