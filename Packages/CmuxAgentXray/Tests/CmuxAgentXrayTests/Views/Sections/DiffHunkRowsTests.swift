import Testing
@testable import CmuxAgentXray

/// Tests `[DiffHunk].toCodeRows()` — the pure projection from JSONL
/// `toolUseResult.structuredPatch` shape into a flat `[CodeRow]`
/// stream. Verifies header emission, classification per line prefix,
/// and the `newNo ?? oldNo` line-number rule that surfaces the
/// post-edit (new-file) position for context + added rows while
/// keeping the old-file position for removed rows.
@Suite("DiffHunk → CodeRow projection")
struct DiffHunkRowsTests {

    @available(macOS 15, *)
    @Test("empty input returns empty rows")
    func emptyInput() {
        let rows: [DiffHunk] = []
        #expect(rows.toCodeRows().isEmpty)
    }

    @available(macOS 15, *)
    @Test("each hunk emits one header row + one row per line")
    func headerPerHunk() {
        let hunk = DiffHunk(
            oldStart: 1, oldLines: 2,
            newStart: 1, newLines: 2,
            lines: [" a", " b"]
        )
        let rows = [hunk].toCodeRows()
        #expect(rows.count == 3)
        if case .hunkHeader(let text) = rows[0].kind {
            #expect(text == "@@ -1,2 +1,2 @@")
        } else {
            Issue.record("Expected .hunkHeader at index 0")
        }
    }

    @available(macOS 15, *)
    @Test("classification matches line prefix; line number uses newNo ?? oldNo")
    func classificationAndNumbering() {
        // Hunk: 3 leading context, 2 removed, 1 added, 1 trailing context.
        // Old: 10..15 (6 lines), New: 10..14 (5 lines).
        let hunk = DiffHunk(
            oldStart: 10, oldLines: 6,
            newStart: 10, newLines: 5,
            lines: [
                " context-a",
                " context-b",
                " context-c",
                "-removed-1",
                "-removed-2",
                "+added",
                " trailing"
            ]
        )
        let rows = [hunk].toCodeRows()
        // 1 header + 7 lines = 8 rows.
        #expect(rows.count == 8)

        // Verify per-line classification + line numbers.
        let expected: [(CodeRow.Classification, Int?)] = [
            (.context, 10),    // newOffset=10, oldOffset=10 → display new=10
            (.context, 11),
            (.context, 12),
            (.removed, 13),    // newNo=nil → falls to oldNo=13
            (.removed, 14),
            (.added,   13),    // oldNo=nil, newNo=13
            (.context, 14),    // trailing context: oldNo=15, newNo=14 → newNo wins
        ]
        for (offset, (cls, num)) in expected.enumerated() {
            let row = rows[offset + 1]
            guard case .line(_, let lineNumber, let classification) = row.kind else {
                Issue.record("Expected .line at index \(offset + 1)")
                continue
            }
            #expect(classification == cls, "row \(offset): classification mismatch")
            #expect(lineNumber == num, "row \(offset): expected lineNumber \(String(describing: num)), got \(String(describing: lineNumber))")
        }
    }

    @available(macOS 15, *)
    @Test("multiple hunks each get their own header")
    func multipleHunks() {
        let hunkA = DiffHunk(
            oldStart: 1, oldLines: 1, newStart: 1, newLines: 1,
            lines: [" x"]
        )
        let hunkB = DiffHunk(
            oldStart: 100, oldLines: 1, newStart: 100, newLines: 1,
            lines: [" y"]
        )
        let rows = [hunkA, hunkB].toCodeRows()
        // 2 headers + 2 lines = 4 rows.
        #expect(rows.count == 4)
        if case .hunkHeader(let h0) = rows[0].kind {
            #expect(h0 == "@@ -1,1 +1,1 @@")
        } else {
            Issue.record("rows[0] should be header")
        }
        if case .hunkHeader(let h1) = rows[2].kind {
            #expect(h1 == "@@ -100,1 +100,1 @@")
        } else {
            Issue.record("rows[2] should be header")
        }
    }
}
