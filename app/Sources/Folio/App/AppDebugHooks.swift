import AppKit

/// Debug hooks for headless checks of windows and reading-position restore.
/// They do nothing without the corresponding arguments.
///
///     Folio --goto-page 5 --quit-after 4   # open a doc, go to a page, save, quit
///     Folio --window-report /tmp/r.txt     # report on windows and models (see WindowReport)
@MainActor
enum AppDebugHooks {
    private static var applied = false

    /// Flag value: the command-line argument, otherwise the UserDefaults key
    /// (needed for checks through Finder/`open`, where `--args` never reach the app).
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

    /// Applied once — only in the first window of the process.
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
                    folioLog("debug: zoom \(zoomValue)%")
                }
                target.goToPage(index)
                target.updateVisiblePage(index, progress: 0.25)
                target.persistReadingPosition()
                folioLog("debug: opened page \(page) in window «\(target.window?.title ?? "—")», position saved")
            }
        }

        // Check the «Open Recent» menu without a mouse: press the item programmatically.
        if let title = value(for: "--open-recent", defaultsKey: "Folio.debugOpenRecent") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let menu = RecentDocumentsMenu.submenu(),
                      let item = menu.items.first(where: { $0.title == title }),
                      let action = item.action else {
                    folioLog("debug: no item «\(title)» among recent documents")
                    return
                }
                folioLog("debug: pressing item «\(title)» in «Open Recent»")
                NSApp.sendAction(action, to: item.target, from: item)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                folioLog("debug: after selection the model holds \(ReaderModel.active?.documentURL?.lastPathComponent ?? "—")")
                WindowReport.write(reason: "after selecting a recent document")
            }
        }

        // Scenario «open another document, then return to the first one»:
        // Folio.debugOpenSequence = "3:/path/b.pdf;7:/path/a.pdf"
        if let sequence = value(for: "--open-sequence", defaultsKey: "Folio.debugOpenSequence") {
            for part in sequence.split(separator: ";") {
                let pieces = part.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2, let delay = Double(pieces[0]) else { continue }
                let path = String(pieces[1])
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.1) * 1_000_000_000))
                    let target = ReaderModel.active ?? model
                    folioLog("debug: sequence — opening \(path) in window «\(target.window?.title ?? "—")»")
                    target.open(url: URL(fileURLWithPath: path))
                }
            }
        }

        if let closeAfter = value(for: "--close-window", defaultsKey: "Folio.debugCloseWindow").flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(closeAfter, 0.2) * 1_000_000_000))
                if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                    folioLog("debug: closing window «\(window.title)»")
                    window.close()
                }
            }
        }

        if let quitAfter = value(for: "--quit-after", defaultsKey: "Folio.debugQuitAfter").flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(quitAfter, 0.2) * 1_000_000_000))
                folioLog("debug: quitting on --quit-after \(quitAfter)")
                NSApp.terminate(nil)
            }
        }
    }
}
