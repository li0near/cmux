import SwiftUI

/// One inline row in a code-shaped body section, projected by
/// ``CodeBlockView`` from a ``Section/code(_:)`` payload.
///
/// `.hunkHeader` rows carry the `@@ -X,Y +A,B @@` separator text and
/// don't count against the cap's line-row budget. `.line` rows carry
/// classified line content (per-line bg picked from
/// ``CodeRow/Classification``) plus an optional line number for the
/// gutter (nil for the rare wrap continuation cases).
///
/// Plain code rows (Read-tool file content) classify as `.plain`;
/// diff rows classify per the hunk's `' '`/`-`/`+` prefix.
struct CodeRow: Equatable, Sendable {
    enum Classification: Equatable, Sendable {
        /// Read-tool file content — neutral row, no glyph, gutter gets
        /// the standard expanded-body gray bg.
        case plain
        /// Diff context line — gutter gets gray, code area transparent.
        case context
        /// Diff added line — full-row green tint.
        case added
        /// Diff removed line — full-row red tint.
        case removed
    }

    enum Kind: Equatable, Sendable {
        /// Hunk separator (only emitted for diff content). Renders as
        /// dim monospace; doesn't increment the cap's line counter.
        case hunkHeader(String)
        /// Code line. `lineNumber` is nil only for unprefixed-line
        /// edge cases (defensive; unobserved in the corpus today).
        case line(text: String, lineNumber: Int?, classification: Classification)
    }

    let kind: Kind
}

// `CodeBlockView` lands in commit 3 of the H-rev sequence. Until then,
// the inline diff renderer (`DiffHunkView`) consumes the new
// `Section.code(.diff)` payload directly via `cappedBody`'s shim arm.
