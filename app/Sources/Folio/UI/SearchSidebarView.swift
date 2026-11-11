import SwiftUI
import AppKit

/// "Search" tab: 250 ms debounce, hit list, next/previous navigation.
struct SearchSidebarView: View {
    let model: ReaderModel

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L10n.t("Find in Document"), text: Binding(get: { model.searchQuery },
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
            folioLog("search: jump to hit \(index + 1) (p. \(hit.page + 1))")
            model.goToHit(index)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L10n.t("Page %ld", hit.page + 1))
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
            .help(L10n.t("Previous Match"))

            Text(L10n.t("%ld of %ld", model.activeHitIndex.map { $0 + 1 } ?? 0, model.searchHits.count))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                model.nextHit()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Next Match"))

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
            Text(model.searchQuery.isEmpty ? L10n.t("Search the Document") : L10n.t("Nothing Found"))
                .font(.callout.weight(.medium))
            Text(model.searchQuery.isEmpty
                 ? L10n.t("Enter a word or phrase.\nSearch runs over the PDF text layer.")
                 : L10n.t("Try changing the query."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
