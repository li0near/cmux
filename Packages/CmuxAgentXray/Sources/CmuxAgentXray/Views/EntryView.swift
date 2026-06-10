public import SwiftUI

/// Top-level entry renderer. Dispatches an `Entry` to a unified
/// header + body layout, applying variant-specific cosmetic chrome
/// (pulse animations for queued / streaming, accent colors per
/// agent-kind, status-dot trailing items for tools).
///
/// **Snapshot-boundary policy:** this view holds only value-typed
/// inputs (Entry, computed cache fields, palette token, two stable
/// closures) — never an `@ObservedObject` reference. Callers from
/// the panel layer are responsible for passing immutable snapshots.
///
/// Post-G1.5: nested children live on the entry's `subEntries` field
/// directly (not in `body.sections`). Container variants (`.agent` /
/// `.tool` / `.synthesized.branchLink`) own their own sub-row
/// rendering — `AgentEntryView` walks `entry.subEntries` directly.
/// `EntryView` no longer takes a `renderSubEntry` closure.
@available(macOS 15, *)
public struct EntryView: View {

    public let entry: Entry
    public let computed: EntryComputedCache.Computed
    public let palette: HudPalette
    public let displayMode: DisplayMode
    /// Whether this entry's body is currently expanded.
    public let isExpanded: Bool
    /// True when this entry is the streaming agent turn (drives the
    /// header glyph's pulse animation).
    public let isStreaming: Bool
    public let onToggleExpansion: () -> Void
    public let onOpenDetail: () -> Void

    public init(
        entry: Entry,
        computed: EntryComputedCache.Computed,
        palette: HudPalette,
        displayMode: DisplayMode,
        isExpanded: Bool,
        isStreaming: Bool = false,
        onToggleExpansion: @escaping () -> Void,
        onOpenDetail: @escaping () -> Void
    ) {
        self.entry = entry
        self.computed = computed
        self.palette = palette
        self.displayMode = displayMode
        self.isExpanded = isExpanded
        self.isStreaming = isStreaming
        self.onToggleExpansion = onToggleExpansion
        self.onOpenDetail = onOpenDetail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.verticalStack) {
            Button(action: onToggleExpansion) {
                EntryHeaderView(
                    header: entry.header,
                    palette: palette,
                    pulseIcon: shouldPulseIcon,
                    kindAccentColor: kindAccentColor,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                EntryBodyView(
                    entryBody: entry.body,
                    computed: computed.sections,
                    palette: palette,
                    displayMode: displayMode,
                    onOpenDetail: onOpenDetail
                )
                .padding(.leading, Theme.Indent.subEntry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Padding.horizontal)
        .padding(.vertical, Theme.Spacing.verticalStack)
    }

    /// Variant-specific accent color override. nil = palette.primary.
    /// Per-kind rules live in ``PaletteRole/forEntry(_:)`` so live-row
    /// and detail-header coloring share one source of truth.
    private var kindAccentColor: Color? {
        PaletteRole.forEntry(entry).map { palette.color(for: $0) }
    }

    /// Pulse the header icon when:
    /// - this is a queued, still-pending UserEntry (user typed
    ///   mid-turn; not yet consumed by the next API call), OR
    /// - this is the agent turn currently streaming.
    private var shouldPulseIcon: Bool {
        switch entry {
        case .user(let user):
            return user.queuedState == .pending
        case .agent:
            return isStreaming
        default:
            return false
        }
    }
}
