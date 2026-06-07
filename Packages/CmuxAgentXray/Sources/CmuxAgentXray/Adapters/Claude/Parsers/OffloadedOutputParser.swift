import Foundation

/// Parses Claude Code's `<persisted-output>` wrapper out of a tool
/// result text block.
///
/// Claude Code offloads tool outputs above its inline-size threshold
/// to disk and inlines a stub like:
///
/// ```
/// <persisted-output>
/// Output too large (29.3KB). Full output saved to: /tmp/<dir>/<id>.txt
///
/// Preview (first 2KB):
/// <inline preview>
/// </persisted-output>
/// ```
///
/// Verified against 252 corpus occurrences 2026-06-07; format is
/// invariant across CC versions in the corpus. Robust to truncated
/// tails — ~21 of 252 occurrences omit the `</persisted-output>`
/// close tag, so detection only requires the open tag + the canonical
/// "Output too large" line.
///
/// Lives in `Adapters/Claude/Parsers/` because it's a content
/// extractor — it consumes the inside of one section's text block,
/// not a JSONL line. (Per-line routing classifiers live in the
/// sibling `Dispatchers/` folder; cross-line pre-pass walks live in
/// `Resolvers/`.)
enum OffloadedOutputParser {

    /// Walk every `.text` section in a result body; if its content is
    /// a `<persisted-output>` wrapper, replace it with
    /// `.offloadedOutput`. Non-text sections pass through unchanged.
    ///
    /// Used by `ClaudeTranscriptBuilder.buildToolResultSections` as a
    /// post-pass on the raw per-block emission.
    static func promote(_ sections: [Section]) -> [Section] {
        sections.map { section in
            if case .text(let blocks, let style) = section {
                let joined = blocks.joined(separator: "\n")
                if let off = parse(joined) {
                    return .offloadedOutput(off)
                }
                return .text(blocks, style: style)
            }
            return section
        }
    }

    /// Parse a `<persisted-output>...</persisted-output>` wrapper.
    /// Returns nil when:
    ///  - the open tag is absent, OR
    ///  - the canonical `"Output too large (<size>). Full output saved
    ///    to: <path>"` line cannot be found / extracted.
    ///
    /// The close tag is optional (truncated-tail tolerance).
    static func parse(_ text: String) -> OffloadedOutput? {
        guard text.contains("<persisted-output>") else { return nil }
        guard let (sizeLabel, path) = extractSizeAndPath(text) else {
            return nil
        }
        let preview = extractPreview(text)
        return OffloadedOutput(path: path, sizeLabel: sizeLabel, preview: preview)
    }

    // MARK: - Internals

    /// Match the `Output too large (<size>). Full output saved to: <path>`
    /// line. Size is `<digits>(.<digits>)?(KB|MB)`; path ends in `.txt`
    /// or `.json`. Both flavors are corpus-validated.
    private static func extractSizeAndPath(_ text: String) -> (size: String, path: String)? {
        guard let regex = canonicalLineRegex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 3,
              let sizeRange = Range(match.range(at: 1), in: text),
              let pathRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return (String(text[sizeRange]), String(text[pathRange]))
    }

    /// Compiled-once regex for the canonical persisted-output line.
    /// Validated against 252 corpus occurrences 2026-06-07.
    private static let canonicalLineRegex: NSRegularExpression? = {
        // Anchored to a line: ^Output too large \(<size>\)\. Full output saved to: <path>$
        // Size: digits, optional decimal, KB or MB.
        // Path: non-whitespace ending in .txt or .json.
        try? NSRegularExpression(
            pattern: #"^Output too large \(([0-9]+(?:\.[0-9]+)?(?:KB|MB))\)\. Full output saved to: (\S+?\.(?:txt|json))$"#,
            options: [.anchorsMatchLines]
        )
    }()

    /// Extract the inline preview (first ~2KB CC inlines after the
    /// path line). Returns nil when the wrapper truncated before the
    /// preview header (rare).
    private static func extractPreview(_ text: String) -> String? {
        guard let headerRange = text.range(of: "Preview (first 2KB):") else { return nil }
        var preview = String(text[headerRange.upperBound...])
        if let closeRange = preview.range(of: "</persisted-output>") {
            preview = String(preview[..<closeRange.lowerBound])
        }
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
