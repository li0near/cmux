import Foundation

/// Internal accessor for the package's resource bundle. Exists so tests
/// running under `@testable import CmuxAgentXray` can resolve the
/// package's `Bundle.module` even when the test target itself has its
/// own resources (which would otherwise shadow the unqualified
/// `Bundle.module` reference at the test call site).
///
/// Production callers continue to use `Bundle.module` directly via
/// `String(localized:defaultValue:bundle:)`; this accessor is purely a
/// test-side seam.
internal enum CmuxAgentXrayResourceBundle {
    internal static var bundle: Bundle { .module }
}
