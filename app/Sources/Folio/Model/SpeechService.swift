import AVFoundation
import Foundation
import NaturalLanguage
import Observation

/// Speaks selected text with the system speech synthesizer (`AVSpeechSynthesizer`).
///
/// The service does not decide anything about being disabled: the single entry point `speak(...)`
/// refuses to work until speech is enabled in settings (it is off by default).
@Observable
@MainActor
final class SpeechService: NSObject {
    static let shared = SpeechService()

    /// Whether the synthesizer is speaking right now.
    private(set) var isSpeaking = false
    /// Last phrase — for the UI indicator and snapshot logs.
    private(set) var lastSpokenText = ""

    private let synthesizer = AVSpeechSynthesizer()
    private var isLoading = true

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Available system voices — for settings and environment checks.
    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { $0.name < $1.name }
    }

    var defaultVoiceDescription: String {
        let voice = Self.voice(for: nil, hint: nil)
        return voice.map { "\($0.name) (\($0.language))" } ?? L10n.t("system default")
    }

    // MARK: - Speech

    /// Speak text. Returns `false` if speech is disabled in settings
    /// or there is nothing to read — the caller decides what to show the user.
    @discardableResult
    func speak(_ text: String, languageHint: String? = nil) -> Bool {
        let settings = SettingsStore.shared
        guard settings.speechEnabled else {
            folioLog("speech: disabled in settings — not reading")
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            folioLog("speech: empty text — nothing to read")
            return false
        }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = Float(settings.speechRate)
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        if let voice = Self.voice(for: trimmed, hint: languageHint) {
            utterance.voice = voice
        }

        lastSpokenText = trimmed
        isSpeaking = true
        synthesizer.speak(utterance)
        folioLog("speech: reading \(trimmed.count) characters, voice=\(utterance.voice?.name ?? "default") (\(utterance.voice?.language ?? "?")): \"\(String(trimmed.prefix(80)))\"")
        return true
    }

    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        folioLog("speech: stopped by user")
    }

    // MARK: - Voice selection

    /// Voice by the text language: first the caller's hint (the document language),
    /// then automatic detection of the phrase language, and finally the system locale.
    static func voice(for text: String?, hint: String?) -> AVSpeechSynthesisVoice? {
        if let hint, !hint.isEmpty, let voice = bestVoice(matching: hint) {
            return voice
        }
        if let text, !text.isEmpty {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(String(text.prefix(400)))
            if let dominant = recognizer.dominantLanguage?.rawValue,
               let voice = bestVoice(matching: dominant) {
                return voice
            }
        }
        return bestVoice(matching: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: nil)
    }

    /// `AVSpeechSynthesisVoice(language:)` requires a full tag (`ru-RU`), so for a
    /// short code (`ru`) we look for any installed voice of that language.
    private static func bestVoice(matching tag: String) -> AVSpeechSynthesisVoice? {
        if let exact = AVSpeechSynthesisVoice(language: tag) { return exact }
        let base = tag.split(separator: "-").first.map(String.init)?.lowercased() ?? tag.lowercased()
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().split(separator: "-").first.map(String.init) == base
        }
        return candidates.min { lhs, rhs in
            lhs.quality.rawValue > rhs.quality.rawValue
        }
    }
}

// MARK: - Delegate

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            folioLog("speech: finished")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}
