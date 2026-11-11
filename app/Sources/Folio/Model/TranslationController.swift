import AppKit
import Foundation
import Observation

/// Состояние перевода выделенного фрагмента.
///
/// Сама `TranslationSession` создаётся только SwiftUI (`.translationTask`), поэтому
/// контроллер хранит лишь «что и когда переводить» и результат. Так модель остаётся
/// доступной и на macOS 14, где Translation framework ещё нет.
@Observable
@MainActor
final class TranslationController {
    enum Phase: Equatable {
        case idle
        case working
        case done
        case failed(String)
    }

    /// Текущая фаза перевода.
    private(set) var phase: Phase = .idle
    /// Исходный текст запроса.
    private(set) var sourceText = ""
    /// Перевод (когда `phase == .done`).
    private(set) var translatedText = ""
    /// Языковая пара конкретного запроса (снимок настроек на момент запуска).
    private(set) var sourceLanguageID = ""
    private(set) var targetLanguageID = ""
    /// Инкрементируется на каждый запрос — по нему хоcт запускает `.translationTask`.
    private(set) var requestToken = 0
    /// Показывать ли панель перевода.
    var isPanelPresented = false
    /// Заголовок панели: «Перевод слова» / «Перевод выделения».
    private(set) var requestOrigin = "выделения"
    /// Дополнительная подсказка под ошибкой (что делать).
    private(set) var failureHint: String?

    var sourceLanguage: TranslateLanguage { TranslateLanguage.named(sourceLanguageID) }
    var targetLanguage: TranslateLanguage { TranslateLanguage.named(targetLanguageID) }
    var pairTitle: String { "\(sourceLanguage.displayName) → \(targetLanguage.displayName)" }

    var canRetry: Bool { !sourceText.isEmpty }
    var isWorking: Bool { phase == .working }

    // MARK: - Запрос

    /// Новый запрос перевода. Пара языков фиксируется в запросе, чтобы смена
    /// настроек не «переехала» в уже запущенный перевод.
    func request(text: String, sourceID: String, targetID: String, origin: String = "выделения") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            folioLog("translate: пустой текст — переводить нечего")
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
        folioLog("translate: запрос #\(requestToken) «\(String(trimmed.prefix(60)))» \(pairTitle), символов \(trimmed.count)")
    }

    /// Повторить перевод текущего текста с актуальной парой из настроек.
    func retry() {
        guard canRetry else { return }
        let settings = SettingsStore.shared
        request(text: sourceText,
                sourceID: settings.translateSourceID,
                targetID: settings.translateTargetID,
                origin: requestOrigin)
    }

    // MARK: - Результаты (вызывает хоcт `.translationTask`)

    func complete(_ text: String) {
        translatedText = text
        phase = .done
        folioLog("translate: готово, символов \(text.count)")
    }

    func fail(_ error: Error) {
        let message = Self.describe(error)
        failureHint = Self.hint(for: error)
        phase = .failed(message)
        folioLog("translate: ОШИБКА \(message)")
    }

    func cancel() {
        guard phase == .working else { return }
        phase = .idle
        folioLog("translate: отменено")
    }

    /// Система без Translation framework (macOS < 15): показываем пояснение вместо перевода.
    func unavailableOnThisSystem() {
        sourceText = ""
        translatedText = ""
        sourceLanguageID = SettingsStore.shared.translateSourceID
        targetLanguageID = SettingsStore.shared.translateTargetID
        requestOrigin = "выделения"
        phase = .failed("Системный перевод требует macOS 15 или новее")
        failureHint = "На этой версии macOS доступны словарь и озвучка — переводить нечем."
        isPanelPresented = true
        folioLog("translate: система без Translation framework — показываю пояснение")
    }

    // MARK: - Диагностика ошибок

    static func describe(_ error: Error) -> String {
        if let cocoa = error as? CocoaError, cocoa.code == .userCancelled {
            return "Загрузка языковых моделей отменена"
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "Сеть недоступна (\(nsError.code)): модели перевода не скачались"
        }
        let text = error.localizedDescription
        return text.isEmpty ? "Не удалось перевести текст" : text
    }

    /// Подсказка по типичным причинам отказа — нужна, чтобы пользователь знал, где искать.
    static func hint(for error: Error) -> String? {
        if let cocoa = error as? CocoaError, cocoa.code == .userCancelled {
            return "Языковые модели можно скачать позже: ⌘, → Перевод."
        }
        return "Нужны языковые модели: Системные настройки → Основные → Язык и регион → Языки перевода."
    }

    // MARK: - Снапшот-приёмка

    /// Подставить результат без сети — только для headless-снапшотов UI.
    func debugInjectResult(source: String, translated: String, sourceID: String, targetID: String) {
        sourceText = source
        translatedText = translated
        sourceLanguageID = sourceID
        targetLanguageID = targetID
        requestOrigin = "выделения"
        failureHint = nil
        phase = .done
        isPanelPresented = true
        folioLog("translate: снапшот — подставлен результат \(TranslateLanguage.named(sourceID).displayName) → \(TranslateLanguage.named(targetID).displayName)")
    }
}
