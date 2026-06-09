import Foundation

/// One hunk-shape entry inside a ``ClaudeToolUseResult/structuredPatch``
/// array. Naming matches the wire JSON field (`structuredPatch`); each
/// element semantically represents one git-diff *hunk*, not a whole
/// patch — but the type carries the field name for grep-ability against
/// Claude Code's own source. The ``DiffHunk`` model type (in `Body.swift`)
/// is the rendering-shape sibling.
///
/// Lines in `lines` are pre-prefixed: each entry starts with one of
/// `' '` (context), `'-'` (removed), or `'+'` (added). The
/// ``EditResultParser`` strips that prefix when projecting to the model
/// type.
struct ClaudeStructuredPatch: Decodable, Equatable {
    /// 1-indexed first line of the pre-edit file represented by this hunk.
    let oldStart: Int
    /// Number of pre-edit file lines covered (counts both context and
    /// removed lines).
    let oldLines: Int
    /// 1-indexed first line of the post-edit file.
    let newStart: Int
    /// Number of post-edit file lines covered (counts both context and
    /// added lines).
    let newLines: Int
    /// Per-line entries in arrival order, each starting with `' '` /
    /// `'-'` / `'+'` followed by the line text.
    let lines: [String]
}
