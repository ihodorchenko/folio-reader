import Foundation

/// Single logging entry point for the UI layer.
/// Acceptance runs need to see that the "force click → dictionary" path really fires,
/// so all key events go through NSLog (visible in Console/stderr).
func folioLog(_ message: @autoclosure () -> String) {
    NSLog("%@", "[Folio] \(message())" as NSString)
}
