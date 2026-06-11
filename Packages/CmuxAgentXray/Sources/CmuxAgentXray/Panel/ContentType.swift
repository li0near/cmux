/// Discriminator for how a ``DetailContent``'s body — or one
/// `.text` ``Section`` of an inline body — should be rendered.
///
/// `Section.text(...)` carries an optional content-type annotation that
/// the detail tab uses to dispatch to the matching renderer. The
/// shape-sniffer and per-server hints are the two upstream producers
/// of non-`.plainText` annotations; inline rendering ignores the
/// annotation and stays flat.
public enum ContentType: Equatable, Sendable {
    /// Render the `body` string as plain text (default).
    case plainText
    /// Render the `entries` array as a transcript using the standard
    /// EntryView dispatcher in detail mode.
    case transcript
    /// Markdown content. Detail-tab renderer parses headings, bullets,
    /// fenced code blocks. Implementation ships in a follow-up PR; the
    /// foundation enum case lands here so the type carries the intent.
    case markdown
    /// Source code in a specific language. `language` is a short
    /// identifier (e.g. `"js"`, `"swift"`, `"python"`) that the
    /// syntax-highlighter renderer uses; nil = unknown / no
    /// highlighting.
    case code(language: String?)
    /// Pretty-printed JSON. Detail-tab renderer parses, indents, and
    /// applies basic syntax coloring.
    case json
    /// Unified-diff content. Detail-tab renderer applies per-line
    /// added / removed / context coloring.
    case diff
}
