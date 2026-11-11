import SwiftUI

/// Sidebar системного ридера: переключатель вкладок + список.
struct SidebarView: View {
    let model: ReaderModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Раздел", selection: Binding(get: { model.sidebarMode },
                                               set: { model.sidebarMode = $0 })) {
                ForEach(SidebarMode.allCases) { mode in
                    Label(mode.titleRu, systemImage: mode.symbol)
                        .labelStyle(.titleOnly)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            Group {
                switch model.sidebarMode {
                case .structure: StructureSidebarView(model: model)
                case .thumbnails: ThumbnailsSidebarView(model: model)
                case .search: SearchSidebarView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .navigationSplitViewColumnWidth(min: 210, ideal: 268, max: 360)
    }
}
