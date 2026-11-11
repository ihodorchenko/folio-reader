import AVFoundation
import Foundation
import NaturalLanguage
import Observation

/// Озвучка выделенного текста системным синтезатором речи (`AVSpeechSynthesizer`).
///
/// Сервис сам ничего не решает про выключенность: единственный вход `speak(...)`
/// отказывается работать, пока в настройках не включена озвучка (по умолчанию — выключена).
@Observable
@MainActor
final class SpeechService: NSObject {
    static let shared = SpeechService()

    /// Читает ли сейчас синтезатор.
    private(set) var isSpeaking = false
    /// Последняя фраза — для индикации в UI и снапшот-логов.
    private(set) var lastSpokenText = ""

    private let synthesizer = AVSpeechSynthesizer()
    private var isLoading = true

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Доступные системные голоса — для настроек и проверки окружения.
    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { $0.name < $1.name }
    }

    var defaultVoiceDescription: String {
        let voice = Self.voice(for: nil, hint: nil)
        return voice.map { "\($0.name) (\($0.language))" } ?? "системный по умолчанию"
    }

    // MARK: - Озвучка

    /// Озвучить текст. Возвращает `false`, если озвучка выключена в настройках
    /// или читать нечего — вызывающая сторона решает, что показать пользователю.
    @discardableResult
    func speak(_ text: String, languageHint: String? = nil) -> Bool {
        let settings = SettingsStore.shared
        guard settings.speechEnabled else {
            folioLog("speech: озвучка выключена в настройках — читать не буду")
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            folioLog("speech: пустой текст — читать нечего")
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
        folioLog("speech: читаю \(trimmed.count) символов, голос=\(utterance.voice?.name ?? "по умолчанию") (\(utterance.voice?.language ?? "?")): «\(String(trimmed.prefix(80)))»")
        return true
    }

    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        folioLog("speech: остановлено пользователем")
    }

    // MARK: - Подбор голоса

    /// Голос по языку текста: сначала подсказка вызывающей стороны (язык документа),
    /// затем автоопределение языка фразы, в конце — системная локаль.
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

    /// `AVSpeechSynthesisVoice(language:)` требует полный тег (`ru-RU`), поэтому для
    /// короткого кода (`ru`) ищем любой установленный голос этого языка.
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
            folioLog("speech: дочитано")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}
