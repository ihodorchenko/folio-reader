import SwiftUI

/// Дерево структуры документа: заголовки с уровнями и переход по клику.
struct StructureSidebarView: View {
    let model: ReaderModel

    var body: some View {
        Group {
            if model.headingRows.isEmpty {
                if model.isLoading || model.doc == nil {
                    ProgressView("Загрузка структуры…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState
                }
            } else {
                VStack(spacing: 0) {
                    List(selection: selectionBinding) {
                        ForEach(model.headingRows) { row in
                            rowView(row)
                                .tag(row.id)
                        }
                    }
                    .listStyle(.sidebar)
                    footer
                }
            }
        }
    }

    // MARK: - Строка дерева

    private func rowView(_ row: HeadingRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: rowSymbol(row))
                .font(.system(size: row.level == 1 ? 11 : 10, weight: .medium))
                .foregroundStyle(row.level == 1 ? Color.primary : Color.secondary)
                .frame(width: 14, alignment: .center)
            Text(row.title)
                .font(row.level == 1 ? .system(size: 13, weight: .semibold) : .system(size: 12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text("\(row.page + 1)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, CGFloat(min(row.level, 6) - 1) * 12)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func rowSymbol(_ row: HeadingRow) -> String {
        row.level == 1 ? "h.square" : "text.alignleft"
    }

    // MARK: - Binding выбора

    private var selectionBinding: Binding<String?> {
        Binding(get: { model.selectedHeadingID },
                set: { newValue in
                    model.selectedHeadingID = newValue
                    guard let id = newValue,
                          let row = model.headingRows.first(where: { $0.id == id }) else { return }
                    folioLog("sidebar: переход к заголовку «\(row.title)» (стр. \(row.page + 1))")
                    model.scrollTo(page: row.page, bbox: row.bbox)
                })
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: model.structure?.tagged == true ? "checkmark.seal" : "wand.and.stars")
            Text(model.structure?.tagged == true
                 ? "tagged PDF: уровни из /StructTreeRoot"
                 : "уровни по эвристике: размер и насыщенность")
            Spacer()
            Text("\(model.headingRows.count)")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Заголовки не найдены")
                .font(.callout.weight(.medium))
            Text("В документе нет заголовков или текстового слоя.\nПопробуйте вкладку «Страницы».")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
