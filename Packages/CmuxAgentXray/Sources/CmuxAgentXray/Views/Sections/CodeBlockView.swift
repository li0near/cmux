import AppKit
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

/// Unified renderer for ``Section/code(_:)`` — paints both plain code
/// (Read tool result body) and structured diff (Edit / MultiEdit /
/// Write-update from `toolUseResult.structuredPatch`) with a
/// line-number gutter, optional `+`/`-` prefix glyph, per-row
/// background tint by classification, and per-language syntax
/// highlighting via `SyntaxHighlight` (highlight.js).
///
/// Cap policy mirrors ``RenderCaps/standard`` — at most 30 inline line
/// rows (hunk-header rows excluded from the count) and 3 KiB of
/// joined line text. When either threshold trips, the view shows the
/// leading rows up to the cap and emits an ``OpenDetailLinkView`` for
/// the remainder; the detail tab serializes the full content
/// (`.diff` rebuilds unified-diff text; `.plain` opens the file's
/// basename via cmux's panel pipeline).
///
/// Lifecycle: stateless; pure render from `CodeContent`. Section
/// equality is structural per the custom ``Section/==(_:_:)`` so
/// SwiftUI re-renders only when content actually changes.
@available(macOS 15, *)
struct CodeBlockView: View {

    let content: CodeContent
    let palette: HudPalette
    let onOpenDetail: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let cap = computeCap(rows: rowsFor(content: content))
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(cap.visibleRows.enumerated()), id: \.offset) { _, row in
                    rowView(row, maxDigits: cap.maxLineNumberDigits)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
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
        case .plain(let text, _, let lineNumberStart):
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.enumerated().map { idx, slice in
                CodeRow(kind: .line(
                    text: String(slice),
                    lineNumber: lineNumberStart + idx,
                    classification: .plain
                ))
            }
        case .diff(let hunks, _):
            return hunks.toCodeRows()
        }
    }

    /// Language hint for `SyntaxHighlight.attributed(...)` — extracted
    /// from whichever `CodeContent` arm we got.
    private var language: String? {
        switch content {
        case .plain(_, let lang, _), .diff(_, let lang):
            return lang
        }
    }

    @ViewBuilder
    private func rowView(_ row: CodeRow, maxDigits: Int) -> some View {
        switch row.kind {
        case .hunkHeader(let text):
            Text(text)
                .font(Theme.SubRow.title)
                .foregroundStyle(palette.dim)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .line(let text, let lineNumber, let classification):
            let style = lineStyle(for: classification)
            HStack(alignment: .top, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(formatLineNumber(lineNumber, width: maxDigits))
                        .font(Theme.SubRow.title)
                        .foregroundStyle(style.gutterFg)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.trailing, 6)
                    Text(style.glyph)
                        .font(Theme.SubRow.title)
                        .foregroundStyle(style.gutterFg)
                        .frame(width: 12, alignment: .center)
                }
                .padding(.leading, 6)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Rectangle().fill(style.gutterBg))
                Text(highlightedText(text))
                    .font(Theme.SubRow.title)
                    .textSelection(.enabled)
                    .padding(.leading, 6)
                    .padding(.trailing, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Rectangle().fill(style.codeBg))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Per-classification styling

    /// All four per-row visual fields for one classification, picked
    /// in a single switch so the renderer doesn't dispatch four times
    /// per row. `.plain` (Read content) and `.context` (diff context
    /// rows) share the same styling — neutral row, gray gutter — and
    /// their distinction is preserved only because the projection
    /// layer cares about it (e.g. for future per-classification
    /// behavior tweaks).
    private struct LineStyle {
        let codeBg: Color
        let gutterBg: Color
        let gutterFg: Color
        let glyph: String
    }

    private func lineStyle(for classification: CodeRow.Classification) -> LineStyle {
        switch classification {
        case .plain, .context:
            return LineStyle(
                codeBg: .clear,
                gutterBg: palette.expandedBackground,
                gutterFg: palette.dim,
                glyph: " "
            )
        case .added:
            let bg = palette.diffAddedBackground(colorScheme: colorScheme)
            return LineStyle(
                codeBg: bg,
                gutterBg: bg,
                gutterFg: palette.green,
                glyph: "+"
            )
        case .removed:
            let bg = palette.diffRemovedBackground(colorScheme: colorScheme)
            return LineStyle(
                codeBg: bg,
                gutterBg: bg,
                gutterFg: palette.red,
                glyph: "-"
            )
        }
    }

    // MARK: - Text rendering helpers

    /// Right-aligned, blank-padded to `width` so every row's number
    /// column is identical pixel width (font is monospaced).
    private func formatLineNumber(_ n: Int?, width: Int) -> String {
        let padded = n.map { String($0) } ?? ""
        return String(repeating: " ", count: max(0, width - padded.count)) + padded
    }

    /// Try to syntax-highlight the line text against the section's
    /// language hint. Falls back to plain text when language is unknown
    /// or the highlighter rejects the input. ZWSP injection layered on
    /// top to keep char-level wrap (SwiftUI Text's word-wrap engine
    /// silently drops the `NSParagraphStyle.lineBreakMode =
    /// .byCharWrapping` paragraph attribute when bridged through
    /// `AttributedString`; ZWSP is the only working approach).
    private func highlightedText(_ text: String) -> AttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        if let attr = SyntaxHighlight.attributed(
            text,
            language: language,
            font: font,
            colorScheme: colorScheme
        ) {
            return charWrap(attr)
        }
        return charWrap(AttributedString(text))
    }

    /// Insert a ZWSP between every character of an `AttributedString`,
    /// preserving each character's foreground attribute. Slow but
    /// called per visible row only.
    private func charWrap(_ attr: AttributedString) -> AttributedString {
        var out = AttributedString()
        var first = true
        for run in attr.runs {
            for ch in attr[run.range].characters {
                if !first {
                    var sep = AttributedString("\u{200B}")
                    if let fg = run.foregroundColor { sep.foregroundColor = fg }
                    out.append(sep)
                }
                first = false
                var single = AttributedString(String(ch))
                if let fg = run.foregroundColor { single.foregroundColor = fg }
                out.append(single)
            }
        }
        return out
    }

    // MARK: - Cap

    private struct CapResult {
        let visibleRows: [CodeRow]
        let overflow: Bool
        let totalLines: Int
        let maxLineNumberDigits: Int
    }

    /// Truncate the projected row stream to the inline cap. The
    /// 30-line / 3-KiB threshold mirrors ``RenderCaps/standard``; the
    /// cache layer treats `.code` as `.empty` so this view owns the
    /// cap decision at render time. Hunk-header rows are kept along
    /// with their following lines (they don't contribute to the line
    /// count or byte budget).
    private func computeCap(rows: [CodeRow]) -> CapResult {
        let lineCap = 30
        let byteCap = 3 * 1024
        var lineRowCount = 0
        var totalBytes = 0
        var maxLineNumber = 0
        for row in rows {
            switch row.kind {
            case .hunkHeader: continue
            case .line(let text, let lineNumber, _):
                lineRowCount += 1
                totalBytes += text.utf8.count
                if let n = lineNumber {
                    maxLineNumber = max(maxLineNumber, n)
                }
            }
        }
        let maxDigits = max(1, String(maxLineNumber).count)
        let overflow = lineRowCount > lineCap || totalBytes > byteCap
        if !overflow {
            return CapResult(
                visibleRows: rows,
                overflow: false,
                totalLines: lineRowCount,
                maxLineNumberDigits: maxDigits
            )
        }
        var visible: [CodeRow] = []
        var visibleLineCount = 0
        var visibleBytes = 0
        for row in rows {
            switch row.kind {
            case .hunkHeader:
                visible.append(row)
            case .line(let text, _, _):
                if visibleLineCount >= lineCap || visibleBytes >= byteCap { break }
                visible.append(row)
                visibleLineCount += 1
                visibleBytes += text.utf8.count
            }
            if visibleLineCount >= lineCap || visibleBytes >= byteCap { break }
        }
        return CapResult(
            visibleRows: visible,
            overflow: true,
            totalLines: lineRowCount,
            maxLineNumberDigits: maxDigits
        )
    }
}
