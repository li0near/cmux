import AppKit
import SwiftUI

/// One inline row in a code-shaped body section, projected by
/// ``CodeBlockView`` from a ``Section/code(_:)`` payload.
///
/// `.hunkHeader` rows carry the `@@ -X,Y +A,B @@` separator text and
/// don't count against the cap's line-row budget. `.line` rows carry
/// classified line content (per-line foreground picked from
/// ``CodeRow/Classification``) plus an optional line number for the
/// inline prefix.
struct CodeRow: Equatable, Sendable {
    enum Classification: Equatable, Sendable {
        /// Read-tool file content — neutral row, code text in primary.
        case plain
        /// Diff context line — code text in primary.
        case context
        /// Diff added line — code text in green.
        case added
        /// Diff removed line — code text in red.
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

extension Array where Element == DiffHunk {
    /// Project `[DiffHunk]` (Claude Code's
    /// `toolUseResult.structuredPatch` shape) into a flat `[CodeRow]`
    /// stream consumed by ``CodeBlockView``. Per-hunk emission:
    /// 1. One `.hunkHeader` row carrying `"@@ -X,Y +A,B @@"`.
    /// 2. One `.line` row per `hunk.lines` entry, line number picked
    ///    via `newNo ?? oldNo` so trailing context after an edit shows
    ///    the NEW file's position (Claude TUI / git `--unified`
    ///    convention).
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

/// Flat row renderer for ``Section/code(_:)`` — paints both plain code
/// (Read tool result body) and structured diff (Edit / MultiEdit /
/// Write-update from `toolUseResult.structuredPatch`) as monospace
/// rows inside one ``HudPalette/expandedBackground`` gray textbox,
/// matching every other text section in the body.
///
/// **No syntax highlighting, no per-row colored backgrounds, no
/// separate gutter column.** Each `.line` row is one
/// `Text(AttributedString)` composed of a dim line-number prefix + the
/// classification glyph + the code text colored per classification:
/// green `+` for added, red `-` for removed, dim ` ` for context /
/// plain. Hunk-header rows render as a separate dim full-width
/// `@@ -X,Y +A,B @@` row.
///
/// Cap policy mirrors ``RenderCaps/standard`` — at most 30 inline line
/// rows (hunk-header rows excluded from the count) and 3 KiB of
/// joined line text. When either threshold trips, the view shows the
/// leading rows up to the cap and emits an ``OpenDetailLinkView`` for
/// the remainder; the detail tab serializes the full content.
@available(macOS 15, *)
struct CodeBlockView: View {

    let content: CodeContent
    let palette: HudPalette
    let onOpenDetail: () -> Void

