import AppKit
import Foundation
import Observation

/// State of the translation of a selected fragment.
///
/// The `TranslationSession` itself is created only by SwiftUI (`.translationTask`), so the
/// controller stores just "what and when to translate" and the result. That keeps the model
/// usable on macOS 14 as well, where the Translation framework does not exist yet.
@Observable
@MainActor
final class TranslationController {
    enum Phase: Equatable {
        case idle
        case working
        case done
        case failed(String)
    }

    /// Current translation phase.
    private(set) var phase: Phase = .idle
    /// Source text of the request.
    private(set) var sourceText = ""
    /// Translation (when `phase == .done`).
    private(set) var translatedText = ""
    /// Language pair of this particular request (settings snapshot taken at launch).
    private(set) var sourceLanguageID = ""
    private(set) var targetLanguageID = ""
    /// Incremented on every request — the host uses it to start `.translationTask`.
    private(set) var requestToken = 0
    /// Whether the translation panel is shown.
    var isPanelPresented = false
    /// What the request was made for: "word" / "selection" (the panel title is built from it).
    private(set) var requestOrigin = "selection"
    /// Extra hint under the error (what to do).
    private(set) var failureHint: String?

    var sourceLanguage: TranslateLanguage { TranslateLanguage.named(sourceLanguageID) }
    var targetLanguage: TranslateLanguage { TranslateLanguage.named(targetLanguageID) }
    var pairTitle: String { "\(sourceLanguage.displayName) → \(targetLanguage.displayName)" }

    var canRetry: Bool { !sourceText.isEmpty }
    var isWorking: Bool { phase == .working }

    // MARK: - Request

    /// New translation request. The language pair is captured in the request so that a settings
    /// change does not "move into" an already running translation.
    func request(text: String, sourceID: String, targetID: String, origin: String = "selection") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            folioLog("translate: empty text — nothing to translate")
            NSSound.beep()
            return
        }
        sourceText = trimmed
        sourceLanguageID = sourceID
        targetLanguageID = targetID
        requestOrigin = origin
        translatedText = ""
        failureHint = nil
        phase = .working
        isPanelPresented = true
        requestToken += 1
        folioLog("translate: request #\(requestToken) \"\(String(trimmed.prefix(60)))\" \(pairTitle), \(trimmed.count) characters")
    }

    /// Retry translating the current text with the current pair from settings.
    func retry() {
        guard canRetry else { return }
        let settings = SettingsStore.shared
        request(text: sourceText,
                sourceID: settings.translateSourceID,
                targetID: settings.translateTargetID,
                origin: requestOrigin)
    }

    // MARK: - Results (called by the `.translationTask` host)

    func complete(_ text: String) {
        translatedText = text
        phase = .done
        folioLog("translate: done, \(text.count) characters")
    }

    func fail(_ error: Error) {
        let message = Self.describe(error)
        failureHint = Self.hint(for: error)
        phase = .failed(message)
        folioLog("translate: ERROR \(message)")
    }

    func cancel() {
        guard phase == .working else { return }
        phase = .idle
        folioLog("translate: cancelled")
    }

    /// System without the Translation framework (macOS < 15): show an explanation instead of a translation.
    func unavailableOnThisSystem() {
        sourceText = ""
        translatedText = ""
        sourceLanguageID = SettingsStore.shared.translateSourceID
        targetLanguageID = SettingsStore.shared.translateTargetID
        requestOrigin = "selection"
        phase = .failed(L10n.t("System translation requires macOS 15 or later"))
        failureHint = L10n.t("On this version of macOS only the dictionary and speech are available — there is no translation.")
        isPanelPresented = true
        folioLog("translate: system without the Translation framework — showing an explanation")
    }

    // MARK: - Error diagnostics

    static func describe(_ error: Error) -> String {
        if let cocoa = error as? CocoaError, cocoa.code == .userCancelled {
            return L10n.t("Language model download cancelled")
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return L10n.t("No network (%ld): translation models weren't downloaded", nsError.code)
        }
        let text = error.localizedDescription
        return text.isEmpty ? L10n.t("Couldn't translate the text") : text
    }

    /// Hint for the typical failure causes — so the user knows where to look.
    static func hint(for error: Error) -> String? {
        if let cocoa = error as? CocoaError, cocoa.code == .userCancelled {
            return L10n.t("Language models can be downloaded later: ⌘, → Translation.")
        }
        return L10n.t("Language models are required: System Settings → General → Language & Region → Translation Languages.")
    }

    // MARK: - Snapshot acceptance

    /// Inject a result without the network — for headless UI snapshots only.
    func debugInjectResult(source: String, translated: String, sourceID: String, targetID: String) {
        sourceText = source
        translatedText = translated
        sourceLanguageID = sourceID
        targetLanguageID = targetID
        requestOrigin = "selection"
        failureHint = nil
        phase = .done
        isPanelPresented = true
        folioLog("translate: snapshot — injected result \(TranslateLanguage.named(sourceID).displayName) → \(TranslateLanguage.named(targetID).displayName)")
    }
}
