import SwiftUI
import AppKit

#if canImport(Translation)
import Translation
#endif

/// Invisible translation host: keeps the `TranslationSession` alive as long as the reader window lives.
///
/// `TranslationSession` cannot be created manually — SwiftUI provides it in `.translationTask`,
/// so a request from an AppKit menu (the page context menu) goes like this:
/// `TranslationController.request(...)` → the `requestToken` counter grows → the host starts
/// `.translationTask` → the result is stored back into the controller → the panel shows the text.
struct TranslationTaskHost: View {
    let controller: TranslationController

    var body: some View {
        if #available(macOS 15.0, *) {
            ModernTranslationTaskHost(controller: controller)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

#if canImport(Translation)
/// macOS 15+ — the Translation framework is available.
@available(macOS 15.0, *)
private struct ModernTranslationTaskHost: View {
    let controller: TranslationController

    @State private var configuration: TranslationSession.Configuration?
    @State private var scheduledToken = 0
    @State private var pairSignature = ""

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .translationTask(configuration) { session in
                await run(session: session)
            }
            .onChange(of: controller.requestToken) { _, token in
                schedule(token)
            }
            .onAppear {
                if controller.requestToken > 0 { schedule(controller.requestToken) }
            }
    }

    /// Creates a configuration for a new language pair or reuses the previous one via `invalidate()`.
    private func schedule(_ token: Int) {
        guard token > scheduledToken else { return }
        scheduledToken = token
        let pair = "\(controller.sourceLanguageID)>\(controller.targetLanguageID)"
        let source = controller.sourceLanguageID.isEmpty
            ? nil
            : Locale.Language(identifier: controller.sourceLanguageID)
        let target = Locale.Language(identifier: controller.targetLanguageID)
        if configuration == nil || pair != pairSignature {
            pairSignature = pair
            configuration = TranslationSession.Configuration(source: source, target: target)
        } else {
            // Same language pair, new text — ask to translate again.
            configuration?.invalidate()
        }
    }

    private func run(session: TranslationSession) async {
        let text = await MainActor.run { controller.sourceText }
        guard !text.isEmpty else { return }
        do {
            let response = try await session.translate(text)
            let translated = response.targetText
            await MainActor.run { controller.complete(translated) }
        } catch {
            await MainActor.run { controller.fail(error) }
        }
    }
}
#else
@available(macOS 15.0, *)
private struct ModernTranslationTaskHost: View {
    let controller: TranslationController
    var body: some View { Color.clear.frame(width: 0, height: 0) }
}
#endif
