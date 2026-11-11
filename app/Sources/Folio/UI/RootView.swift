import SwiftUI
import AppKit

/// Root reader window: sidebar + pages in system-app style.
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
            // The system sidebar button is removed by WindowChrome: `.toolbar(removing:)`
            // does not take effect on `NavigationSplitView` with a custom toolbar.
            .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
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
        .onAppear {
            model.backingScale = displayScale
            WindowChrome.suppressSoon()
        }
        .onChange(of: displayScale) { _, scale in model.backingScale = scale }
        .onChange(of: model.columnVisibility) { _, _ in WindowChrome.suppressSoon() }
        .alert(L10n.t("Could Not Open Document"),
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button(L10n.t("Close"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // The system translation host lives for the whole lifetime of the window: SwiftUI
        // provides the session, and requests come from the AppKit menu (the page context menu).
        .background(TranslationTaskHost(controller: model.translation))
        .sheet(isPresented: Binding(get: { model.translation.isPanelPresented },
                                    set: { model.translation.isPanelPresented = $0 })) {
            TranslationPanel(model: model)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Left group: the only sidebar button, immediately followed by the book title.
        ToolbarItem(placement: .navigation) {
            Button {
                toggleSidebar()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help(model.columnVisibility == .detailOnly ? L10n.t("Show Sidebar (⧉)") : L10n.t("Hide Sidebar (⧉)"))
        }

        ToolbarItem(placement: .navigation) {
            titleView
        }

        // Flexible spring in the center: without it SwiftUI packs the right group right
        // after the title instead of pinning it to the toolbar edge.
        ToolbarItem(placement: .principal) {
            Spacer(minLength: 0)
        }

        // Right group: pinned to the far right corner of the toolbar.
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
                Text(L10n.t("DEMO"))
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.yellow.opacity(0.35), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .lineLimit(1)
        .help(L10n.t("%@ — %@", model.documentTitle, model.statusText))
    }

    private var zoomMenu: some View {
        Menu {
            Button(L10n.t("Zoom In")) { model.zoomIn() }
            Button(L10n.t("Zoom Out")) { model.zoomOut() }
            Divider()
            Button(L10n.t("Fit Width")) { model.applyFitWidth() }
            Button(L10n.t("100%")) { model.actualSize() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus.magnifyingglass")
                Text("\(Int((model.zoom * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.t("Zoom: pinch, ⌘+ / ⌘−, ⌘0 — fit to width, ⌘1 — 100%"))
    }

    private var debugButton: some View {
        Button {
            model.toggleDebugOverlay()
        } label: {
            Image(systemName: "rectangle.dashed")
                .symbolVariant(model.showDebugOverlay ? .fill : .none)
        }
        .foregroundStyle(model.showDebugOverlay ? Color.accentColor : Color.primary)
        .help(L10n.t("Show element layout: kind, heading level, confidence"))
    }

    private var searchButton: some View {
        Button {
            model.focusSearch()
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .help(L10n.t("Search the document (⌘F)"))
    }

    private var moreMenu: some View {
        Menu {
            Button(L10n.t("Open…")) { model.presentOpenPanel() }
            Menu(L10n.t("Open Recent")) {
                let recent = RecentDocumentsStore.shared.documents
                if recent.isEmpty {
                    Text(L10n.t("No Recent Documents"))
                } else {
                    ForEach(recent) { document in
                        Button(document.title) { model.open(url: document.url) }
                    }
                    Divider()
                    Button(L10n.t("Clear Menu")) { RecentDocumentsStore.shared.clear() }
                }
            }
            Divider()
            Button(model.translation.canRetry ? L10n.t("Translate Selection (Retry)") : L10n.t("Translate Selection")) {
                if model.translation.canRetry {
                    model.translation.retry()
                } else {
                    model.translateSelection()
                }
            }
            .disabled((model.selection?.isEmpty ?? true) && !model.translation.canRetry)
            Button(model.speech.isSpeaking ? L10n.t("Stop Speaking") : L10n.t("Speak Selection")) {
                model.speech.isSpeaking ? model.stopSpeaking() : model.speakSelection()
            }
            .disabled(!model.settings.speechEnabled)
            Divider()
            Button(L10n.t("Export Structure → JSON…")) { model.exportStructureJSON() }
                .disabled(model.structure == nil)
            Divider()
            Toggle(L10n.t("Element Layout"), isOn: Binding(get: { model.debugMode == .blocks },
                                                         set: { model.setDebugMode($0 ? .blocks : .off) }))
            Toggle(L10n.t("Word Boxes"), isOn: Binding(get: { model.debugMode == .words },
                                                      set: { model.setDebugMode($0 ? .words : .off) }))
            Divider()
            Button(L10n.t("Actual Size (100%)")) { model.actualSize() }
            Button(L10n.t("Fit Width")) { model.applyFitWidth() }
            Divider()
            Button(L10n.t("Settings…")) { model.presentSettings() }
                .keyboardShortcut(",", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.t("More"))
    }

    // MARK: - Actions

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.22)) {
            model.columnVisibility = (model.columnVisibility == .detailOnly) ? .all : .detailOnly
        }
        // SwiftUI rebuilds the toolbar after visibility changes — clean up the system button once more.
        WindowChrome.suppressSoon()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier("com.adobe.pdf") })
                ?? providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                folioLog("drop: opening \(url.path)")
                model.open(url: url)
            }
        }
        return true
    }
}

// MARK: - "page / total" field

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
        .help(L10n.t("Page number — type a number and press Return"))
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
        folioLog("toolbar: go to page \(target + 1)")
        model.goToPage(target)
        model.updateVisiblePage(target)
        text = String(target + 1)
        editing = false
    }
}

// MARK: - "core not built" banner

private struct MockCoreBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t("The pdfcore core is not built — showing a demo document"))
                    .font(.system(size: 11, weight: .medium))
                Text(L10n.t("Build the core: pdfreader/scripts/build-core.sh — then reopen the PDF (⌘O)."))
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
