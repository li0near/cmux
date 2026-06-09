/// Body data for every `Entry`. The body is a list of sections; an empty
/// list means a header-only entry (Variant A — clickable link with no
/// inline content, e.g. `assistantText`, `prLink`).
///
/// Sections cover inline rendering payloads only. Nested children
/// (sub-agent transcripts, abandoned-branch entries, agent turn
/// sub-entries) live on the entry's top-level `subEntries` field, not
/// in `body.sections`.
public struct Body: Equatable, Sendable {
    public let sections: [Section]

    public init(sections: [Section] = []) {
        self.sections = sections
    }

    /// Convenience: header-only body (no inline content).
    public static let empty = Body(sections: [])

    /// Convenience: single text section in the default style.
    public static func text(_ blocks: [String]) -> Body {
        Body(sections: [.text(blocks, style: .normal)])
    }
}

/// One section within an entry's body.
///
/// Pure rendering payloads. Container-shape data (nested children)
/// lives on the parent ``Entry``'s `subEntries` projection, not in a
/// section.
///
/// `Section` defines a custom `==` so the `.text` and `.code` cases
/// compare their content by a **structural signature** only — synthesizing
/// equality would deep-walk every byte of every text block (or every
/// line of every diff hunk), and `DetailContent: Equatable` runs that
/// comparison on every reactive update at SwiftUI's hot path. Section
/// content is immutable per builder pass, so a structural-signature
/// collision across distinct contents is vanishingly unlikely (a real
/// content change almost always changes the byte count too). The
/// `.image` / `.toolReference` / `.offloadedOutput` arms compare their
/// associated values normally — they're small and stable.
public enum Section: Sendable {
    /// Inline text block(s) rendered in a gray background. The `style`
    /// drives per-section visual treatment (italic, error red, etc.).
    /// Detail-tab rendering hint (markdown / json / code / diff) is
    /// **derived at resolve time** by the detail resolver — it is NOT
    /// stored on the Section. Inline rendering only ever uses `style`.
    case text([String], style: TextStyle)
    /// Inline image (user-pasted or tool-returned). Base64 lazy-decoded
    /// at render time. See ``ImageSource``.
    case image(ImageSource)
    /// A `tool_reference` block from CC's client-side `ToolSearch` deferred
    /// loader, naming a tool the model is being made aware of (e.g.
    /// `mcp__sap-jira__get_issue`). Carries just the bare tool name —
    /// the renderer parses any `mcp__<server>__` prefix at display time.
    case toolReference(toolName: String)
    /// Claude Code's `<persisted-output>` wrapper — a tool result that
    /// exceeded CC's inline size threshold and was offloaded to a file
    /// on disk. The renderer surfaces an "↗ Open offloaded result" link;
    /// the detail-tab resolver reads the file lazily on click.
    case offloadedOutput(OffloadedOutput)
    /// Code-shaped content rendered with a line-number gutter and
    /// per-language syntax highlighting. The inner ``CodeContent``
    /// discriminator picks between plain code (Read tool result, file
    /// content) and structured diff (Edit / MultiEdit / Write-update
    /// `toolUseResult.structuredPatch`). The renderer
    /// (``CodeBlockView``) projects either case into a flat
    /// ``CodeRow`` stream; the detail-tab resolver branches on the
    /// inner case to either reuse the file's basename (plain) or
    /// serialize the hunks back to a fenced ``` ```diff ``` markdown
    /// body (diff).
    case code(CodeContent)
}

/// Discriminated payload for ``Section/code(_:)``. Plain code carries
/// raw text + an optional language hint + an optional line-number
/// start (nil = no gutter, e.g. Bash / Grep output where line numbers
/// don't map to file lines); diff code carries the structured
/// `[DiffHunk]` from the JSONL wire shape so the detail-tab serializer
/// can rebuild the unified-diff text losslessly.
public enum CodeContent: Sendable {
    /// File-content-shaped code (e.g. Read tool result body) when
    /// `lineNumberStart` is non-nil; or shell-output-shaped code
    /// (Bash / Grep) when `lineNumberStart` is nil. Renders as
    /// line-numbered rows when the start is set, syntax-highlighted
    /// by `language` when the hint is set.
    case plain(text: String, language: String?, lineNumberStart: Int?)
    /// Structured git-diff hunks. Renders as line-numbered rows with
    /// per-line classification (context / added / removed) and full-row
    /// red/green tints. The hunks survive the model layer untouched so
    /// the detail-tab path (`serializeUnifiedDiff`) can reconstruct the
    /// `--- a/X / +++ b/X / @@ ...` shape.
    case diff(hunks: [DiffHunk], language: String?)
}

