import Foundation

/// Per-section inline-rendering caps. The panel renders entries inline
/// up to these limits; anything beyond surfaces an `↗ Open detail`
/// link that opens the full content in a sibling detail tab.
///
/// Two-tier policy:
///   - **Standard** (`.standard`) — 30 lines / 3 KiB. Bounds maximum
///     row height so LazyVStack's lazy-row height estimation can't
///     drift by orders of magnitude when long sections fold into the
///     rendered set.
///   - **Always link** (`.alwaysLink`) — title-only inline rendering;
///     body opens in a detail tab. Used for sections the user has
///     explicitly opted to read in a dedicated panel (assistant text,
///     skill bodies).
public struct RenderSectionCaps: Equatable, Sendable {
    public let maxLines: Int
    public let maxBytes: Int
    public let alwaysLink: Bool

    /// Default inline cap. 30 lines × ~17 px per line ≈ 510 px max
    /// per section.
    public static let standard = RenderSectionCaps(
        maxLines: 30, maxBytes: 3 * 1024, alwaysLink: false
    )

    /// Title-only inline rendering. The detail link is the entirety
    /// of the inline surface.
    public static let alwaysLink = RenderSectionCaps(
        maxLines: 0, maxBytes: 0, alwaysLink: true
    )
}

/// Per-section cap policy. Every entry section enumerates here so
/// adding a new section type forces an explicit cap decision via
/// Swift's exhaustive switch.
public enum RenderCaps {
    public enum Section: Equatable, Sendable {
        case assistantText
        case compactBody
        case contextUsage
        case editedTextFile
        case localCommandCaveat
        case recapBody
        case skillBody
        case slashCmdOutput
        case systemBody
        case systemReminder
        case thinking
        case toolInput
        case toolResult
        case userPrompt
    }

    /// Authoritative cap policy. Every section is enumerated
    /// explicitly so a future contributor adding a new section gets
    /// a compile error here until they make a deliberate decision.
    public static func caps(for section: Section) -> RenderSectionCaps {
        switch section {
        case .assistantText:
            // User-preference: always read assistant responses in a
            // dedicated detail panel rather than inline.
            return .alwaysLink
        case .compactBody:        return .standard
        case .contextUsage:       return .standard
        case .editedTextFile:     return .standard
        case .localCommandCaveat: return .standard
        case .recapBody:          return .standard
        case .skillBody:
            // User-preference: always read skill bodies in a
            // dedicated detail panel.
            return .alwaysLink
        case .slashCmdOutput:     return .standard
        case .systemBody:         return .standard
        case .systemReminder:     return .standard
        case .thinking:           return .standard
        case .toolInput:          return .standard
        case .toolResult:         return .standard
        case .userPrompt:         return .standard
        }
    }
}
