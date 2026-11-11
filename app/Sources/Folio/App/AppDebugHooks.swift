import AppKit

/// Отладочные хуки для headless-проверок окон и восстановления позиции чтения.
/// Без соответствующих аргументов ничего не делают.
///
///     Folio --goto-page 5 --quit-after 4   # открыть док., перейти на страницу, сохранить, выйти
///     Folio --window-report /tmp/r.txt     # отчёт об окнах и моделях (см. WindowReport)
@MainActor
enum AppDebugHooks {
    private static var applied = false

    /// Значение флага: аргумент командной строки, иначе — ключ UserDefaults
    /// (нужен для проверок через Finder/`open`, где `--args` до приложения не доходят).
    static func value(for flag: String, defaultsKey: String? = nil) -> String? {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: flag), index + 1 < args.count {
            return args[index + 1]
        }
        if let defaultsKey {
            return UserDefaults.standard.string(forKey: defaultsKey)
        }
        return nil
    }

    /// Применяется один раз — только в первом окне процесса.
    static func startIfNeeded(model: ReaderModel) {
        guard !applied else { return }
        applied = true

        if let pageArgument = value(for: "--goto-page", defaultsKey: "Folio.debugGotoPage"),
           let page = Int(pageArgument) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                let target = ReaderModel.active ?? model
                let index = max(0, page - 1)
                if let zoomValue = value(for: "--zoom", defaultsKey: "Folio.debugZoom").flatMap(Double.init) {
                    target.setZoom(zoomValue / 100.0)
                    folioLog("debug: зум \(zoomValue)%")
                }
                target.goToPage(index)
                target.updateVisiblePage(index, progress: 0.25)
                target.persistReadingPosition()
                folioLog("debug: открыта страница \(page) в окне «\(target.window?.title ?? "—")», позиция сохранена")
            }
        }

        // Проверка меню «Открыть недавние» без мыши: нажимаем пункт программно.
        if let title = value(for: "--open-recent", defaultsKey: "Folio.debugOpenRecent") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let menu = RecentDocumentsMenu.submenu(),
                      let item = menu.items.first(where: { $0.title == title }),
                      let action = item.action else {
                    folioLog("debug: в недавних нет пункта «\(title)»")
                    return
                }
                folioLog("debug: нажимаю пункт «\(title)» в «Открыть недавние»")
                NSApp.sendAction(action, to: item.target, from: item)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                folioLog("debug: после выбора в модели \(ReaderModel.active?.documentURL?.lastPathComponent ?? "—")")
                WindowReport.write(reason: "после выбора недавнего")
            }
        }

        // Сценарий «открыть другой документ, затем вернуться к первому»:
        // Folio.debugOpenSequence = "3:/path/b.pdf;7:/path/a.pdf"
        if let sequence = value(for: "--open-sequence", defaultsKey: "Folio.debugOpenSequence") {
            for part in sequence.split(separator: ";") {
                let pieces = part.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2, let delay = Double(pieces[0]) else { continue }
                let path = String(pieces[1])
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.1) * 1_000_000_000))
                    let target = ReaderModel.active ?? model
                    folioLog("debug: последовательность — открываю \(path) в окне «\(target.window?.title ?? "—")»")
                    target.open(url: URL(fileURLWithPath: path))
                }
            }
        }

        if let closeAfter = value(for: "--close-window", defaultsKey: "Folio.debugCloseWindow").flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(closeAfter, 0.2) * 1_000_000_000))
                if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                    folioLog("debug: закрываю окно «\(window.title)»")
                    window.close()
                }
            }
        }

        if let quitAfter = value(for: "--quit-after", defaultsKey: "Folio.debugQuitAfter").flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(quitAfter, 0.2) * 1_000_000_000))
                folioLog("debug: завершение по --quit-after \(quitAfter)")
                NSApp.terminate(nil)
            }
        }
    }
}
