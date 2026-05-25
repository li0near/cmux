import Foundation

/// Per-section inline-rendering caps. The inspector renders chunks inline
/// up to these limits; anything beyond surfaces an `↗ Open detail` link
/// that opens the full content in a sibling detail tab.
///
/// Three classes of cap applied uniformly to regular and `isMeta=true`
/// chunks:
///
///   - **Mostly short** (`mostlyShort` — 150 lines / 16 KiB) — the section
///     is typically small enough to render in full; a soft fallback cap
///     protects against pathological cases. Used by tool inputs, system
///     errors/hooks/recap, isMeta context-usage / short reminders.
///
///   - **Standard** (`standard` — 150 lines / 16 KiB) — the section is
///     medium-length. Same numerics as `mostlyShort` but documents the
///     intent of "everything else." Used by user prompt full text.
///
///   - **Mostly long** (`mostlyLong` — 100 lines / 8 KiB) — the section
///     is typically too large to read inline; cap teaser + link. Used
///     by tool results, compact summaries, slash-command stdout.
///
///   - **Always link** (`alwaysLink`) — render only as a clickable
///     title row that opens the full body in a detail tab. Used by
///     assistant text, skill bodies, slash-command markdown bodies —
///     content the user explicitly preferred to view in a dedicated
///     panel rather than inline.
///
///   - **Never cap** (`neverCap`) — render fully inline always; expand
///     and collapse via row state. Used by thinking — redirecting to a
///     detail panel would break the user's reading flow.
struct InspectorSectionCaps: Equatable {
    let maxLines: Int
    let maxBytes: Int
    let alwaysLink: Bool

    static let neverCap = InspectorSectionCaps(maxLines: .max, maxBytes: .max, alwaysLink: false)
    static let mostlyShort = InspectorSectionCaps(maxLines: 150, maxBytes: 16 * 1024, alwaysLink: false)
    static let standard = InspectorSectionCaps(maxLines: 150, maxBytes: 16 * 1024, alwaysLink: false)
    static let mostlyLong = InspectorSectionCaps(maxLines: 100, maxBytes: 8 * 1024, alwaysLink: false)
    static let alwaysLink = InspectorSectionCaps(maxLines: 0, maxBytes: 0, alwaysLink: true)
}

/// Per-section bindings. Single source of truth — every snapshot field
/// references one of these rather than introducing its own constant.
enum InspectorCaps {
    static let userPrompt = InspectorSectionCaps.standard
    static let assistantText = InspectorSectionCaps.alwaysLink
    static let thinking = InspectorSectionCaps.neverCap
    static let toolInput = InspectorSectionCaps.mostlyShort
    static let toolResult = InspectorSectionCaps.mostlyLong
    static let systemBody = InspectorSectionCaps.mostlyShort
    static let slashCmdOutput = InspectorSectionCaps.mostlyLong
    static let recapBody = InspectorSectionCaps.mostlyShort
    static let compactBody = InspectorSectionCaps.mostlyLong
    static let skillBody = InspectorSectionCaps.alwaysLink
    static let systemReminder = InspectorSectionCaps.mostlyShort
    static let localCommandCaveat = InspectorSectionCaps.mostlyShort
    static let contextUsage = InspectorSectionCaps.mostlyShort
}