extension CodeContent {
    /// Language hint shared by both inner cases.
    fileprivate var language: String? {
        switch self {
        case .plain(_, let lang, _), .diff(_, let lang):
            return lang
        }
    }

    /// Total UTF-8 byte count across all this section's text content
    /// (the single string for `.plain`, every hunk line for `.diff`).
    /// Used by ``Section/==(_:_:)`` as the structural-signature
    /// fingerprint — same shape as `.text`'s arm. The
    /// `.plain` ↔ `.diff` cross-case alias is a theoretical
    /// collision; tools don't transition between shapes within a
    /// single result, so a render would never observe one swap to
    /// the other.
    fileprivate var totalBytes: Int {
        switch self {
        case .plain(let text, _, _):
            return text.utf8.count
        case .diff(let hunks, _):
            return hunks.reduce(0) { $0 + $1.lines.reduce(0) { $0 + $1.utf8.count } }
        }
    }
}

extension Section: Equatable {
    public static func == (lhs: Section, rhs: Section) -> Bool {
        switch (lhs, rhs) {
        case (.text(let lb, let ls), .text(let rb, let rs)):
            // Structural signature: block count + style + total UTF-8
            // bytes. Avoids the deep `[String] == [String]` walk that
            // synthesized equality would trigger on the SwiftUI hot
            // path (a 50 KB Bash result or a long pasted prompt would
            // be O(N) per reactive update). Collision class is the
            // same as the `.code` arms — distinct contents with the
            // same byte count + style is vanishingly rare since
            // section content is immutable per builder pass.
            guard ls == rs, lb.count == rb.count else { return false }
            return lb.reduce(0) { $0 + $1.utf8.count }
                == rb.reduce(0) { $0 + $1.utf8.count }
        case (.image(let l), .image(let r)):
            return l == r
        case (.toolReference(let l), .toolReference(let r)):
            return l == r
        case (.offloadedOutput(let l), .offloadedOutput(let r)):
            return l == r
        case (.code(let l), .code(let r)):
            // Same shape as `.text`'s arm: total UTF-8 bytes + language.
            // `.plain` and `.diff` reduce to the same fingerprint
            // formula here — see the rationale on `CodeContent`.
            return l.totalBytes == r.totalBytes && l.language == r.language
        case (.text, _), (.image, _), (.toolReference, _),
             (.offloadedOutput, _), (.code, _):
            return false
        }
    }
}

/// Visual treatment applied to a `.text` section.
public enum TextStyle: Equatable, Sendable {
    /// Default: monospace, slightly dimmed primary color.
    case normal
    /// Italic, dim — used for the thinking sub-entry.
    case thinking
    /// Red foreground — used for tool error results.
    case error
    /// Monospace foreground — used for code spans inside markdown
    /// or for a fully-monospaced code section (alongside
    /// ``ContentType/code(language:)``).
    case codeMonospace
}

/// Image content carried in a ``Section/image(_:)``. Two parents in the
/// corpus today (verified 2026-06-07):
/// - User-pasted screenshots in top-level `user.message.content[]`.
/// - Tool-returned screenshots in `tool_result.content[]` (e.g. Playwright
///   `browser_take_screenshot`).
///
/// The base64 payload is kept as `String` and **lazy-decoded** at render
/// time (in `Task.detached`, never on the main thread) so we don't pay
/// the ~150KB-per-image decode cost during transcript build.
public struct ImageSource: Equatable, Sendable {
    /// Encoding of `data`. Today only `.base64` is observed; URL-mode
    /// is in the Anthropic Messages API spec but absent from the corpus.
    public enum Kind: Equatable, Sendable { case base64 }

    public let kind: Kind
    /// MIME type, e.g. `"image/png"`, `"image/jpeg"`.
    public let mediaType: String
    /// Base64-encoded image bytes (no `data:` prefix).
    public let data: String

    public init(kind: Kind = .base64, mediaType: String, data: String) {
        self.kind = kind
        self.mediaType = mediaType
        self.data = data
    }
}

