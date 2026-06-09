import Foundation

/// Project `[DiffHunk]` (Claude Code's `toolUseResult.structuredPatch`
/// shape) into a flat `[CodeRow]` stream consumed by ``CodeBlockView``.
///
/// Per-hunk emission:
/// 1. One `.hunkHeader` row carrying `"@@ -X,Y +A,B @@"`.
/// 2. One `.line` row per `hunk.lines` entry, with line number picked
///    via `newNo ?? oldNo` so trailing context after an edit shows the
///    NEW file's position (Claude TUI / git's `--unified` convention —
///    matches the post-edit perspective the user reads against).
///
/// Pure value transform; no SwiftUI / AppKit deps. Lives in
/// `Views/Sections/` because its consumer is `CodeBlockView`, but it's
/// safe to move to Models if a non-view caller ever needs it.
extension Array where Element == DiffHunk {
    func toCodeRows() -> [CodeRow] {
        var rows: [CodeRow] = []
        for hunk in self {
            rows.append(.init(kind: .hunkHeader(
                "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@"
            )))
            var oldOffset = hunk.oldStart
            var newOffset = hunk.newStart
            for raw in hunk.lines {
                let line = DiffHunk.classifyLine(raw)
                let oldNo: Int?
                let newNo: Int?
                let classification: CodeRow.Classification
                switch line.kind {
                case .context:
                    oldNo = oldOffset
                    newNo = newOffset
                    classification = .context
                    oldOffset += 1
                    newOffset += 1
                case .removed:
                    oldNo = oldOffset
                    newNo = nil
                    classification = .removed
                    oldOffset += 1
                case .added:
                    oldNo = nil
                    newNo = newOffset
                    classification = .added
                    newOffset += 1
                }
                rows.append(.init(kind: .line(
                    text: line.text,
                    lineNumber: newNo ?? oldNo,
                    classification: classification
                )))
            }
        }
        return rows
    }
}
