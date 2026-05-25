import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-data tests for `ClaudeContentDetector.classify(_:)`.
final class ClaudeContentDetectorTests: XCTestCase {

    func testSlashCommandInputBuiltInOrdering() {
        let result = ClaudeContentDetector.classify(
            "<command-name>/model</command-name>\n<command-args>sonnet</command-args>"
        )
        guard case let .slashCommandInput(name, args) = result else {
            return XCTFail("expected .slashCommandInput, got \(result)")
        }
        XCTAssertEqual(name, "model")
        XCTAssertEqual(args, "sonnet")
    }

    func testSlashCommandInputSkillOrdering() {
        let result = ClaudeContentDetector.classify(
            "<command-message>browse-url</command-message>\n<command-name>/browse-url</command-name>"
        )
        guard case let .slashCommandInput(name, args) = result else {
            return XCTFail("expected .slashCommandInput, got \(result)")
        }
        XCTAssertEqual(name, "browse-url")
        XCTAssertNil(args)
    }

    func testSlashCommandStdout() {
        let result = ClaudeContentDetector.classify(
            "<local-command-stdout>Set model to sonnet</local-command-stdout>"
        )
        guard case let .slashCommandOutput(body, isStderr) = result else {
            return XCTFail("expected .slashCommandOutput, got \(result)")
        }
        XCTAssertEqual(body, "Set model to sonnet")
        XCTAssertFalse(isStderr)
    }

    func testSlashCommandStderr() {
        let result = ClaudeContentDetector.classify(
            "<local-command-stderr>oops</local-command-stderr>"
        )
        guard case let .slashCommandOutput(_, isStderr) = result else {
            return XCTFail("expected .slashCommandOutput, got \(result)")
        }
        XCTAssertTrue(isStderr)
    }

    func testLocalCommandCaveat() {
        let result = ClaudeContentDetector.classify(
            "<local-command-caveat>Caveat: messages below were generated.</local-command-caveat>"
        )
        guard case let .localCommandCaveat(body) = result else {
            return XCTFail("expected .localCommandCaveat, got \(result)")
        }
        XCTAssertEqual(body, "Caveat: messages below were generated.")
    }

    func testSystemReminder() {
        let result = ClaudeContentDetector.classify(
            "<system-reminder>\nThe user named this session \"X\".\n</system-reminder>"
        )
        guard case let .systemReminder(body) = result else {
            return XCTFail("expected .systemReminder, got \(result)")
        }
        XCTAssertTrue(body.contains("X"))
    }

    func testSkillInvocationParsesNameAndBasePath() {
        let result = ClaudeContentDetector.classify(
            "Base directory for this skill: /home/user/.claude/skills/example\n\n# Example Skill\n\nBody text here."
        )
        guard case let .skillInvocation(name, basePath, body) = result else {
            return XCTFail("expected .skillInvocation, got \(result)")
        }
        XCTAssertEqual(name, "Example Skill")
        XCTAssertEqual(basePath, "/home/user/.claude/skills/example")
        XCTAssertTrue(body.contains("Body text here."))
    }

    func testContextUsage() {
        let result = ClaudeContentDetector.classify(
            "## Context Usage\n\n**Model:** claude-sonnet-4-5"
        )
        guard case .contextUsage = result else {
            return XCTFail("expected .contextUsage, got \(result)")
        }
    }

    func testContinueResume() {
        let result = ClaudeContentDetector.classify("Continue from where you left off.")
        XCTAssertEqual(result, .continueResume)
    }

    func testUnknownContentFallsThrough() {
        let result = ClaudeContentDetector.classify("just some freeform text")
        guard case let .unknown(body) = result else {
            return XCTFail("expected .unknown, got \(result)")
        }
        XCTAssertEqual(body, "just some freeform text")
    }
}
