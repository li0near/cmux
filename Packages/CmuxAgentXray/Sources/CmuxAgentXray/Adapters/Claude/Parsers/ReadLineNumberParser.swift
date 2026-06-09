import Foundation

/// Parses Claude Code's Read tool result format — lines prefixed with
/// `<padded-line-num>\t<line-text>`. Used by the builder to lift the
/// embedded line numbers into `Section.code(.plain)`'s gutter (so the
/// row renders with real file line numbers) and strip them from the
/// rendered text (so we don't show duplicate numbers).
///
/// Format invariant (corpus probe 2026-06-10, 9,872 results across
/// 776 sessions):
///
/// - 99.86% of non-empty lines match `^\s*\d+\t`
/// - The 0.14% non-matching results are whole-result envelopes (error
///   messages, `<system-reminder>...</system-reminder>` appendices,
///   the dedup marker `"File unchanged since last read..."`) —
///   numbered output never interleaves with these
/// - When the user passes `offset: N`, numbering starts at N (not 1);
///   `limit` truncates the trailing tail
/// - Trailing blank lines from a numbered file still carry their own
///   `<num>\t` prefix (just no text after the tab)
/// - Legacy `→` (U+2192) delimiter from 2026-03/04 is gone since
///   2026-04 — the `\t` form is universal in the live corpus
enum ReadLineNumberParser {

    /// If every non-empty line of `text` matches `^\s*\d+\t`, strip
    /// the prefix from each line and return the stripped joined
    /// content + the first line's parsed number (matches the Read
    /// tool's `offset` parameter when set, or `1` otherwise).
    /// Returns nil for status envelopes (no numbered output) — caller
    /// renders those with `lineNumberStart: nil` so the gutter is
    /// suppressed.
    static func strip(_ text: String) -> (text: String, lineNumberStart: Int)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return nil }
        var stripped: [String] = []
        stripped.reserveCapacity(lines.count)
        var firstNumber: Int?
        for line in lines {
            // Trailing empty line after final \n: keep as empty,
            // doesn't disqualify the match.
            if line.isEmpty {
                stripped.append("")
                continue
            }
            guard let prefix = parsePrefix(line) else { return nil }
            if firstNumber == nil { firstNumber = prefix.number }
            stripped.append(prefix.rest)
        }
        guard let firstNumber else { return nil }
        return (stripped.joined(separator: "\n"), firstNumber)
    }

    /// Parse `\s*\d+\t` from the start of `line`. Returns the parsed
    /// number plus the rest of the line (after the tab). Nil if the
    /// shape doesn't match.
    private static func parsePrefix(_ line: Substring) -> (number: Int, rest: String)? {
        var i = line.startIndex
        // Skip leading spaces (Claude Code right-aligns to 4–6 chars).
        while i < line.endIndex, line[i] == " " {
            i = line.index(after: i)
        }
        // Require ≥1 digit.
        let numStart = i
        while i < line.endIndex, line[i].isASCII,
              let v = line[i].asciiValue, v >= 0x30, v <= 0x39 {
            i = line.index(after: i)
        }
        guard i > numStart else { return nil }
        guard i < line.endIndex, line[i] == "\t" else { return nil }
        guard let number = Int(line[numStart..<i]) else { return nil }
        let rest = String(line[line.index(after: i)..<line.endIndex])
        return (number, rest)
    }
}