    var body: some View {
        let cap = computeCap(rows: rowsFor(content: content))
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(cap.visibleRows.enumerated()), id: \.offset) { _, row in
                    rowView(row, maxDigits: cap.maxLineNumberDigits)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Padding.expandedBodyBlock)
            .background(Rectangle().fill(palette.expandedBackground))
            if cap.overflow {
                OpenDetailLinkView(
                    totalLines: cap.totalLines,
                    palette: palette,
                    action: onOpenDetail
                )
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Project a `CodeContent` into the flat row stream the renderer
    /// consumes. Plain code: split text by `\n`, line numbers
    /// `lineNumberStart..N`, classification = `.plain`. Diff code:
    /// delegate to ``Array/toCodeRows()``.
    private func rowsFor(content: CodeContent) -> [CodeRow] {
        switch content {
        case .plain(let text, let lineNumberStart):
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.enumerated().map { idx, slice in
                CodeRow(kind: .line(
                    text: String(slice),
                    lineNumber: lineNumberStart + idx,
                    classification: .plain
                ))
            }
        case .diff(let hunks):
            return hunks.toCodeRows()
        }
    }

    @ViewBuilder
    private func rowView(_ row: CodeRow, maxDigits: Int) -> some View {
        switch row.kind {
        case .hunkHeader(let text):
            Text(text)
                .font(Theme.Entry.title)
                .foregroundStyle(palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .line(let text, let lineNumber, let classification):
            Text(rowAttributedString(
                text: text,
                lineNumber: lineNumber,
                classification: classification,
                maxDigits: maxDigits
            ))
            .font(Theme.Entry.title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    /// Compose one row as an `AttributedString`. For `.plain` /
    /// `.context` rows the leading line-number prefix renders dim and
    /// the code text renders primary; for `.added` / `.removed` rows
    /// the entire row (line number + glyph + code text) renders in the
    /// classification color so the diff color extends the full width.
    private func rowAttributedString(
        text: String,
        lineNumber: Int?,
        classification: CodeRow.Classification,
        maxDigits: Int
    ) -> AttributedString {
        let lineNumFg: Color
        let codeFg: Color
        let glyph: String
        switch classification {
        case .plain, .context:
            lineNumFg = palette.dim
            codeFg = palette.primary.opacity(0.85)
            glyph = " "
        case .added:
            lineNumFg = palette.green
            codeFg = palette.green
            glyph = "+"
        case .removed:
            lineNumFg = palette.red
            codeFg = palette.red
            glyph = "-"
        }

        var prefix = AttributedString(formatLineNumber(lineNumber, width: maxDigits) + " ")
        prefix.foregroundColor = lineNumFg
        var glyphSpan = AttributedString("\(glyph) ")
        glyphSpan.foregroundColor = codeFg
        var codeSpan = AttributedString(text)
        codeSpan.foregroundColor = codeFg
        var out = AttributedString()
        out.append(prefix)
        out.append(glyphSpan)
        out.append(codeSpan)
        return out
    }

    /// Right-aligned, blank-padded to `width` so every row's number
    /// column is identical pixel width (font is monospaced).
    private func formatLineNumber(_ n: Int?, width: Int) -> String {
        let padded = n.map { String($0) } ?? ""
        return String(repeating: " ", count: max(0, width - padded.count)) + padded
    }

    // MARK: - Cap

    private struct CapResult {
        let visibleRows: [CodeRow]
        let overflow: Bool
        let totalLines: Int
        let maxLineNumberDigits: Int
    }

    /// Truncate the projected row stream to the inline cap. The
    /// 30-line / 3-KiB threshold mirrors ``RenderCaps/standard``;
    /// hunk-header rows are kept along with their following lines
    /// (they don't contribute to the line count or byte budget).
    private func computeCap(rows: [CodeRow]) -> CapResult {
        let lineCap = 30
        let byteCap = 3 * 1024
        var totalLineCount = 0
        var totalBytes = 0
        for row in rows {
            if case .line(let text, _, _) = row.kind {
                totalLineCount += 1
                totalBytes += text.utf8.count
            }
        }
        let overflow = totalLineCount > lineCap || totalBytes > byteCap
        let visible: [CodeRow]
        if !overflow {
            visible = rows
        } else {
            var v: [CodeRow] = []
            var c = 0
            var b = 0
            for row in rows {
                switch row.kind {
                case .hunkHeader:
                    v.append(row)
                case .line(let text, _, _):
                    if c >= lineCap || b >= byteCap { break }
                    v.append(row)
                    c += 1
                    b += text.utf8.count
                }
                if c >= lineCap || b >= byteCap { break }
            }
            visible = v
        }
        // Compute the gutter's column width from VISIBLE rows only —
        // a Read of a 200-line file with cap at row 30 should size
        // the prefix to fit the largest visible number, not the
        // off-screen file's last line.
        var maxLineNumber = 0
        for row in visible {
            if case .line(_, let lineNumber, _) = row.kind, let n = lineNumber {
                maxLineNumber = max(maxLineNumber, n)
            }
        }
        let maxDigits = max(1, String(maxLineNumber).count)
        return CapResult(
            visibleRows: visible,
            overflow: overflow,
            totalLines: totalLineCount,
            maxLineNumberDigits: maxDigits
        )
    }
}
