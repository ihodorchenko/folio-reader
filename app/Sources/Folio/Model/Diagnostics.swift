import Foundation

/// Единая точка логов UI-слоя.
/// В приёмке важно видеть, что путь «сильное нажатие → словарь» реально вызывается,
/// поэтому все ключевые события пишутся через NSLog (видны в Console/stderr).
func folioLog(_ message: @autoclosure () -> String) {
    NSLog("%@", "[Folio] \(message())" as NSString)
}
