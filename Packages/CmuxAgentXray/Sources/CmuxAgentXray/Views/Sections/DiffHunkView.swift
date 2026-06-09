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
    let onOpenDetail: () -> Void

    var body: some View {
        let cap = computeCap(hunks: hunks)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(cap.visibleRows.enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
            if cap.overflow {
                OpenDetailLinkView(
                    totalLines: cap.totalLines,
                    palette: palette,
                    action: onOpenDetail
                )
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .header(let hunk):
            Text(hunkHeaderText(hunk))
                .font(Theme.SubRow.title)
                .foregroundStyle(palette.dim)
                .padding(.horizontal, Theme.Padding.expandedBodyBlock)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .line(let line, let oldNo, let newNo):
            let colors = lineColors(for: line.kind)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(formatLineNumber(oldNo))
                    .font(Theme.SubRow.title)
                    .foregroundStyle(palette.dim)
                    .frame(width: 36, alignment: .trailing)
                Text(formatLineNumber(newNo))
                    .font(Theme.SubRow.title)
                    .foregroundStyle(palette.dim)
                    .frame(width: 36, alignment: .trailing)
                Text(prefixGlyph(for: line.kind))
                    .font(Theme.SubRow.title)
                    .foregroundStyle(colors.foreground)
                    .frame(width: 14, alignment: .center)
                Text(line.text)
                    .font(Theme.SubRow.title)
                    .foregroundStyle(colors.foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 1)
            .background(Rectangle().fill(colors.background))
        }
    }

    private func lineColors(
        for kind: DiffHunk.Line.Kind
    ) -> (foreground: Color, background: Color) {
        switch kind {
        case .context: return (palette.primary.opacity(0.85), .clear)
        case .removed: return (palette.red, palette.red.opacity(0.20))
        case .added:   return (palette.green, palette.green.opacity(0.20))
        }
    }

    private func prefixGlyph(for kind: DiffHunk.Line.Kind) -> String {
        switch kind {
        case .context: return " "
        case .removed: return "-"
        case .added:   return "+"
        }
    }

    private func formatLineNumber(_ n: Int?) -> String {
        guard let n else { return "" }
        return String(n)
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
    }

    /// Project hunks into a flat list of rows (header + per-line) and
    /// truncate to the inline cap. The 30-row / 3-KiB threshold mirrors
    /// ``RenderCaps/standard``; the cache layer treats `.diffHunks` as
    /// `.empty` so this view owns the cap decision at render time.
    private func computeCap(hunks: [DiffHunk]) -> CapResult {
        var allRows: [Row] = []
        var totalBytes = 0
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
                allRows.append(.line(line, oldNo: oldNo, newNo: newNo))
                totalBytes += line.text.utf8.count
            }
        }
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
                totalLines: lineRowCount
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
            totalLines: lineRowCount
        )
    }
}
