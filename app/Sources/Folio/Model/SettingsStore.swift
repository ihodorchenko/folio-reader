import Foundation
import Observation

// MARK: - Язык перевода

/// Язык пары перевода. Пустой `identifier` — «определять автоматически» (только для источника).
struct TranslateLanguage: Identifiable, Hashable, Sendable {
    /// BCP-47 (`en-US`) или пустая строка для автоопределения.
    let identifier: String
    /// Человеческое название для меню/настроек (локализовано системой).
    let fallbackName: String

    var id: String { identifier }
    var isAuto: Bool { identifier.isEmpty }

    var displayName: String {
        if isAuto { return "Определять автоматически" }
        let locale = Locale.current
        if let name = locale.localizedString(forIdentifier: identifier), !name.isEmpty {
            return name
        }
        let base = identifier.split(separator: "-").first.map(String.init) ?? identifier
        if let name = locale.localizedString(forLanguageCode: base), !name.isEmpty {
            return name
        }
        return fallbackName
    }

    static let auto = TranslateLanguage(identifier: "", fallbackName: "Авто")

    /// Разумный список: языки, которые поддерживает системный движок перевода,
    /// с явными региональными вариантами там, где это важно (en-US по умолчанию).
    static let all: [TranslateLanguage] = [
        TranslateLanguage(identifier: "en-US", fallbackName: "English (US)"),
        TranslateLanguage(identifier: "en-GB", fallbackName: "English (UK)"),
        TranslateLanguage(identifier: "ru-RU", fallbackName: "Русский"),
        TranslateLanguage(identifier: "uk-UA", fallbackName: "Украинская"),
        TranslateLanguage(identifier: "de-DE", fallbackName: "Deutsch"),
        TranslateLanguage(identifier: "fr-FR", fallbackName: "Français"),
        TranslateLanguage(identifier: "es-ES", fallbackName: "Español"),
        TranslateLanguage(identifier: "it-IT", fallbackName: "Italiano"),
        TranslateLanguage(identifier: "pt-BR", fallbackName: "Português (Brasil)"),
        TranslateLanguage(identifier: "nl-NL", fallbackName: "Nederlands"),
        TranslateLanguage(identifier: "pl-PL", fallbackName: "Polski"),
        TranslateLanguage(identifier: "cs-CZ", fallbackName: "Čeština"),
        TranslateLanguage(identifier: "sv-SE", fallbackName: "Svenska"),
        TranslateLanguage(identifier: "da-DK", fallbackName: "Dansk"),
        TranslateLanguage(identifier: "nb-NO", fallbackName: "Norsk bokmål"),
        TranslateLanguage(identifier: "fi-FI", fallbackName: "Suomi"),
        TranslateLanguage(identifier: "el-GR", fallbackName: "Ελληνικά"),
        TranslateLanguage(identifier: "tr-TR", fallbackName: "Türkçe"),
        TranslateLanguage(identifier: "he-IL", fallbackName: "עברית"),
        TranslateLanguage(identifier: "ar", fallbackName: "العربية"),
        TranslateLanguage(identifier: "hi-IN", fallbackName: "हिन्दी"),
        TranslateLanguage(identifier: "th-TH", fallbackName: "ไทย"),
        TranslateLanguage(identifier: "vi-VN", fallbackName: "Tiếng Việt"),
        TranslateLanguage(identifier: "ja-JP", fallbackName: "日本語"),
        TranslateLanguage(identifier: "ko-KR", fallbackName: "한국어"),
        TranslateLanguage(identifier: "zh-Hans", fallbackName: "简体中文"),
        TranslateLanguage(identifier: "zh-Hant", fallbackName: "繁體中文"),
    ]

    /// Источник может быть «авто», цель — нет.
    static var sourceChoices: [TranslateLanguage] { [auto] + all }
    static var targetChoices: [TranslateLanguage] { all }

