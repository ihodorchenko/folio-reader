import Foundation

/// Localization lookup for the app UI.
///
/// English text is the key: it doubles as the default value, so a development run
/// of the plain SwiftPM binary (no app bundle, no `*.lproj`) automatically uses
/// English. Russian lives in `Resources/ru.lproj/Localizable.strings` inside the
/// app bundle and is picked when the system language is Russian.
///
/// ```swift
/// L10n.t("Open…")
/// L10n.t("Page %ld of %ld", page, total)
/// ```
enum L10n {
    private static let table = "Localizable"

    /// Localized string for `key`; falls back to the key itself (English).
    static func t(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: table)
    }

    /// Localized format string with arguments (`%ld`, `%@`, `%.0f`, …).
    static func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }
}
