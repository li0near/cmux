import SwiftUI

/// Inline renderer for ``Section/diffHunks(_:)`` — paints a row's
/// pre-computed unified diff (from
/// `toolUseResult.structuredPatch[]`) with line-number gutters,
/// per-line prefix glyph, and full-width per-line background colors
/// (red for removed, green for added, transparent for context).
/// Each hunk is preceded by its `@@ -X,Y +A,B @@` header line in
/// dim monospace.
///
/// Cap policy mirrors ``RenderCaps/standard`` — at most 30 inline
/// rows (header + lines counted together) and 3 KiB of joined line
/// text. When either threshold trips, the view shows the leading
/// rows up to the cap and emits an ``OpenDetailLinkView`` for the
/// remainder; the detail tab serializes the full hunk array back to
/// a fenced ` ```diff ` markdown body.
///
/// Lifecycle: stateless; pure render from `[DiffHunk]`. Hunks are
/// immutable per builder pass, so SwiftUI re-renders only when
/// `Section.==` returns false (which the custom `.diffHunks` arm
/// gates by hunk count + per-hunk header tuple + line count, not a
/// deep walk).
@available(macOS 15, *)
struct DiffHunkView: View {

    let hunks: [DiffHunk]
    let palette: HudPalette
    let language: String?
    let onOpenDetail: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let cap = computeCap(hunks: hunks)
        let maxDigits = cap.maxLineNumberDigits
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(cap.visibleRows.enumerated()), id: \.offset) { _, row in
                    rowView(row, maxDigits: maxDigits)
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

    @ViewBuilder
    private func rowView(_ row: Row, maxDigits: Int) -> some View {
        switch row {
        case .header(let hunk):
            Text(hunkHeaderText(hunk))
                .font(Theme.SubRow.title)
                .foregroundStyle(palette.dim)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .line(let line, let oldNo, let newNo):
            let codeBg = lineBackground(for: line.kind)
            let gutterBg = lineGutterBackground(for: line.kind)
            let gutterFg = lineGutterForeground(for: line.kind)
            // For `-` rows newNo is nil → falls back to oldNo. For `+`
            // and context rows we prefer newNo so the gutter shows the
            // post-edit (new file) position — matches Claude TUI and
            // git's `--unified` display, which is what users care about
            // when reviewing an edit's destination.
            let display = newNo ?? oldNo
            HStack(alignment: .top, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(formatLineNumber(display, width: maxDigits))
                        .font(Theme.SubRow.title)
                        .foregroundStyle(gutterFg)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.trailing, 6)
                    Text(prefixGlyph(for: line.kind))
                        .font(Theme.SubRow.title)
                        .foregroundStyle(gutterFg)
                        .frame(width: 12, alignment: .center)
                }
                .padding(.leading, 6)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Rectangle().fill(gutterBg))
                Text(highlightedText(line.text))
                    .font(Theme.SubRow.title)
                    .textSelection(.enabled)
                    .padding(.leading, 6)
                    .padding(.trailing, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Rectangle().fill(codeBg))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lineBackground(for kind: DiffHunk.Line.Kind) -> Color {
        switch kind {
        case .context: return .clear
        case .removed: return palette.diffRemovedBackground(colorScheme: colorScheme)
        case .added:   return palette.diffAddedBackground(colorScheme: colorScheme)
        }
    }

    /// Background for the line-number / prefix-glyph gutter. Context
    /// rows get the standard expanded-body gray (matches text-section
    /// gray-bg pattern); +/- rows match their full-row tint so the
    /// gutter blends into the change strip.
    private func lineGutterBackground(for kind: DiffHunk.Line.Kind) -> Color {
        switch kind {
        case .context: return palette.expandedBackground
        case .removed: return palette.diffRemovedBackground(colorScheme: colorScheme)
        case .added:   return palette.diffAddedBackground(colorScheme: colorScheme)
        }
    }

    /// Foreground for the line-number gutter and prefix glyph. Removed
    /// rows tint red, added rows tint green, context stays dim — mirrors
    /// Claude TUI's gutter coloring.
    private func lineGutterForeground(for kind: DiffHunk.Line.Kind) -> Color {
        switch kind {
        case .context: return palette.dim
        case .removed: return palette.red
        case .added:   return palette.green
        }
    }

    /// Inject a zero-width space (`\u{200B}`) between every character
    /// so SwiftUI's `Text` word-wrap engine — which has no
    /// public modifier to flip to character-wrap mode and silently
    /// drops `NSParagraphStyle.lineBreakMode = .byCharWrapping` when
    /// bridged through `AttributedString` — sees a break opportunity
    /// at every position. Long unbroken tokens like
    /// `Style::default().fg(theme::TEXT_SECONDARY)` then wrap at
    /// character boundaries instead of overflowing the row. ZWSP is
    /// invisible at render time and stripped by most paste targets.
    private func charWrappable(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text.map(String.init).joined(separator: "\u{200B}")
    }

    /// Try to syntax-highlight the line text against the section's
    /// `language` hint (carried on the `Section.code(.diff(...))`
    /// payload by the builder). Falls back to plain text when language
    /// is unknown or highlighter rejects the input. ZWSP injection is
    /// layered on top to keep char-level wrap.
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
    /// preserving each character's attributes (foreground color from
    /// highlight.js). Slow but called per visible row only.
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

    private func prefixGlyph(for kind: DiffHunk.Line.Kind) -> String {
        switch kind {
        case .context: return " "
        case .removed: return "-"
        case .added:   return "+"
        }
    }

    /// Right-aligned, blank-padded to `width` so every row's number
    /// column is identical pixel width (font is monospaced).
    private func formatLineNumber(_ n: Int?, width: Int) -> String {
        let padded = n.map { String($0) } ?? ""
        return String(repeating: " ", count: max(0, width - padded.count)) + padded
    }

    private func hunkHeaderText(_ hunk: DiffHunk) -> String {
        "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@"
    }

    // MARK: - Row projection + cap

    /// One inline row in the rendered diff. `.header` rows carry just
    /// the hunk-header text; `.line` rows carry a classified line plus
    /// its post-classification line numbers (nil for the side that
    /// doesn't apply — e.g. `oldNo` is nil on a `.added` line).
    private enum Row {
        case header(DiffHunk)
        case line(DiffHunk.Line, oldNo: Int?, newNo: Int?)
    }

    private struct CapResult {
        let visibleRows: [Row]
        let overflow: Bool
        let totalLines: Int
        let maxLineNumberDigits: Int
    }

    /// Project hunks into a flat list of rows (header + per-line) and
    /// truncate to the inline cap. The 30-row / 3-KiB threshold mirrors
    /// ``RenderCaps/standard``; the cache layer treats `.diffHunks` as
    /// `.empty` so this view owns the cap decision at render time.
    private func computeCap(hunks: [DiffHunk]) -> CapResult {
        var allRows: [Row] = []
        var totalBytes = 0
        var maxLineNumber = 0
        for hunk in hunks {
            allRows.append(.header(hunk))
            var oldOffset = hunk.oldStart
            var newOffset = hunk.newStart
            for raw in hunk.lines {
                let line = DiffHunk.classifyLine(raw)
                let oldNo: Int?
                let newNo: Int?
                switch line.kind {
                case .context:
                    oldNo = oldOffset
                    newNo = newOffset
                    oldOffset += 1
                    newOffset += 1
                case .removed:
                    oldNo = oldOffset
                    newNo = nil
                    oldOffset += 1
                case .added:
                    oldNo = nil
                    newNo = newOffset
                    newOffset += 1
                }
                if let n = oldNo { maxLineNumber = max(maxLineNumber, n) }
                if let n = newNo { maxLineNumber = max(maxLineNumber, n) }
                allRows.append(.line(line, oldNo: oldNo, newNo: newNo))
                totalBytes += line.text.utf8.count
            }
        }
        let maxDigits = max(1, String(maxLineNumber).count)
        let lineRowCount = allRows.reduce(0) { count, row in
            if case .line = row { return count + 1 }
            return count
        }
        let lineCap = 30
        let byteCap = 3 * 1024
        let overByLines = lineRowCount > lineCap
        let overByBytes = totalBytes > byteCap
        let overflow = overByLines || overByBytes
        if !overflow {
            return CapResult(
                visibleRows: allRows,
                overflow: false,
                totalLines: lineRowCount,
                maxLineNumberDigits: maxDigits
            )
        }
        // Truncate to first N line rows (keep their preceding header).
        var visible: [Row] = []
        var visibleLineCount = 0
        var visibleBytes = 0
        for row in allRows {
            switch row {
            case .header:
                visible.append(row)
            case .line(let line, _, _):
                if visibleLineCount >= lineCap || visibleBytes >= byteCap { break }
                visible.append(row)
                visibleLineCount += 1
                visibleBytes += line.text.utf8.count
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
