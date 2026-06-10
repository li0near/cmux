import Foundation

/// Result of applying a `RenderSectionCaps` to a body of text.
/// Carries the truncated inline preview plus an `overflow` flag the
/// view uses to decide whether to surface an `↗ Open detail` link.
public struct ExpandableContent: Equatable, Sendable {
    /// The text the panel renders inline. Joined with `"\n"`.
    public let inlineBody: String
    /// Total line count of the original (pre-truncation) body. Used
    /// in the `Open detail · N lines` overflow label.
    public let totalLines: Int
    /// True when the original body was truncated to fit the cap;
    /// prompts the renderer to show the overflow link.
    public let overflow: Bool

    public init(inlineBody: String, totalLines: Int, overflow: Bool) {
        self.inlineBody = inlineBody
        self.totalLines = totalLines
        self.overflow = overflow
    }

    public static let empty = ExpandableContent(inlineBody: "", totalLines: 0, overflow: false)
}

extension ExpandableContent {
    /// Apply caps to a list of text blocks. `caps.alwaysLink` returns
    /// an empty inline body and `overflow = true` so the renderer
    /// surfaces the link only.
    public static func make(
        from blocks: [String],
        caps: RenderSectionCaps
    ) -> ExpandableContent {
        let joined = blocks.joined(separator: "\n")
        let totalLines = joined.split(separator: "\n", omittingEmptySubsequences: false).count

        if caps.alwaysLink {
            return ExpandableContent(inlineBody: "", totalLines: totalLines, overflow: !joined.isEmpty)
        }

        // Apply line cap first.
        var lines = joined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var didTruncate = false
        if caps.maxLines > 0, lines.count > caps.maxLines {
            lines = Array(lines.prefix(caps.maxLines))
            didTruncate = true
        }
        var prefix = lines.joined(separator: "\n")

        // Apply byte cap on the line-prefixed result.
        if caps.maxBytes > 0,
           let utf8 = prefix.data(using: .utf8),
           utf8.count > caps.maxBytes {
            // Truncate by character count then re-encode — bytes-aware
            // truncation in pure Swift would need scalar-by-scalar UTF-8
            // accumulation; this is a conservative approximation.
            let charCap = caps.maxBytes
            if prefix.count > charCap {
                prefix = String(prefix.prefix(charCap))
            }
            didTruncate = true
        }

        return ExpandableContent(
            inlineBody: prefix,
            totalLines: totalLines,
            overflow: didTruncate
        )
    }
}
