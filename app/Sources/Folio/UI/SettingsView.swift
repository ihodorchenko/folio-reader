import SwiftUI
import AppKit

/// Settings window: speech (off by default) and the translation language pair.
/// Everything changed here is saved to `UserDefaults` immediately via `SettingsStore`.
struct SettingsView: View {
    @Bindable var settings: SettingsStore

    @State private var speakingSample = false

    var body: some View {
        Form {
            Section(L10n.t("Speech")) {
                Toggle(L10n.t("Speak selected text"), isOn: $settings.speechEnabled)
                    .help(L10n.t("System speech synthesizer (AVSpeechSynthesizer). Off by default."))

                LabeledContent(L10n.t("Rate")) {
                    HStack(spacing: 8) {
                        Text(L10n.t("slow"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.speechRate, in: 0.3...0.7)
                            .frame(width: 150)
                        Text(L10n.t("fast"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.2f×", settings.speechRate / 0.5))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                .disabled(!settings.speechEnabled)

                LabeledContent(L10n.t("Voice")) {
                    HStack(spacing: 8) {
                        Text(SpeechService.shared.defaultVoiceDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(speakingSample ? L10n.t("Stop") : L10n.t("Play Sample")) {
                            if speakingSample {
                                SpeechService.shared.stop()
                                speakingSample = false
                            } else {
                                let ok = SpeechService.shared.speak(L10n.t("Folio reads the selected text aloud."))
                                speakingSample = ok
                            }
                        }
                        .controlSize(.small)
                        .disabled(!settings.speechEnabled)
                    }
                }

                Text(L10n.t("Off by default. The voice follows the text language; speech is available from the context menu and via ⌥⎋."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("Translation")) {
                Picker(L10n.t("Translate from"), selection: $settings.translateSourceID) {
                    ForEach(TranslateLanguage.sourceChoices) { language in
                        Text(language.displayName).tag(language.identifier)
                    }
                }
                Picker(L10n.t("to"), selection: $settings.translateTargetID) {
                    ForEach(TranslateLanguage.targetChoices) { language in
                        Text(language.displayName).tag(language.identifier)
                    }
                }

                HStack {
                    Text(L10n.t("Default: %@ → %@", TranslateLanguage.named(SettingsStore.defaultSourceID).displayName, TranslateLanguage.named(SettingsStore.defaultTargetID).displayName))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(L10n.t("Restore Defaults")) { settings.resetTranslationPair() }
                        .controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("Translate Selection is in the page context menu and the “Translation” menu (⌥⌘T). The language choice persists across launches."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if #available(macOS 15.0, *) {
                        Text(L10n.t("The first translation of a language pair may download system models. Find them in System Settings → General → Language & Region → Translation Languages."))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.t("System translation requires macOS 15 or later; on this system the menu item is disabled."))
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

// MARK: - Settings window

/// Custom settings window instead of the `Settings` scene: the app also runs as a
/// plain SwiftPM executable (no bundle), where the standard `Settings` scene does not open.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            folioLog("settings: settings window raised")
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
        window.title = L10n.t("Folio Settings")
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Folio.settings.window")
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        folioLog("settings: settings window opened (speech=\(SettingsStore.shared.speechEnabled ? "on" : "off"), pair=\(SettingsStore.shared.translationPairTitle))")
    }
}
