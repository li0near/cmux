/// One git-diff hunk inside a structured patch — the rendering shape
/// for an Edit / MultiEdit / Write-update result. Decodes directly
/// from Claude Code's JSONL `toolUseResult.structuredPatch[]` array,
/// which means the wire shape and the rendering shape are the same
/// type (no intermediate parser needed). The wire layer references
/// this Models type through ``ClaudeToolUseResult/structuredPatch``;
/// the layering bend mirrors the existing
/// ``ClaudeJSONLLine/attachment`` referencing ``ClaudeAttachment``.
///
/// Lines in ``lines`` are pre-prefixed by Claude Code: each entry
/// starts with one of `' '` (context), `'-'` (removed), or `'+'`
/// (added) followed by the line text. The renderer peeks at
/// ``Line/first`` to classify; ``classifyLine(_:)`` is the canonical
/// helper.
public struct DiffHunk: Decodable, Equatable, Sendable {
    /// 1-indexed first line of the pre-edit file represented by this
    /// hunk.
    public let oldStart: Int
    /// Number of pre-edit file lines covered (counts both context and
    /// removed lines).
    public let oldLines: Int
    /// 1-indexed first line of the post-edit file.
    public let newStart: Int
    /// Number of post-edit file lines covered (counts both context and
    /// added lines).
    public let newLines: Int
    /// Per-line entries in arrival order. Each line's first character
    /// is the diff prefix (` ` / `-` / `+`); use ``classifyLine(_:)``
    /// to split into kind + text.
    public let lines: [String]

    public init(
        oldStart: Int,
        oldLines: Int,
        newStart: Int,
        newLines: Int,
        lines: [String]
    ) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }

    /// One classified line: a kind (context / removed / added) plus
    /// the line text without its prefix character.
    public struct Line: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case context
            case removed
            case added
        }
        public let kind: Kind
        public let text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Classify a prefix-embedded line. `' '` → `.context`, `'-'` →
    /// `.removed`, `'+'` → `.added`. Defensive fallback for unprefixed
    /// or empty lines: treats them as context with the full text
    /// preserved (unobserved in the corpus, but cheap insurance).
    public static func classifyLine(_ line: String) -> Line {
        guard let first = line.first else {
            return Line(kind: .context, text: "")
        }
        switch first {
        case "-": return Line(kind: .removed, text: String(line.dropFirst()))
        case "+": return Line(kind: .added, text: String(line.dropFirst()))
        case " ": return Line(kind: .context, text: String(line.dropFirst()))
        default:  return Line(kind: .context, text: line)
        }
    }
}
