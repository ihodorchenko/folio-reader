import SwiftUI
import AppKit

/// Панель перевода выделенного фрагмента: исходник, перевод, пара языков, действия.
///
/// Панель не знает про `TranslationSession` — она лишь показывает состояние
/// `TranslationController` и меняет настройки пары языков (они сохраняются в `UserDefaults`).
struct TranslationPanel: View {
    let model: ReaderModel

    @Bindable private var settings: SettingsStore
    @Bindable private var controller: TranslationController
    @State private var reflowTask: Task<Void, Never>?

    init(model: ReaderModel) {
        self.model = model
        self._settings = Bindable(model.settings)
        self._controller = Bindable(model.translation)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sourceSection
                    resultSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: settings.translateSourceID) { _, _ in reflow() }
        .onChange(of: settings.translateTargetID) { _, _ in reflow() }
    }

    // MARK: - Заголовок

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Перевод \(controller.requestOrigin)")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)

            Picker("", selection: $settings.translateSourceID) {
                ForEach(TranslateLanguage.sourceChoices) { language in
                    Text(language.displayName).tag(language.identifier)
                }
            }
            .labelsHidden()
            .frame(width: 190)
            .help("Язык оригинала (выбор сохраняется)")

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            Picker("", selection: $settings.translateTargetID) {
                ForEach(TranslateLanguage.targetChoices) { language in
                    Text(language.displayName).tag(language.identifier)
                }
            }
            .labelsHidden()
            .frame(width: 190)
            .help("Язык перевода (выбор сохраняется)")

            Button {
                swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .help("Поменять языки местами")
            .disabled(settings.translateSourceID.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Исходник и результат

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(controller.sourceLanguage.displayName.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(controller.sourceText)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 7))
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(controller.targetLanguage.displayName.uppercased())
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
                    .padding(10)
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
                Text("Перевожу…")
                    .font(.system(size: 12, weight: .medium))
                Text("Первый перевод пары языков может скачивать системные модели — это несколько минут.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
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
            Button("Открыть настройки перевода") { model.presentSettings() }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Подвал

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                copyTranslation()
            } label: {
                Label("Копировать", systemImage: "doc.on.doc")
            }
            .disabled(controller.phase != .done)

            Button {
                model.speech.speak(controller.translatedText, languageHint: controller.targetLanguageID)
            } label: {
                Label("Озвучить", systemImage: "speaker.wave.2")
            }
            .disabled(controller.phase != .done || !settings.speechEnabled)
            .help(settings.speechEnabled
                  ? "Прочитать перевод вслух"
                  : "Озвучка выключена — включите её в настройках (⌘,)")

            Spacer(minLength: 0)

            Button("Перевести заново") { controller.retry() }
                .disabled(!controller.canRetry || controller.isWorking)

            Button("Закрыть") { controller.isPanelPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Действия

    private func copyTranslation() {
        guard controller.phase == .done else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(controller.translatedText, forType: .string)
        folioLog("translate: перевод \(ok ? "скопирован" : "НЕ скопирован") (\(controller.translatedText.count) символов)")
    }

    private func swapLanguages() {
        let source = settings.translateSourceID
        settings.translateSourceID = settings.translateTargetID
        settings.translateTargetID = source
    }

    /// Пользователь сменил пару языков — переводим тем же текстом.
    /// Небольшая задержка склеивает два изменения (например, обмен языков местами) в один запрос.
    private func reflow() {
        reflowTask?.cancel()
        let sourceID = settings.translateSourceID
        let targetID = settings.translateTargetID
        reflowTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, controller.canRetry else { return }
            guard controller.sourceLanguageID != sourceID || controller.targetLanguageID != targetID else {
                folioLog("translate: пара не изменилась — повторный запрос не нужен")
                return
            }
            folioLog("translate: пара изменена → \(settings.translationPairTitle), перевожу заново")
            controller.request(text: controller.sourceText,
                               sourceID: sourceID,
                               targetID: targetID,
                               origin: controller.requestOrigin)
        }
    }
}
