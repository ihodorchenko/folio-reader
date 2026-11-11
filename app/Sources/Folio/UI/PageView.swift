import SwiftUI
import AppKit

/// Мост SwiftUI → AppKit для одной страницы документа.
/// NSView сам рисует растр и оверлей текста, SwiftUI только задаёт геометрию и состояние.
struct PageView: NSViewRepresentable {
    let model: ReaderModel
    let pageIndex: Int
    let pageSize: CGSize
    let zoom: Double
    let layout: PcPageLayout?
    let selection: Selection?
    let searchRects: [PcRect]
    let debugMode: DebugOverlayMode
    let renderScale: CGFloat
    let documentIdentity: String

    func makeNSView(context: Context) -> PageCanvasView {
        let view = PageCanvasView(pageIndex: pageIndex)
        view.model = model
        view.configure(pageSize: pageSize,
                       zoom: zoom,
                       layout: layout,
                       selection: selection,
                       searchRects: searchRects,
                       debugMode: debugMode,
                       renderScale: renderScale,
                       documentIdentity: documentIdentity)
        view.ensureImage()
        return view
    }

    func updateNSView(_ nsView: PageCanvasView, context: Context) {
        nsView.model = model
        nsView.configure(pageSize: pageSize,
                         zoom: zoom,
                         layout: layout,
                         selection: selection,
                         searchRects: searchRects,
                         debugMode: debugMode,
                         renderScale: renderScale,
                         documentIdentity: documentIdentity)
        nsView.ensureImage()
    }
}
