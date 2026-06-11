public import SwiftUI

/// Single recursive depth-driven row view for every transcript entry.
/// One renderer parameterized by ``Entry`` + ``depth`` covers every
/// kind at every nesting level.
///
/// **Universal rendering rule.** At every nest depth the view:
/// 1. Renders ``EntryHeaderView`` with the entry's accent
///    (``PaletteRole/forEntry(_:)``) and emphasis
///    (``Entry/isEmphasized``) — both predicates editable in one place.
/// 2. When expanded, dispatches on ``Entry/expansionShape``:
///    - ``ExpansionShape/children(_:)`` → recursive `LazyVStack` of
///      child Entries at `depth + 1`, wrapped in an expansion-gutter
///      overlay colored with this entry's accent.
///    - ``ExpansionShape/body(_:)`` → leaf body sections, no gutter.
///    - ``ExpansionShape/none`` → header-only; nothing renders.
///
/// **Outer-padding rule.** ``EntryView`` at depth 0 adds no horizontal
/// padding — the outer ``TranscriptView`` `LazyVStack` applies
/// ``Theme/Padding/horizontal`` once. Each deeper recursion adds one
/// ``Theme/Indent/unit`` of leading padding so cumulative leading from
/// screen left at depth N = `horizontal + N × unit` — universal,
/// scales to any depth, no double-stacking.
///
/// **Snapshot-boundary policy:** holds only value-typed inputs and the
/// closure-bundle ``EntryActions``; never an `@ObservedObject` /
/// `@Bindable` reference.
///
/// **Equatable + `.equatable()`**: conforms `Equatable` over its
/// value-typed stored fields; the closure-bearing ``EntryActions``
/// field's `==` is intentionally `true`-always.
@available(macOS 15, *)
public struct EntryView: View, Equatable {

    public let entry: Entry
    public let depth: Int
    public let palette: HudPalette
    public let isExpanded: Bool
    public let isStreaming: Bool
    public let computed: EntryComputedCache.Computed
    nonisolated public let actions: EntryActions

    public init(
        entry: Entry,
        depth: Int,
        palette: HudPalette,
        isExpanded: Bool,
        isStreaming: Bool,
        computed: EntryComputedCache.Computed,
        actions: EntryActions
    ) {
        self.entry = entry
        self.depth = depth
        self.palette = palette
        self.isExpanded = isExpanded
        self.isStreaming = isStreaming
        self.computed = computed
        self.actions = actions
    }

    public var body: some View {
        let entryID = entry.id.stableString
        VStack(alignment: .leading, spacing: Theme.Spacing.verticalStack) {
            Button {
                actions.onToggleExpansion(entryID)
            } label: {
                EntryHeaderView(
                    header: entry.header,
                    palette: palette,
                    accent: accentColor,
                    emphasized: entry.isEmphasized,
                    chip: chipDisplay,
                    pulseIcon: pulseIcon,
                    isExpanded: isExpanded,
                    titleTruncation: entry.titleTruncation
                )
            }
            .buttonStyle(.plain)
            .hoverHighlight(palette: palette, accent: accentColor)

            if isExpanded {
                expandedContent
            }
        }
        .padding(.leading, depth == 0 ? 0 : Theme.Indent.unit)
        .id(entryID)
    }

