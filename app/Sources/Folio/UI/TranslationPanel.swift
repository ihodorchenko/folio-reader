import SwiftUI
import AppKit

/// Height of the scrollable part of the bubble: measured so that short fragments stay compact
/// and long ones scroll instead of growing the popover.
private struct TranslationBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Translation bubble for the selected fragment (source, translation, language pair, actions).
///
/// It is presented as a system popover anchored to the selection — the same interaction as the
/// Look Up / Translation bubble of the system apps: `Esc` or a click outside dismisses it, a new
/// gesture (selection, scroll, context menu) replaces it. There is no Close button and no modal
/// sheet, so translating a fragment does not block the reader.
///
/// The view knows nothing about `TranslationSession` — it only shows the state of
/// `TranslationController` and changes the language-pair settings (persisted in `UserDefaults`).
struct TranslationPopover: View {
    let model: ReaderModel

    @Bindable private var settings: SettingsStore
    @Bindable private var controller: TranslationController
    @State private var reflowTask: Task<Void, Never>?
    /// Measured height of the content inside the scroll view. Starts near a typical size so the
    /// first layout pass does not open an almost-empty popover.
    @State private var bodyHeight: CGFloat = 140

    /// Identifier of the popover window — lets the headless snapshot run tell the bubble apart
    /// from other popovers the app may have on screen.
    static let windowIdentifier = "folio.translation.bubble"

    /// Width of the bubble: close to the system one, still readable for a sentence or two.
    private static let width: CGFloat = 440
    /// The body never grows beyond this — longer fragments scroll.
    private static let maxBodyHeight: CGFloat = 300

    init(model: ReaderModel) {
        self.model = model
        self._settings = Bindable(model.settings)
        self._controller = Bindable(model.translation)
    }

    var body: some View {
        VStack(spacing: 0) {
            languageBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sourceSection
                    resultSection
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: TranslationBodyHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .frame(height: min(max(bodyHeight, 1), Self.maxBodyHeight))
            Divider()
            actionBar
        }
        .frame(width: Self.width)
        .onPreferenceChange(TranslationBodyHeightKey.self) { height in
            guard height > 1 else { return }
            bodyHeight = height
        }
        .onChange(of: settings.translateSourceID) { _, _ in reflow() }
        .onChange(of: settings.translateTargetID) { _, _ in reflow() }
        .background(TranslationBubbleWindowMarker().frame(width: 0, height: 0))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Translation"))
    }

    // MARK: - Language pair

    private var languageBar: some View {
        HStack(spacing: 6) {
            Picker("", selection: $settings.translateSourceID) {
                ForEach(TranslateLanguage.sourceChoices) { language in
                    Text(language.shortName).tag(language.identifier)
                }
            }
            .labelsHidden()
            .frame(width: 158)
            .help(L10n.t("Source language (the choice is saved)") + ": " + controller.sourceLanguage.displayName)

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)

            Picker("", selection: $settings.translateTargetID) {
                ForEach(TranslateLanguage.targetChoices) { language in
                    Text(language.shortName).tag(language.identifier)
                }
            }
            .labelsHidden()
            .frame(width: 158)
            .help(L10n.t("Target language (the choice is saved)") + ": " + controller.targetLanguage.displayName)

            Button {
                swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Swap languages"))
            .disabled(settings.translateSourceID.isEmpty)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Source and result

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(controller.sourceLanguage.shortName.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(controller.sourceText)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 7))
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(controller.targetLanguage.shortName.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)

            switch controller.phase {
            case .idle, .working:
                workingState
            case .done:
                Text(controller.translatedText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(Color.accentColor.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.accentColor.opacity(0.22)))
            case .failed(let message):
                failedState(message: message)
            }
        }
    }

    private var workingState: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("Translating…"))
                    .font(.system(size: 12, weight: .medium))
                Text(L10n.t("The first translation of a language pair may download system models — this can take a few minutes."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private func failedState(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12))
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint = controller.failureHint {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(L10n.t("Translation Settings…")) { model.presentSettings() }
                .controlSize(.small)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Actions

    /// No Close item: `Esc` and a click outside dismiss the popover.
    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                copyTranslation()
            } label: {
                Label(L10n.t("Copy"), systemImage: "doc.on.doc")
            }
            .disabled(controller.phase != .done)
            .help(L10n.t("Copy the translation"))

            Button {
                model.speech.speak(controller.translatedText, languageHint: controller.targetLanguageID)
            } label: {
                Label(L10n.t("Speak"), systemImage: "speaker.wave.2")
            }
            .disabled(controller.phase != .done || !settings.speechEnabled)
            .help(settings.speechEnabled
                  ? L10n.t("Read the translation aloud")
                  : L10n.t("Speech is off — enable it in Settings (⌘,)"))

            Spacer(minLength: 0)

            Button {
                controller.retry()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!controller.canRetry || controller.isWorking)
            .help(L10n.t("Translate Again"))
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func copyTranslation() {
        guard controller.phase == .done else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(controller.translatedText, forType: .string)
        folioLog("translate: translation \(ok ? "copied" : "not copied") (\(controller.translatedText.count) chars)")
    }

    private func swapLanguages() {
        let source = settings.translateSourceID
        settings.translateSourceID = settings.translateTargetID
        settings.translateTargetID = source
    }

    /// The user changed the language pair — translate the same text again.
    /// A short delay merges two changes (for example, swapping languages) into one request.
    private func reflow() {
        reflowTask?.cancel()
        let sourceID = settings.translateSourceID
        let targetID = settings.translateTargetID
        reflowTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, controller.canRetry else { return }
            guard controller.sourceLanguageID != sourceID || controller.targetLanguageID != targetID else {
                folioLog("translate: pair unchanged — retry not needed")
                return
            }
            folioLog("translate: pair changed → \(settings.translationPairTitle), translating again")
            controller.request(text: controller.sourceText,
                               sourceID: sourceID,
                               targetID: targetID,
                               origin: controller.requestOrigin)
        }
    }
}

// MARK: - Window marker

/// Marks the popover window with a stable identifier: the acceptance run captures the bubble by
/// window, and other popovers on screen must not be mistaken for it.
private struct TranslationBubbleWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = NSUserInterfaceItemIdentifier(TranslationPopover.windowIdentifier)
        }
    }
}
