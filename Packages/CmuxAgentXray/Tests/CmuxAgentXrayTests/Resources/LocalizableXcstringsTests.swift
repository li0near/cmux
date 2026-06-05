import Foundation
import Testing
@testable import CmuxAgentXray

/// Localization sanity tests. Note: under `swift test` the xcstrings
/// file is shipped raw (Apple's xcstringstool is not invoked by SwiftPM),
/// so `String(localized:bundle:.module)` lookups fall through to the
/// Swift-source defaultValue. Real lookup against the compiled bundle
/// happens once the cmux app target builds via Xcode (Phase 9).
@Suite("CmuxAgentXray Localizable.xcstrings presence")
struct LocalizableXcstringsTests {

    /// The xcstrings file must be shipped in the resource bundle even
    /// if SwiftPM doesn't compile it. Validates the resource pipeline
    /// is wired up.
    @Test("xcstrings ships in Bundle.module")
    func xcstringsShippedInBundle() throws {
        let url = Bundle.module.url(
            forResource: "Localizable",
            withExtension: "xcstrings"
        )
        try #require(url != nil, "Localizable.xcstrings missing from Bundle.module")
    }

    /// The xcstrings JSON must contain the kind-specific agent label
    /// keys introduced in Phase 11 (split from the colliding
    /// `agentXray.entry.agent.label`). Reads the raw JSON since SwiftPM
    /// doesn't compile xcstrings under `swift test`.
    @Test("Agent label keys are kind-specific in xcstrings")
    func agentLabelsKindSpecificInXcstrings() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings")
        )
        let data = try Data(contentsOf: url)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        #expect(strings["agentXray.entry.agent.label.claude"] != nil)
        #expect(strings["agentXray.entry.agent.label.codex"] != nil)
        #expect(
            strings["agentXray.entry.agent.label"] == nil,
            "Legacy colliding key must be removed; split into .claude and .codex"
        )
    }
}