/// Stub representing Claude Code's `<persisted-output>` wrapper —
/// the inline placeholder that CC injects when a tool's stdout exceeds
/// its size threshold. Real bytes are written to a `.txt` / `.json`
/// file on disk and referenced by absolute path.
///
/// Two-commit corpus shape (verified 2026-06-07, 97 files / 78 distinct
/// sessions):
/// ```
/// <persisted-output>
/// Output too large (29.3KB). Full output saved to: /Users/<...>/<...>.txt
///
/// Preview (first 2KB):
/// <preview bytes>
/// </persisted-output>
/// ```
/// ~21 of 252 corpus occurrences truncate before the close tag — the
/// detector must match on the open tag + canonical "Output too large"
/// line only. Path always ends in `.txt` (most) or `.json`.
public struct OffloadedOutput: Equatable, Sendable {
    /// Absolute path to the offloaded `.txt` or `.json` file.
    public let path: String
    /// Display-friendly size label (e.g. `"29.3KB"`, `"1.2MB"`).
    public let sizeLabel: String
    /// First ~2 KB inlined by CC after the path line. nil when the
    /// wrapper truncated before the preview header (rare).
    public let preview: String?

    public init(path: String, sizeLabel: String, preview: String? = nil) {
        self.path = path
        self.sizeLabel = sizeLabel
        self.preview = preview
    }
}

/// One git-diff hunk inside a structured patch — the rendering shape
/// for an Edit / MultiEdit / Write-update result. Decodes directly
/// from Claude Code's JSONL `toolUseResult.structuredPatch[]` array,
/// which means the wire shape and the rendering shape are the same
/// type (no intermediate parser needed). The wire layer references
/// this Models type through ``ClaudeToolUseResult/structuredPatch``;
/// the layering bend mirrors the existing
/// ``ClaudeJSONLLine/attachment`` referencing ``ClaudeAttachment``.
///
/// Lines in ``lines`` are pre-prefixed by Claude Code: each entry
/// starts with one of `' '` (context), `'-'` (removed), or `'+'`
/// (added) followed by the line text. The renderer peeks at the
/// line's `first` to classify; ``classifyLine(_:)`` is the canonical
/// helper.
public struct DiffHunk: Decodable, Equatable, Sendable {
    /// 1-indexed first line of the pre-edit file represented by this
    /// hunk.
    public let oldStart: Int
    /// Number of pre-edit file lines covered (counts both context and
    /// removed lines).
    public let oldLines: Int
    /// 1-indexed first line of the post-edit file.
    public let newStart: Int
    /// Number of post-edit file lines covered (counts both context and
    /// added lines).
    public let newLines: Int
    /// Per-line entries in arrival order. Each line's first character
    /// is the diff prefix (` ` / `-` / `+`); use ``classifyLine(_:)``
    /// to split into kind + text.
    public let lines: [String]

    public init(
        oldStart: Int,
        oldLines: Int,
        newStart: Int,
        newLines: Int,
        lines: [String]
    ) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }

    /// One classified line: a kind (context / removed / added) plus
    /// the line text without its prefix character.
    public struct Line: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case context
            case removed
            case added
        }
        public let kind: Kind
        public let text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Classify a prefix-embedded line. `' '` → `.context`, `'-'` →
    /// `.removed`, `'+'` → `.added`. Defensive fallback for unprefixed
    /// or empty lines: treats them as context with the full text
    /// preserved (unobserved in the corpus, but cheap insurance).
    public static func classifyLine(_ line: String) -> Line {
        guard let first = line.first else {
            return Line(kind: .context, text: "")
        }
        switch first {
        case "-": return Line(kind: .removed, text: String(line.dropFirst()))
        case "+": return Line(kind: .added, text: String(line.dropFirst()))
        case " ": return Line(kind: .context, text: String(line.dropFirst()))
        default:  return Line(kind: .context, text: line)
        }
    }
}

// MARK: - Convenience accessors

extension Body {
    /// Concatenated text content from `.text` and `.code(.plain)`
    /// sections, joined by `"\n"`. Returns "" when the body is
    /// header-only.
    ///
    /// `.code(.diff(...))` sections are NOT walked — diff bodies surface
    /// through dedicated `.diff`-aware paths (renderer + detail
    /// resolver's `serializeUnifiedDiff`), not via plain text
    /// concatenation. Walking them here would emit prefix-embedded
    /// hunk lines into a stream that callers (anchor pairing,
    /// detail-tab text routing) treat as plain code.
    public var textContent: String {
        var parts: [String] = []
        for section in sections {
            switch section {
            case .text(let blocks, _):
                parts.append(contentsOf: blocks)
            case .code(.plain(let text, _, _)):
                parts.append(text)
            case .code(.diff), .image, .toolReference, .offloadedOutput:
                continue
            }
        }
        return parts.joined(separator: "\n")
    }
}
