import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies the friendly-name parser for Anthropic model ids. Mirrors the
/// behaviour of `claude-devtools/src/renderer/utils/modelParser.ts:34-137`.
final class ClaudeModelNameMapTests: XCTestCase {

    func testNewFormatSonnet45() {
        XCTAssertEqual(
            ClaudeModelNameMap.friendlyName(for: "claude-sonnet-4-5-20250929"),
            "Sonnet 4.5"
        )
    }

    func testNewFormatOpus47() {
        XCTAssertEqual(
            ClaudeModelNameMap.friendlyName(for: "claude-opus-4-7"),
            "Opus 4.7"
        )
    }

    func testNewFormatHaiku45() {
        XCTAssertEqual(
            ClaudeModelNameMap.friendlyName(for: "claude-haiku-4-5-20251001"),
            "Haiku 4.5"
        )
    }

    func testLegacyFormatSonnet35() {
        XCTAssertEqual(
            ClaudeModelNameMap.friendlyName(for: "claude-3-5-sonnet-20241022"),
            "Sonnet 3.5"
        )
    }

    func testLegacyFormatOpus3() {
        XCTAssertEqual(
            ClaudeModelNameMap.friendlyName(for: "claude-3-opus-20240229"),
            "Opus 3"
        )
    }

    func testNonClaudeIdReturnsRaw() {
        // Codex / opencode model ids etc. — round-trip rather than nil so
        // the renderer still shows something useful in the header.
        XCTAssertEqual(
            ClaudeModelNameMap.friendlyName(for: "gpt-5.1"),
            "gpt-5.1"
        )
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ClaudeModelNameMap.friendlyName(for: ""))
        XCTAssertNil(ClaudeModelNameMap.friendlyName(for: "   "))
    }

    func testUnknownFamilyReturnsNil() {
        // `claude-sparkle-1-0` — sparkle is not a known family.
        XCTAssertNil(ClaudeModelNameMap.friendlyName(for: "claude-sparkle-1-0"))
    }

    func testCaseInsensitiveFamily() {
        XCTAssertEqual(
            ClaudeModelNameMap.friendlyName(for: "Claude-Sonnet-4-5"),
            "Sonnet 4.5"
        )
    }
}
