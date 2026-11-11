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
                let index = max(0, page - 1)
                model.goToPage(index)
                model.updateVisiblePage(index, progress: 0.25)
                model.persistReadingPosition()
                folioLog("debug: открыта страница \(page), позиция чтения сохранена")
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

        if let quitAfter = value(for: "--quit-after", defaultsKey: "Folio.debugQuitAfter").flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(quitAfter, 0.2) * 1_000_000_000))
                folioLog("debug: завершение по --quit-after \(quitAfter)")
                NSApp.terminate(nil)
            }
        }
    }
}
