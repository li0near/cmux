public import SwiftUI

/// Top-level entry renderer. Dispatches an `Entry` to a unified
/// header + body layout, applying variant-specific cosmetic chrome
/// (pulse animations for queued / streaming, accent colors per
/// agent-kind, status-dot trailing items for tools).
///
/// **Snapshot-boundary policy:** this view holds only value-typed
/// inputs (Entry, computed cache fields, palette token, bundled
/// closures via ``EntryViewActions``) — never an `@ObservedObject`
/// reference. Callers from the panel layer are responsible for
/// passing immutable snapshots.
///
/// Post-G1.5: nested children live on the entry's `subEntries` field
/// directly (not in `body.sections`). Container variants (`.agent` /
/// `.tool` / `.synthesized.rewind`) own their own sub-entry
/// rendering — `AgentEntryView` walks `entry.subEntries` directly.
/// `EntryView` no longer takes a `renderSubEntry` closure.
///
/// **Equatable + `.equatable()`**: conforms `Equatable` (synthesized
/// from value-typed stored properties; the closure-bearing
/// ``EntryViewActions`` field's `==` is intentionally `true`-always).
/// Dispatch sites append `.equatable()` so SwiftUI skips body
/// re-evaluation when value inputs haven't changed.
@available(macOS 15, *)
public struct EntryView: View, Equatable {

    public let entry: Entry
    public let computed: EntryComputedCache.Computed
    public let palette: HudPalette
    public let displayMode: DisplayMode
    /// Whether this entry's body is currently expanded.
    public let isExpanded: Bool
    /// True when this entry is the streaming agent turn (drives the
    /// header glyph's pulse animation).
    public let isStreaming: Bool
    /// Bundled action closures; see ``EntryViewActions``.
    nonisolated public let actions: EntryViewActions

    public init(
        entry: Entry,
        computed: EntryComputedCache.Computed,
        palette: HudPalette,
        displayMode: DisplayMode,
        isExpanded: Bool,
        isStreaming: Bool = false,
        actions: EntryViewActions
    ) {
        self.entry = entry
        self.computed = computed
        self.palette = palette
        self.displayMode = displayMode
        self.isExpanded = isExpanded
        self.isStreaming = isStreaming
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.verticalStack) {
            Button(action: actions.onToggleExpansion) {
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
                    onOpenDetail: actions.onOpenDetail
                )
                .padding(.leading, Theme.Indent.subEntry)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .frame(width: 2)
                        .foregroundStyle(palette.expandedBackground)
                        .padding(.leading, Theme.Metric.entryIconWidth)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Padding.horizontal)
    }

    /// Variant-specific accent color override. nil = palette.primary.
    /// Per-kind rules live in ``PaletteRole/forEntry(_:)`` so live-entry
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