    @ViewBuilder
    private var expandedContent: some View {
        switch entry.expansionShape {
        case .children(let kids):
            childrenList(kids: kids)
        case .body(let body):
            EntryBodyView(
                entryBody: body,
                computed: computed.sections,
                palette: palette,
                onOpenDetail: { sectionIndex in
                    actions.onOpenDetail(.bodySection(
                        targetID: entry.id.stableString,
                        sectionIndex: sectionIndex
                    ))
                }
            )
            // Body text box leading offset = icon width + half the
            // icon-text gap. Sits 3pt left of the sub-entry indent
            // column so the gray box reads as part of the entry's body
            // rather than as a child row.
            .padding(.leading, Theme.Metric.entryIconWidth + Theme.Spacing.entryIconText / 2)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func childrenList(kids: [Entry]) -> some View {
        // Abandoned-branch (rewind) sub-trees render in the rewind's
        // own ``HudPalette/dim`` color uniformly. Achieved by passing
        // ``HudPalette/dimmed`` (a variant where every per-kind accent
        // collapses to dim) down the recursion. Leaf views never see
        // the override — they keep reading `palette.X` as usual; the
        // palette itself returns dim for every accessor. Idempotent:
        // nested rewinds compose without compounding.
        let kidPalette = isAbandonedBranch ? palette.dimmed : palette
        LazyVStack(alignment: .leading, spacing: Theme.Padding.entryGap) {
            ForEach(kids, id: \.id.stableString) { kid in
                EntryView(
                    entry: kid,
                    depth: depth + 1,
                    palette: kidPalette,
                    isExpanded: actions.isExpanded(kid.id.stableString),
                    isStreaming: false,
                    computed: actions.computed(kid),
                    actions: actions
                )
                .equatable()
            }
        }
        .overlay(alignment: .leading) {
            // Expansion gutter — colored with the parent (this) entry's
            // accent. Sits at the parent's icon-right-edge in this
            // view's content coordinate space. The header pins the icon
            // to ``Theme/Metric/entryIconWidth`` so the offset is
            // geometrically stable regardless of which SF Symbol renders.
            //
            // ``GutterRail`` owns its own hover state so EntryView
            // stays free of @State. Click anywhere in the rail's
            // wide hit strip toggles the parent's expansion (mirrors
            // clicking the parent header).
            let parentID = entry.id.stableString
            GutterRail(accentColor: accentColor) {
                actions.onToggleExpansion(parentID)
            }
        }
    }

    /// True when this entry is a `.synthesized(.rewind)` — its
    /// expanded children render dimmed via a subtree-wide opacity.
    private var isAbandonedBranch: Bool {
        if case .synthesized(let s) = entry,
           case .rewind = s.kind {
            return true
        }
        return false
    }

    /// Per-Entry-kind accent. Single source of truth in
    /// ``PaletteRole/forEntry(_:)`` covers every kind including
    /// sub-entries (text → claude, tool → status-derived).
    private var accentColor: Color {
        PaletteRole.forEntry(entry).map { palette.color(for: $0) } ?? palette.primary
    }

    /// Pulse the header icon when:
    /// - this is a queued, still-pending UserEntry, OR
    /// - this is the agent turn currently streaming, OR
    /// - this is a tool sub-entry whose status is `.pending`.
    private var pulseIcon: Bool {
        switch entry {
        case .user(let u):
            return u.queuedState == .pending
        case .agent:
            return isStreaming
        case .tool(let t):
            return t.status == .pending
        default:
            return false
        }
    }

    /// Optional inline chip rendered between `label` and `title`.
    /// Only the Task tool's `subagent_type` populates it today.
    private var chipDisplay: HeaderChipDisplay? {
        guard case .tool(let t) = entry,
              let chip = t.subagentType,
              !chip.isEmpty
        else { return nil }
        return HeaderChipDisplay(text: chip, color: palette.magenta)
    }

    nonisolated public static func == (lhs: EntryView, rhs: EntryView) -> Bool {
        lhs.entry == rhs.entry
            && lhs.depth == rhs.depth
            && lhs.palette == rhs.palette
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isStreaming == rhs.isStreaming
            && lhs.computed == rhs.computed
        // actions intentionally true-always per snapshot-boundary policy
    }
}

/// Visible expansion gutter for a parent entry's children-list.
/// Painted in the parent's accent color at low opacity; brightens on
/// hover. Click anywhere in the wide hit strip toggles the parent's
/// expansion. Owns its own hover state so the surrounding ``EntryView``
/// stays free of `@State`.
@available(macOS 15, *)
private struct GutterRail: View {
    let accentColor: Color
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(accentColor.opacity(hovering ? Theme.Opacity.dim : Theme.Opacity.gutter))
            .frame(width: Theme.Stroke.gutter)
            .frame(width: Theme.Indent.unit, alignment: .center)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: Theme.Timing.quick), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture(perform: onTap)
    }
}
