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
/// 2. **Markdown** — text contains two or more lines starting with
///    `^### `. The single-heading case is treated as plain prose
///    (avoids overfitting against tool output that happens to use
///    one heading).
/// 3. **Plain text** — everything else.
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
        if isMarkdown(text) {
            return .markdown
        }
        return .plainText
    }

    /// Map a file-path extension to a highlight.js-compatible
    /// language identifier. Used by the detail-tab resolver for
    /// Read / Write tool results — the file_path is known, so we
    /// classify the result text as `.code(language:)` directly
    /// instead of running the text-shape ladder. Unmapped extensions
    /// return nil so callers fall through to the existing ladder.
    static func languageHint(forFilePath path: String?) -> String? {
        guard let path else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        switch ext {
        case "swift":         return "swift"
        case "py":            return "python"
        case "ts":            return "typescript"
        case "tsx":           return "tsx"
        case "js":            return "javascript"
        case "jsx":           return "jsx"
        case "json":          return "json"
        case "md", "markdown": return "markdown"
        case "diff", "patch": return "diff"
        case "sh", "bash":    return "bash"
        case "html", "htm":   return "html"
        case "css":           return "css"
        case "yaml", "yml":   return "yaml"
        case "rs":            return "rust"
        case "go":            return "go"
        case "c", "h":        return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "m", "mm":       return "objectivec"
        default:              return nil
        }
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

    /// Split a markdown text on `^### ` heading boundaries. Each
    /// returned segment carries `(heading: String?, body: String)`
    /// where `heading` is the trimmed heading text (without the
    /// leading `### `), or `nil` for content before the first
    /// heading.
    ///
    /// Used by the detail tab to render each section under its own
    /// label. Phase D's stub markdown renderer ignores this split;
    /// the follow-up rich markdown renderer consumes it.
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
