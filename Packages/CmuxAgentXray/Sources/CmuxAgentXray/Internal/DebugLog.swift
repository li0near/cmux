/// Lightweight package-internal debug log. Wraps `print` in `#if DEBUG`
/// so release builds elide the message and any string interpolation.
///
/// The cmux app target has its own `cmuxDebugLog` ring buffer + file
/// log. The package can't reach into the app target, so any log calls
/// inside `Packages/CmuxAgentXray/` route through this helper instead.
/// Future improvement: route through `os.Logger` with a stable
/// subsystem id so Console.app filters work cleanly.
@inlinable
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[CmuxAgentXray] \(message())")
    #endif
}