    static func named(_ identifier: String) -> TranslateLanguage {
        if identifier.isEmpty { return .auto }
        return all.first { $0.identifier == identifier }
            ?? TranslateLanguage(identifier: identifier, fallbackName: identifier)
    }
}

// MARK: - Настройки

/// Пользовательские настройки. Хранятся в `UserDefaults` (ключи `Folio.*`),
/// поэтому переживают перезапуск; значения по умолчанию — по продуктовому контракту:
/// озвучка выключена, перевод `en-US → ru-RU`.
@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    enum Key {
        static let speechEnabled = "Folio.speech.enabled"
        static let speechRate = "Folio.speech.rate"
        static let translateSource = "Folio.translate.source"
        static let translateTarget = "Folio.translate.target"
    }

    static let defaultSourceID = "en-US"
    static let defaultTargetID = "ru-RU"

    // MARK: Озвучка

    /// По умолчанию **выключена**: пока пользователь не включит её в настройках,
    /// ни меню, ни контекстное меню не читают текст вслух.
    var speechEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(speechEnabled, forKey: Key.speechEnabled)
            folioLog("settings: озвучка \(speechEnabled ? "включена" : "выключена")")
        }
    }

    /// Скорость речи AVSpeechUtterance (0…1, 0.5 — системная по умолчанию).
    var speechRate: Double {
        didSet {
            let clamped = min(max(speechRate, 0.3), 0.7)
            if clamped != speechRate { speechRate = clamped; return }
            guard !isLoading else { return }
            defaults.set(speechRate, forKey: Key.speechRate)
        }
    }

    // MARK: Перевод

    var translateSourceID: String {
        didSet {
            guard !isLoading, translateSourceID != oldValue else { return }
            defaults.set(translateSourceID, forKey: Key.translateSource)
            folioLog("settings: язык источника → \(TranslateLanguage.named(translateSourceID).displayName)")
        }
    }

    var translateTargetID: String {
        didSet {
            guard !isLoading, translateTargetID != oldValue else { return }
            defaults.set(translateTargetID, forKey: Key.translateTarget)
            folioLog("settings: язык перевода → \(TranslateLanguage.named(translateTargetID).displayName)")
        }
    }

    var translateSource: TranslateLanguage { TranslateLanguage.named(translateSourceID) }
    var translateTarget: TranslateLanguage { TranslateLanguage.named(translateTargetID) }

    /// Подпись пары для тултипов и логов: «Английский (США) → Русский».
    var translationPairTitle: String {
        "\(translateSource.displayName) → \(translateTarget.displayName)"
    }

    private let defaults: UserDefaults
    private var isLoading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Key.speechEnabled) == nil {
            speechEnabled = false
        } else {
            speechEnabled = defaults.bool(forKey: Key.speechEnabled)
        }
        if defaults.object(forKey: Key.speechRate) == nil {
            speechRate = 0.5
        } else {
            speechRate = defaults.double(forKey: Key.speechRate)
        }
        translateSourceID = defaults.string(forKey: Key.translateSource) ?? Self.defaultSourceID
        translateTargetID = defaults.string(forKey: Key.translateTarget) ?? Self.defaultTargetID
        isLoading = false
    }

    /// Возврат к заводской паре EN (US) → RU.
    func resetTranslationPair() {
        translateSourceID = Self.defaultSourceID
        translateTargetID = Self.defaultTargetID
    }

    /// Проверка «пользователь изменил выбор — он сохранён» (используется в снапшот-приёмке).
    func reloadFromDisk() -> (source: String, target: String, speechEnabled: Bool, speechRate: Double) {
        (
            source: defaults.string(forKey: Key.translateSource) ?? Self.defaultSourceID,
            target: defaults.string(forKey: Key.translateTarget) ?? Self.defaultTargetID,
            speechEnabled: defaults.object(forKey: Key.speechEnabled) == nil
                ? false
                : defaults.bool(forKey: Key.speechEnabled),
            speechRate: defaults.object(forKey: Key.speechRate) == nil
                ? 0.5
                : defaults.double(forKey: Key.speechRate)
        )
    }
}
