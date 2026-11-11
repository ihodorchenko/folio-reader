import SwiftUI
import AppKit

/// Окно настроек: озвучка (по умолчанию выключена) и пара языков перевода.
/// Всё, что здесь меняется, сразу сохраняется в `UserDefaults` через `SettingsStore`.
struct SettingsView: View {
    @Bindable var settings: SettingsStore

    @State private var speakingSample = false

    var body: some View {
        Form {
            Section("Озвучка") {
                Toggle("Озвучивать выделенный текст", isOn: $settings.speechEnabled)
                    .help("Системный синтезатор речи (AVSpeechSynthesizer). По умолчанию выключено.")

                LabeledContent("Скорость") {
                    HStack(spacing: 8) {
                        Text("медленно")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.speechRate, in: 0.3...0.7)
                            .frame(width: 150)
                        Text("быстро")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.2f×", settings.speechRate / 0.5))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                .disabled(!settings.speechEnabled)

                LabeledContent("Голос") {
                    HStack(spacing: 8) {
                        Text(SpeechService.shared.defaultVoiceDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(speakingSample ? "Стоп" : "Прослушать пример") {
                            if speakingSample {
                                SpeechService.shared.stop()
                                speakingSample = false
                            } else {
                                let ok = SpeechService.shared.speak("Folio читает текст выделенного фрагмента.")
                                speakingSample = ok
                            }
                        }
                        .controlSize(.small)
                        .disabled(!settings.speechEnabled)
                    }
                }

                Text("Выключено по умолчанию. Голос подбирается по языку текста; озвучка доступна из контекстного меню и по ⌥⎋.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Section("Перевод") {
                Picker("Переводить с", selection: $settings.translateSourceID) {
                    ForEach(TranslateLanguage.sourceChoices) { language in
                        Text(language.displayName).tag(language.identifier)
                    }
                }
                Picker("на", selection: $settings.translateTargetID) {
                    ForEach(TranslateLanguage.targetChoices) { language in
                        Text(language.displayName).tag(language.identifier)
                    }
                }

                HStack {
                    Text("По умолчанию: \(TranslateLanguage.named(SettingsStore.defaultSourceID).displayName) → \(TranslateLanguage.named(SettingsStore.defaultTargetID).displayName)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Вернуть по умолчанию") { settings.resetTranslationPair() }
                        .controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Перевод выделения — в контекстном меню страницы и в меню «Перевод» (⌥⌘T). Выбор языков сохраняется между запусками.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if #available(macOS 15.0, *) {
                        Text("Первый перевод пары языков может скачивать системные модели. Где посмотреть: Системные настройки → Основные → Язык и регион → Языки перевода.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Системный перевод требует macOS 15 или новее; на этой системе пункт меню будет отключён.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 470)
        .onChange(of: SpeechService.shared.isSpeaking) { _, value in
            if !value { speakingSample = false }
        }
    }
}

// MARK: - Окно настроек

/// Собственное окно настроек вместо `Settings`-сцены: приложение запускается и как
/// SwiftPM-исполняемый файл (без бандла), где стандартная сцена `Settings` не открывается.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            folioLog("settings: окно настроек поднято")
            return
        }
        let root = SettingsView(settings: SettingsStore.shared)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 470)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки Folio"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Folio.settings.window")
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        folioLog("settings: окно настроек открыто (озвучка=\(SettingsStore.shared.speechEnabled ? "вкл" : "выкл"), пара=\(SettingsStore.shared.translationPairTitle))")
    }
}
