import Foundation

/// Renders `[DiffHunk]` as a self-contained HTML chunk suitable for
/// embedding inside a Markdown body. Output is a `<table>` with
/// line-number columns + per-row background tints (full-row green for
/// added, red for removed, transparent for context). Hunk headers
/// render as a row with `colspan="3"`.
///
/// The detail-tab WebView's shell.html styles
/// `.diff-table` / `.diff-add` / `.diff-rem` / `.diff-context` /
/// `.diff-hunk-header`.
///
/// Lib-like: pure value-in / value-out — no SwiftUI, no AppKit, no
/// per-platform deps. Designed so it can be lifted out into a separate
/// package or consumed by any surface that needs an HTML diff
/// representation. The Spike-level output is structural only — code
/// cells are emitted as plain escaped text. Per-language syntax
/// highlighting is a planned follow-up that wraps cell content in
/// `<code class="language-X">` so the WebView's highlight.js auto-tints
/// each cell.
enum DiffHTMLRenderer {

    /// Build the HTML chunk for a unified-diff view.
    /// - Parameters:
    ///   - hunks: the structured patch (Claude Code's
    ///     `toolUseResult.structuredPatch` shape).
    ///   - filePath: file path to display in the table caption header.
    ///   - language: language hint reserved for the future syntax-
    ///     highlighting follow-up; currently embedded as a `data-language`
    ///     attribute for stylesheet hooks.
    static func render(
        hunks: [DiffHunk],
        filePath: String,
        language: String?
    ) -> String {
        var out: [String] = []
        out.append(
            "<table class=\"diff-table\" data-language=\"\(escape(language ?? ""))\">"
        )
        out.append(
            "<caption class=\"diff-caption\">\(escape(filePath))</caption>"
        )
        out.append("<tbody>")
        for hunk in hunks {
            out.append(hunkHeaderRow(hunk))
            var oldOffset = hunk.oldStart
            var newOffset = hunk.newStart
            for raw in hunk.lines {
                let line = DiffHunk.classifyLine(raw)
                let displayNumber: Int?
                let rowClass: String
                let glyph: String
                switch line.kind {
                case .context:
                    displayNumber = newOffset
                    rowClass = "diff-context"
                    glyph = " "
                    oldOffset += 1
                    newOffset += 1
                case .removed:
                    displayNumber = oldOffset
                    rowClass = "diff-rem"
                    glyph = "-"
                    oldOffset += 1
                case .added:
                    displayNumber = newOffset
                    rowClass = "diff-add"
                    glyph = "+"
                    newOffset += 1
                }
                out.append(
                    "<tr class=\"\(rowClass)\">"
                    + "<td class=\"diff-num\">\(displayNumber.map(String.init) ?? "")</td>"
                    + "<td class=\"diff-glyph\">\(escape(glyph))</td>"
                    + "<td class=\"diff-code\">\(escape(line.text))</td>"
                    + "</tr>"
                )
            }
        }
        out.append("</tbody>")
        out.append("</table>")
        return out.joined(separator: "\n")
    }

    private static func hunkHeaderRow(_ hunk: DiffHunk) -> String {
        let header =
            "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@"
        return "<tr class=\"diff-hunk-header\"><td colspan=\"3\">\(escape(header))</td></tr>"
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&#39;"
            default:   out.append(c)
            }
        }
        return out
    }
}
