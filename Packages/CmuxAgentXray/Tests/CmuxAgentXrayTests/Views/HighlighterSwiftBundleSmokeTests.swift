import AppKit
import Testing
@testable import CmuxAgentXray

/// Spike-only smoke test: verify HighlighterSwift's bundled JS / theme
/// resources are reachable when consumed transitively through this
/// package. If `Highlighter()` returns nil here, the SPM resource
/// pipeline is the blocker (and the `print` line will show why).
@Suite("HighlighterSwift bundle smoke")
struct HighlighterSwiftBundleSmokeTests {

    @available(macOS 15, *)
    @Test("SyntaxHighlight returns a non-nil AttributedString for swift code")
    func highlightsSwiftSnippet() async {
        // Run on MainActor since the helper is annotated.
        let attr = await MainActor.run {
            SyntaxHighlight.attributed(
                "let x = 42",
                language: "swift",
                font: .systemFont(ofSize: 12),
                colorScheme: .dark
            )
        }
        #expect(attr != nil, "Highlighter init or highlight() returned nil — bundle resources may not reach the package consumer")
    }
}
