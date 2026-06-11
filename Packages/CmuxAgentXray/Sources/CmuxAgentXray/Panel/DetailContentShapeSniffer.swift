import Foundation

/// Source-aware content-shape sniffer for the detail-tab dispatch.
/// Inspects a `.text` section's content and decides which renderer
/// foundation case (``ContentType``) to use.
///
/// Detection ladder (in order; first match wins):
/// 1. **JSON** — leading `{` or `[` after trim **and**
///    `JSONSerialization.jsonObject(...)` parses without error.
///    Leading-char only would misfire on Bash output starting with
///    `{` (e.g. raw `jq` lines, partial JSON Lines), so the validity
///    parse is the conservative fallback.
/// 2. **Diff** — text contains at least **two** of:
///    `^diff --git` line, `^@@ -X,Y +X,Y @@` hunk header,
///    `^--- a/` + `^+++ b/` file-header pair. The two-of-three
///    threshold mirrors the JSON validity-parse conservatism so a
///    Bash log line containing a single `--- a/` doesn't misclassify.
/// 3. **Markdown** — text contains two or more lines starting with
///    `^### `. The single-heading case is treated as plain prose
///    (avoids overfitting against tool output that happens to use
///    one heading).
/// 4. **Plain text** — everything else.
///
/// `mcpServer` is currently unused; reserved for future per-server
/// hints if the corpus shows stable conventions (e.g. a server known
/// to always emit YAML). No allow-list today — Playwright's
/// `### Result / ### Ran` shape is recognized via the generic
/// markdown ladder, not via a server-name match (verified against
/// the corpus 2026-06-07 — no other MCP server in the corpus uses
/// the convention, but the sniffer doesn't need to know that).
enum DetailContentShapeSniffer {

    /// Run the detection ladder. Returns the matching ``ContentType``.
    static func sniff(text: String, mcpServer: String? = nil) -> ContentType {
        if isJSON(text) {
            return .json
        }
        if isDiff(text) {
            return .diff
        }
        if isMarkdown(text) {
            return .markdown
        }
        return .plainText
    }

    /// True when the trimmed text starts with `{` or `[` AND parses
    /// as valid JSON via `JSONSerialization`. The validity check
    /// guards against false positives from Bash output / log lines
    /// that happen to start with `{` but aren't real JSON.
    private static func isJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, (first == "{" || first == "[") else {
            return false
        }
        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )) != nil
    }

    /// True when the text contains two or more `^### ` heading lines.
    /// Used by Playwright MCP results (`### Result`, `### Ran
    /// Playwright code`, `### Open tabs`, etc.) but not Playwright-
    /// specific — any text with multiple H3 headings counts.
    private static func isMarkdown(_ text: String) -> Bool {
        var headingCount = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("### ") {
                headingCount += 1
                if headingCount >= 2 { return true }
            }
        }
        return false
    }

    /// True when the text shows at least two of the three structural
    /// signals of a unified diff:
    /// - a `diff --git` line (`git diff` only),
    /// - a `@@ -X[,Y] +A[,B] @@` hunk header (any unified diff),
    /// - a paired `--- a/` and `+++ b/` file-header pair (any unified diff).
    /// One signal is too weak — Bash logs sometimes carry a single
    /// `+++ ...` style line. Two-of-three matches the JSON
    /// validity-parse conservatism elsewhere in the ladder.
    private static func isDiff(_ text: String) -> Bool {
        var hasDiffGit = false
        var hasHunkHeader = false
        var hasMinusA = false
        var hasPlusB = false
        let hunkRegex = /^@@ -\d+(,\d+)? \+\d+(,\d+)? @@/
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !hasDiffGit, line.hasPrefix("diff --git") { hasDiffGit = true }
            if !hasMinusA, line.hasPrefix("--- a/") { hasMinusA = true }
            if !hasPlusB, line.hasPrefix("+++ b/") { hasPlusB = true }
            if !hasHunkHeader, line.starts(with: hunkRegex) { hasHunkHeader = true }
        }
        let hasFileHeaders = hasMinusA && hasPlusB
        let signals = (hasDiffGit ? 1 : 0)
            + (hasHunkHeader ? 1 : 0)
            + (hasFileHeaders ? 1 : 0)
        return signals >= 2
    }

    /// Split a markdown text on `^### ` heading boundaries. Each
    /// returned segment carries `(heading: String?, body: String)`
    /// where `heading` is the trimmed heading text (without the
    /// leading `### `), or `nil` for content before the first
    /// heading.
    ///
    /// Used by the detail tab to render each section under its own
    /// label.
    static func splitMarkdownSections(text: String) -> [(heading: String?, body: String)] {
        var sections: [(heading: String?, body: String)] = []
        var currentHeading: String? = nil
        var currentBody: [String] = []

        func flush() {
            let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if currentHeading != nil || !body.isEmpty {
                sections.append((heading: currentHeading, body: body))
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("### ") {
                flush()
                currentHeading = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                currentBody = []
            } else {
                currentBody.append(String(line))
            }
        }
        flush()
        return sections
    }
}
