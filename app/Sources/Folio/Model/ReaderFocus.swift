import SwiftUI

/// Menu key: which model belongs to the reader's active window.
struct ReaderFocusKey: FocusedValueKey {
    typealias Value = ReaderModel
}

extension FocusedValues {
    var readerModel: ReaderModel? {
        get { self[ReaderFocusKey.self] }
        set { self[ReaderFocusKey.self] = newValue }
    }
}

/// Lets the model know its window: needed for ⌘C/⌘D from the event monitors,
/// for saving the position when the window closes, and for reports.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class WindowProbeView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
