import SwiftUI

/// Маршрутизация «открыть файл» между окнами.
///
/// Правила:
/// 1. Если есть окно без документа (только что запущенное приложение) — открываем в нём.
/// 2. Если окон ещё нет (файл пришёл до создания сцены) — запоминаем и отдаём первой сцене.
/// 3. Иначе открываем **новое окно** с этим файлом: другие окна сохраняют свои книги.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    private var openWindowAction: OpenWindowAction?
    private var pendingURL: URL?

    func register(_ action: OpenWindowAction) {
        openWindowAction = action
    }

    /// Запрос извне: Finder «Открыть с помощью → Folio», `open -a Folio file.pdf`.
    func openDocument(_ url: URL) {
        guard url.isFileURL else { return }
        let models = ReaderModel.registry.allObjects
        folioLog("router: запрос открыть \(url.lastPathComponent); окон моделей=\(models.count)")
        WindowReport.event("router.openDocument \(url.lastPathComponent): моделей=\(models.count), окон=\(NSApp.windows.count)")

        // 1. Пустое окно (холодный старт) — используем его, чтобы не плодить дубли.
        if let blank = models.first(where: { $0.documentURL == nil && $0.window != nil }) {
            folioLog("router: открываю в пустом окне")
            WindowReport.event("router → пустое окно")
            blank.open(url: url)
            WindowHygiene.scheduleBlankWindowCleanup()
            return
        }
        // 2. Окон ещё нет — первая сцена заберёт URL при появлении.
        if models.isEmpty {
            folioLog("router: окон нет — запомнил файл для первой сцены")
            WindowReport.event("router → ждём первую сцену")
            pendingURL = url
            WindowHygiene.scheduleBlankWindowCleanup()
            return
        }
        // 3. Есть окна с документами — открываем новое окно.
        openNewWindow(with: url)
        // SwiftUI может создать ещё одно пустое окно в ответ на open-событие.
        WindowHygiene.scheduleBlankWindowCleanup()
    }

    func openNewWindow(with url: URL? = nil) {
        guard let openWindowAction else {
            pendingURL = url
            folioLog("router: нет действия openWindow — запомнил файл")
            return
        }
        WindowReport.event("router → новое окно \(url?.lastPathComponent ?? "—")")
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
