import SwiftUI
import AppKit

/// One scene = one window = one book with its own model.
///
/// The model used to be a singleton, so opening a new book changed the document
/// in every window at once. Now every window has its own `ReaderModel`, and the
/// document comes from the `WindowGroup(for: URL.self)` value.
struct ReaderScene: View {
    static let windowGroupID = "reader"

    let documentURL: URL?

    @State private var model = ReaderModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        RootView(model: model)
            .frame(minWidth: 900, minHeight: 600)
            .background(WindowAccessor { window in
                model.attach(window: window)
            })
            .focusedSceneValue(\.readerModel, model)
            .task {
                WindowRouter.shared.register(openWindow)
                model.start(documentURL: documentURL)
                AppDebugHooks.startIfNeeded(model: model)
            }
            .onChange(of: documentURL) { _, url in
                guard let url else { return }
                model.open(url: url)
            }
            .onChange(of: controlActiveState) { _, state in
                if state == .key {
                    model.activate()
                }
            }
            .onAppear {
                WindowReport.event("scene appeared: model=\(ObjectIdentifier(model)), value=\(documentURL?.lastPathComponent ?? "—"), windows=\(NSApp.windows.count)")
                if SnapshotRunner.isSnapshotMode {
                    model.configureForSnapshot()
                }
                WindowReport.startIfNeeded()
            }
    }
}
