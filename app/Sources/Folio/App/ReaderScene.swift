import SwiftUI
import AppKit

/// Одна сцена = одно окно = одна книга со своей моделью.
///
/// Раньше модель была синглтоном, поэтому открытие новой книги меняло документ
/// во всех окнах сразу. Теперь у каждого окна своя `ReaderModel`, а документ
/// приходит из значения `WindowGroup(for: URL.self)`.
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
                WindowReport.event("scene появилась: model=\(ObjectIdentifier(model)), value=\(documentURL?.lastPathComponent ?? "—"), окон=\(NSApp.windows.count)")
                if SnapshotRunner.isSnapshotMode {
                    model.configureForSnapshot()
                }
                WindowReport.startIfNeeded()
            }
    }
}
