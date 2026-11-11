import SwiftUI
import AppKit

/// Корневое окно ридера: sidebar + страницы в стиле системного приложения.
struct RootView: View {
    let model: ReaderModel

    @Environment(\.displayScale) private var displayScale
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { model.columnVisibility },
                                                     set: { model.columnVisibility = $0 })) {
            SidebarView(model: model)
        } detail: {
            VStack(spacing: 0) {
                if model.isMock {
                    MockCoreBanner()
                }
                DetailView(model: model)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .navigationTitle(model.documentTitle)
        .navigationSubtitle(model.statusText)
        .toolbar { toolbarContent }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay(alignment: .top) {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { model.backingScale = displayScale }
        .onChange(of: displayScale) { _, scale in model.backingScale = scale }
        .alert("Не удалось открыть документ",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("Закрыть", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // Хост системного перевода живёт всё время работы окна: сессию выдаёт SwiftUI,
        // а запросы приходят из AppKit-меню (контекстное меню страницы).
        .background(TranslationTaskHost(controller: model.translation))
        .sheet(isPresented: Binding(get: { model.translation.isPanelPresented },
                                    set: { model.translation.isPanelPresented = $0 })) {
            TranslationPanel(model: model)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Когда панель свёрнута, SwiftUI сам показывает кнопку возврата в titlebar —
        // нашу не дублируем.
        if model.columnVisibility != .detailOnly {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Скрыть боковую панель (⧉)")
            }
        }

        ToolbarItem(placement: .principal) {
            titleView
        }

        ToolbarItemGroup(placement: .primaryAction) {
            PageIndicatorField(model: model)
            zoomMenu
            debugButton
            searchButton
            moreMenu
        }
    }

    private var titleView: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.documentTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(model.statusText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if model.isMock {
                Text("ДЕМО")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.yellow.opacity(0.35), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 460)
        .help("\(model.documentTitle) — \(model.statusText)")
    }

    private var zoomMenu: some View {
        Menu {
            Button("Увеличить") { model.zoomIn() }
            Button("Уменьшить") { model.zoomOut() }
            Divider()
            Button("По размеру ширины") { model.applyFitWidth() }
            Button("100%") { model.actualSize() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus.magnifyingglass")
                Text("\(Int((model.zoom * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Масштаб: пинч, ⌘+ / ⌘−, ⌘0 — по ширине, ⌘1 — 100%")
    }

    private var debugButton: some View {
        Button {
            model.toggleDebugOverlay()
        } label: {
            Image(systemName: "rectangle.dashed")
                .symbolVariant(model.showDebugOverlay ? .fill : .none)
        }
        .foregroundStyle(model.showDebugOverlay ? Color.accentColor : Color.primary)
        .help("Показать разметку блоков: тип, уровень заголовка, уверенность")
    }

    private var searchButton: some View {
        Button {
            model.focusSearch()
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .help("Поиск по документу (⌘F)")
    }

    private var moreMenu: some View {
        Menu {
            Button("Открыть…") { model.presentOpenPanel() }
            Divider()
            Button(model.translation.canRetry ? "Перевести выделение (повторить)" : "Перевести выделение") {
                if model.translation.canRetry {
                    model.translation.retry()
                } else {
                    model.translateSelection()
                }
            }
            .disabled((model.selection?.isEmpty ?? true) && !model.translation.canRetry)
            Button(model.speech.isSpeaking ? "Остановить озвучку" : "Озвучить выделение") {
                model.speech.isSpeaking ? model.stopSpeaking() : model.speakSelection()
            }
            .disabled(!model.settings.speechEnabled)
            Divider()
            Button("Экспорт структуры → JSON…") { model.exportStructureJSON() }
                .disabled(model.structure == nil)
            Divider()
            Toggle("Разметка блоков", isOn: Binding(get: { model.debugMode == .blocks },
                                                   set: { model.setDebugMode($0 ? .blocks : .off) }))
            Toggle("Рамки слов", isOn: Binding(get: { model.debugMode == .words },
                                               set: { model.setDebugMode($0 ? .words : .off) }))
            Divider()
            Button("Фактический размер (100%)") { model.actualSize() }
            Button("По размеру ширины") { model.applyFitWidth() }
            Divider()
            Button("Настройки…") { model.presentSettings() }
                .keyboardShortcut(",", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Дополнительно")
    }

    // MARK: - Действия

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.22)) {
            model.columnVisibility = (model.columnVisibility == .detailOnly) ? .all : .detailOnly
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier("com.adobe.pdf") })
                ?? providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                folioLog("drop: открываю \(url.path)")
                model.open(url: url)
            }
        }
        return true
    }
}

// MARK: - Поле «страница / всего»

private struct PageIndicatorField: View {
    let model: ReaderModel

    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 3) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 34)
                .focused($editing)
                .onSubmit { commit() }
            Text("/ \(model.pageCount)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.10)))
        .help("Номер страницы — введите число и нажмите Return")
        .onAppear { syncText() }
        .onChange(of: model.currentPage) { _, _ in syncText() }
        .onChange(of: model.pageCount) { _, _ in syncText() }
        .onChange(of: editing) { _, isEditing in
            if !isEditing { syncText() }
        }
    }

    private func syncText() {
        guard !editing else { return }
        text = String(model.currentPage + 1)
    }

    private func commit() {
        guard let number = Int(text), number >= 1 else {
            syncText()
            return
        }
        let target = min(max(number - 1, 0), max(model.pageCount - 1, 0))
        folioLog("toolbar: переход на страницу \(target + 1)")
        model.goToPage(target)
        model.updateVisiblePage(target)
        text = String(target + 1)
        editing = false
    }
}

// MARK: - Баннер «ядро не собрано»

private struct MockCoreBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 1) {
                Text("Ядро pdfcore не собрано — показан демонстрационный документ")
                    .font(.system(size: 11, weight: .medium))
                Text("Соберите ядро: pdfreader/scripts/build-core.sh — затем откройте PDF заново (⌘O).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.16))
        .overlay(alignment: .bottom) { Divider() }
        .lineLimit(1)
    }
}
