import SwiftUI
import AppKit

/// Вкладка «Поиск»: debounce 250 мс, список попаданий, переходы «далее/назад».
struct SearchSidebarView: View {
    let model: ReaderModel

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Найти в документе", text: Binding(get: { model.searchQuery },
                                                          set: { model.searchQuery = $0 }))
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { model.scheduleSearch() }
                    .onChange(of: model.searchQuery) { _, _ in
                        model.scheduleSearch()
                    }
                if model.isSearching {
                    ProgressView().controlSize(.small)
                } else if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                        model.scheduleSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.black.opacity(0.12)))
            .padding(10)

            if model.searchHits.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.searchHits.enumerated()), id: \.offset) { index, hit in
                            hitRow(index: index, hit: hit)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                Divider()
                navigationBar
            }
        }
        .onAppear {
            if model.focusSearchRequest > 0 || model.searchQuery.isEmpty {
                fieldFocused = true
            }
        }
        .onChange(of: model.focusSearchRequest) { _, _ in
            fieldFocused = true
        }
    }

    private func hitRow(index: Int, hit: PcSearchHit) -> some View {
        let isActive = model.activeHitIndex == index
        return Button {
            folioLog("поиск: переход к попаданию \(index + 1) (стр. \(hit.page + 1))")
            model.goToHit(index)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Стр. \(hit.page + 1)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    Spacer()
                    if isActive {
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(hit.snippet.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var navigationBar: some View {
        HStack(spacing: 10) {
            Button {
                model.previousHit()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help("Предыдущее попадание")

            Text("\(model.activeHitIndex.map { $0 + 1 } ?? 0) из \(model.searchHits.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                model.nextHit()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Следующее попадание")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.searchQuery.isEmpty ? "text.magnifyingglass" : "questionmark.folder")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.searchQuery.isEmpty ? "Поиск по документу" : "Ничего не найдено")
                .font(.callout.weight(.medium))
            Text(model.searchQuery.isEmpty
                 ? "Введите слово или фразу.\nПоиск идёт по текстовому слою PDF."
                 : "Попробуйте изменить запрос.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
