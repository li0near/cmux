import Foundation
@testable import CmuxAgentXray

/// Loads JSONL fixture files from the test bundle's `Resources/Fixtures/`
/// directory and decodes them into ``ClaudeJSONLLine`` values for tests.
///
/// Fixtures are real (or trimmed-real) JSONL excerpts named by scenario,
/// e.g. `edit-tool-result-with-patch.jsonl`. Each fixture is one or
/// more JSONL lines. Use ``line(named:lineIndex:)`` to grab a single
/// line by index, or ``lines(named:)`` to pull the whole file as an
/// array.
///
/// Scope: meant for raw real-corpus-shaped fixtures whose value comes
/// from realism (Edit's `toolUseResult` envelope, full-file JSONL
/// excerpts, edge-case shapes from the corpus). Templated test
/// fixtures that interpolate per-call parameters — e.g. the
/// `make...Line(uuid:parentUuid:...)` helpers in
/// `ClaudeTranscriptBuilderTests` — stay inline; fixture files can't
/// substitute parameters.
enum JSONLFixture {

    /// Decode a single JSONL line at `lineIndex` from the fixture
    /// `<name>.jsonl` in the test bundle's `Resources/Fixtures/`.
    /// Throws ``Error/fixtureNotFound`` if the file is missing,
    /// ``Error/lineOutOfRange`` if `lineIndex` exceeds the file's
    /// line count, or any decode error from `AgentXrayJSON.decoder`.
    static func line(
        named name: String,
        lineIndex: Int = 0
    ) throws -> ClaudeJSONLLine {
        let allLines = try rawLines(named: name)
        guard lineIndex >= 0, lineIndex < allLines.count else {
            throw Error.lineOutOfRange(name: name, requested: lineIndex, available: allLines.count)
        }
        return try AgentXrayJSON.decoder.decode(
            ClaudeJSONLLine.self,
            from: Data(allLines[lineIndex].utf8)
        )
    }

    /// Decode every JSONL line in the fixture file.
    static func lines(named name: String) throws -> [ClaudeJSONLLine] {
        try rawLines(named: name).map {
            try AgentXrayJSON.decoder.decode(
                ClaudeJSONLLine.self,
                from: Data($0.utf8)
            )
        }
    }

    /// Read fixture file content as a list of non-empty lines (each a
    /// JSON object). Whitespace-only lines are dropped so fixtures can
    /// have trailing newlines or interspersed blanks for readability.
    private static func rawLines(named name: String) throws -> [String] {
        // SPM `.process("Resources/Fixtures")` flattens the directory
        // contents into the bundle root, so `Bundle.module.url(...)`
        // resolves the fixture by basename without a subdirectory hint.
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "jsonl"
        ) else {
            throw Error.fixtureNotFound(name: name)
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case fixtureNotFound(name: String)
        case lineOutOfRange(name: String, requested: Int, available: Int)

        var description: String {
            switch self {
            case .fixtureNotFound(let name):
                return "JSONL fixture not found: Resources/Fixtures/\(name).jsonl"
            case .lineOutOfRange(let name, let requested, let available):
                return "JSONL fixture \(name).jsonl has \(available) lines; requested index \(requested)"
            }
        }
    }
}
