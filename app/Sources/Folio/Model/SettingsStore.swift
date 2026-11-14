import Foundation
import Observation

// MARK: - Translation language

/// Translation-pair language. An empty `identifier` means "detect automatically" (source only).
struct TranslateLanguage: Identifiable, Hashable, Sendable {
    /// BCP-47 (`en-US`) or an empty string for automatic detection.
    let identifier: String
    /// Human-readable name for menus/settings (localized by the system).
    let fallbackName: String

    var id: String { identifier }
    var isAuto: Bool { identifier.isEmpty }

    var displayName: String {
        if isAuto { return L10n.t("Detect automatically") }
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

    /// Compact name for narrow UI (the translation bubble): the language alone, plus a short
    /// region marker only where it distinguishes variants — "Английский (US)", "Русский".
    /// `displayName` stays the full system name for menus and settings.
    var shortName: String {
        if isAuto { return L10n.t("Detect automatically") }
        let parts = identifier.split(separator: "-")
        let languageCode = parts.first.map(String.init) ?? identifier
        let locale = Locale.current
        let language = locale.localizedString(forLanguageCode: languageCode)
            ?? locale.localizedString(forIdentifier: identifier)
            ?? fallbackName
        guard parts.count > 1 else { return language }
        let regionCode = String(parts[1]).uppercased()
        // The list only carries regional variants where the difference matters
        // (en-US/en-GB, pt-BR…) — otherwise the region would be noise.
        let variants = Self.all.filter { $0.identifier.hasPrefix(languageCode + "-") }
        guard variants.count > 1 else { return language }
        return "\(language) (\(regionCode))"
    }

    static let auto = TranslateLanguage(identifier: "", fallbackName: "Auto")

    /// A sensible list: languages supported by the system translation engine,
    /// with explicit regional variants where it matters (en-US by default).
    static let all: [TranslateLanguage] = [
        TranslateLanguage(identifier: "en-US", fallbackName: "English (US)"),
        TranslateLanguage(identifier: "en-GB", fallbackName: "English (UK)"),
        TranslateLanguage(identifier: "ru-RU", fallbackName: L10n.t("Russian")),
        TranslateLanguage(identifier: "uk-UA", fallbackName: L10n.t("Ukrainian")),
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

    /// The source may be "auto"; the target may not.
    static var sourceChoices: [TranslateLanguage] { [auto] + all }
    static var targetChoices: [TranslateLanguage] { all }

    static func named(_ identifier: String) -> TranslateLanguage {
        if identifier.isEmpty { return .auto }
        return all.first { $0.identifier == identifier }
            ?? TranslateLanguage(identifier: identifier, fallbackName: identifier)
    }
}

// MARK: - Settings

/// User settings. Stored in `UserDefaults` (`Folio.*` keys), so they survive a
/// relaunch; the defaults follow the product contract: speech off, translation
/// `en-US → ru-RU`.
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

    // MARK: Speech

    /// **Off** by default: until the user enables it in settings,
    /// neither the menu nor the context menu reads text aloud.
    var speechEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(speechEnabled, forKey: Key.speechEnabled)
            folioLog("settings: speech \(speechEnabled ? "enabled" : "disabled")")
        }
    }

    /// AVSpeechUtterance speech rate (0…1; 0.5 is the system default).
    var speechRate: Double {
        didSet {
            let clamped = min(max(speechRate, 0.3), 0.7)
            if clamped != speechRate { speechRate = clamped; return }
            guard !isLoading else { return }
            defaults.set(speechRate, forKey: Key.speechRate)
        }
    }

    // MARK: Translation

    var translateSourceID: String {
        didSet {
            guard !isLoading, translateSourceID != oldValue else { return }
            defaults.set(translateSourceID, forKey: Key.translateSource)
            folioLog("settings: source language → \(TranslateLanguage.named(translateSourceID).displayName)")
        }
    }

    var translateTargetID: String {
        didSet {
            guard !isLoading, translateTargetID != oldValue else { return }
            defaults.set(translateTargetID, forKey: Key.translateTarget)
            folioLog("settings: target language → \(TranslateLanguage.named(translateTargetID).displayName)")
        }
    }

    var translateSource: TranslateLanguage { TranslateLanguage.named(translateSourceID) }
    var translateTarget: TranslateLanguage { TranslateLanguage.named(translateTargetID) }

    /// Pair label for tooltips and logs: "English (US) → Russian".
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

    /// Reset to the factory pair EN (US) → RU.
    func resetTranslationPair() {
        translateSourceID = Self.defaultSourceID
        translateTargetID = Self.defaultTargetID
    }

    /// "The user changed the choice — it was saved" check (used in snapshot acceptance).
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
