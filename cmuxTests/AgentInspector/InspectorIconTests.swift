import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies the per-tool icon dispatch table. The table is purely declarative
/// (a switch statement) so these tests guard against accidental edits and
/// confirm fallback behaviour.
final class InspectorIconTests: XCTestCase {

    func testKnownTools() {
        XCTAssertEqual(InspectorIcon.tool(named: "Read").collapsed, "doc.text")
        XCTAssertEqual(InspectorIcon.tool(named: "Read").expanded, "doc.text.fill")

        XCTAssertEqual(InspectorIcon.tool(named: "Bash").collapsed, "apple.terminal")
        XCTAssertEqual(InspectorIcon.tool(named: "Bash").expanded, "apple.terminal.fill")

        XCTAssertEqual(InspectorIcon.tool(named: "Task").collapsed, "person.2")
        XCTAssertEqual(InspectorIcon.tool(named: "Task").expanded, "person.2.fill")
    }

    func testEditFamilySharesIcon() {
        // Edit / Write / MultiEdit all use the same pencil icon — confirms
        // the user-requested unification.
        let edit = InspectorIcon.tool(named: "Edit")
        let write = InspectorIcon.tool(named: "Write")
        let multi = InspectorIcon.tool(named: "MultiEdit")
        XCTAssertEqual(edit.collapsed, write.collapsed)
        XCTAssertEqual(edit.collapsed, multi.collapsed)
        XCTAssertEqual(edit.collapsed, "pencil.tip.crop.circle")
    }

    func testFallbackUsesWrench() {
        let unknown = InspectorIcon.tool(named: "ThisToolDoesNotExist")
        XCTAssertEqual(unknown.collapsed, "wrench.adjustable")
        XCTAssertEqual(unknown.expanded, "wrench.adjustable.fill")
    }

    func testSystemNameSwitchesByExpansion() {
        let pair = InspectorIcon.tool(named: "Read")
        XCTAssertEqual(pair.systemName(expanded: false), "doc.text")
        XCTAssertEqual(pair.systemName(expanded: true), "doc.text.fill")
    }

    func testKindIconsHaveFillVariants() {
        XCTAssertEqual(InspectorIcon.user.expanded, "person.fill")
        XCTAssertEqual(InspectorIcon.system.expanded, "terminal.fill")
        XCTAssertEqual(InspectorIcon.thinking.expanded, "brain.fill")
        XCTAssertEqual(InspectorIcon.ai.expanded, "microbe.fill")
    }
}
