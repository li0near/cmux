public import SwiftUI

/// Container renderer for a `SynthesizedEntry` whose kind is `.rewind`.
///
/// Renders the rewind's header through ``EntryHeaderView`` (chevron +
/// "Abandoned Branch" + entry-count label + divergence timestamp);
/// when expanded, walks the abandoned-branch transcript inline through
/// the parent's per-`Entry` dispatcher injected via
/// ``RewindEntryActions/renderSubEntry``. Children are top-level
/// `Entry` kinds (user / agent / system / compact / synthesized) so
/// they recurse through exactly the dispatch the main transcript
/// `ForEach` uses, automatically gaining the same expansion wiring.
///
/// Inner `LazyVStack` defers child realization to scroll-visibility:
/// the corpus dogfood max abandoned-tail is 512 entries (one outlier),
/// p95 is 6, median is 1. A plain `ForEach` would realize all 512
/// child views the moment the user clicks expand; `LazyVStack` keeps
/// the expansion path responsive in the worst-case-tail.
///
/// **Snapshot-boundary policy**: holds only value-typed inputs and
/// the action bundle. The actions struct's closures transitively
/// capture the `AgentXrayPanel` reference (`@MainActor @Observable
/// final class`), which has stable object identity across re-renders.
///
/// **Equatable + `.equatable()`**: conforms `Equatable` (synthesized
/// from value-typed stored properties; the closure-bearing
/// ``RewindEntryActions`` field's `==` is intentionally `true`-always).
/// Dispatch site appends `.equatable()` so SwiftUI skips body
/// re-evaluation when value inputs haven't changed.
@available(macOS 15, *)
public struct RewindEntryView: View, Equatable {

    public let entry: SynthesizedEntry
    public let palette: HudPalette
    public let isExpanded: Bool
    nonisolated public let actions: RewindEntryActions

    public init(
        entry: SynthesizedEntry,
        palette: HudPalette,
        isExpanded: Bool,
        actions: RewindEntryActions
    ) {
        self.entry = entry
        self.palette = palette
        self.isExpanded = isExpanded
        self.actions = actions
    }

    public var body: some View {
        let entryID = entry.id.stableString
        VStack(alignment: .leading, spacing: Theme.Spacing.verticalStack) {
            Button {
                actions.onToggleExpansion(.entry(id: entryID))
            } label: {
                EntryHeaderView(
                    header: entry.header,
                    palette: palette,
                    pulseIcon: false,
                    kindAccentColor: nil,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                // Universal-look spike: spacing 0 (children's own
                // .padding(.vertical) provides the rhythm — same
                // density as outer transcript). Vertical gutter on
                // the body's leading edge marks the abandoned-branch
                // boundary at the rewind's icon column.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entry.subEntries, id: \.id.stableString) { sub in
                        actions.renderSubEntry(sub)
                    }
                }
                .padding(.leading, Theme.Indent.subEntry)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .frame(width: 1)
                        .foregroundStyle(palette.dim.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, Theme.Padding.horizontal)
        .padding(.vertical, Theme.Spacing.verticalStack)
        .id(entryID)
    }
}
