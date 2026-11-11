import AppKit

/// Window and lifecycle event log — for headless checks.
///
/// Enabled either by the `--window-report <path>` argument or (more reliably for
/// launching from Finder) by UserDefaults keys:
///
///     defaults write dev.folio.reader Folio.windowReport -bool YES
///     defaults write dev.folio.reader Folio.windowReportPath /tmp/folio-windows.txt
///
/// Writes a sequence of events (launch, open events, scene appearances,
/// document opens) and a snapshot of the window state once a second.
@MainActor
enum WindowReport {
    static var isEnabled: Bool {
        CommandLine.arguments.contains("--window-report")
            || UserDefaults.standard.bool(forKey: "Folio.windowReport")
    }

    private static var reportPath: String {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--window-report"), index + 1 < args.count {
            return args[index + 1]
        }
        return UserDefaults.standard.string(forKey: "Folio.windowReportPath")
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("folio-windows.txt")
    }

    private static var events: [String] = []
    private static var timer: Timer?

    // MARK: - Events

    static func event(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        events.append("[\(stamp)] \(message())")
        if events.count > 200 { events.removeFirst(events.count - 200) }
        write(reason: "event")
    }

    static func startIfNeeded() {
        guard isEnabled else { return }
        event("report enabled")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                write(reason: "tick")
            }
        }
    }

    private static func pageViews(in window: NSWindow) -> [PageCanvasView] {
        guard let root = window.contentView else { return [] }
        var result: [PageCanvasView] = []
        func walk(_ view: NSView) {
            if let pageView = view as? PageCanvasView { result.append(pageView) }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return result
    }

    // MARK: - State snapshot

    static func write(reason: String) {
        guard isEnabled else { return }
        var lines: [String] = []
        lines.append("report: \(reason)")
        lines.append("args: \(CommandLine.arguments.joined(separator: " "))")
        let windows = NSApp.windows
        lines.append("nsapp.windows: \(windows.count)")
        for (index, window) in windows.enumerated() {
            let visible = window.isVisible ? "visible" : "hidden"
            let key = window.isKeyWindow ? "key" : "-"
            lines.append("  [\(index)] class=\(type(of: window)) title=«\(window.title)» \(visible) \(key) frame=\(window.frame) sheet=\(window.attachedSheet != nil)")
        }
        for (index, window) in windows.enumerated() where window.isVisible {
            let pages = pageViews(in: window)
            if !pages.isEmpty {
                lines.append("  window[\(index)] pages: \(pages.map(\.debugSummary).joined(separator: " ; "))")
            }
        }
        let models = ReaderModel.registry.allObjects
        lines.append("reader models: \(models.count)")
        for model in models {
            lines.append("  model \(ObjectIdentifier(model)) doc=\(model.documentURL?.lastPathComponent ?? "—") page=\(model.currentPage + 1) pages=\(model.pageCount) hasDoc=\(model.doc != nil) structure=\(model.structure != nil) zoom=\(String(format: "%.2f", model.zoom)) renderScale=\(String(format: "%.2f", model.renderScale)) window=«\(model.window?.title ?? "—")» key=\(model.window?.isKeyWindow == true)")
        }
        lines.append("renderErrors: \(RenderStore.shared.errorCount) last=\(RenderStore.shared.lastError)")
        if let recentMenu = RecentDocumentsMenu.submenu() {
            let titles = recentMenu.items.filter { !$0.isSeparatorItem }.map { $0.title }
            lines.append("recentMenu (\(titles.count)): \(titles.joined(separator: " | "))")
        } else {
            lines.append("recentMenu: none")
        }
        if !events.isEmpty {
            lines.append("events:")
            lines.append(contentsOf: events.map { "  \($0)" })
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(toFile: reportPath, atomically: true, encoding: .utf8)
    }
}
