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
/// Recursion: `.subentries` sections (AgentEntry body, branch-link
/// body, tool sidechains) call back into this view via the
/// `renderSubEntry` closure provided by the parent panel view. The
/// closure isolates SwiftUI's view identity tracking so the parent
/// can decide whether to recurse inline or surface a link.
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
    public let renderSubEntry: (Entry) -> AnyView

    public init(
        entry: Entry,
        computed: EntryComputedCache.Computed,
        palette: HudPalette,
        displayMode: DisplayMode,
        isExpanded: Bool,
        isStreaming: Bool = false,
        onToggleExpansion: @escaping () -> Void,
        onOpenDetail: @escaping () -> Void,
        renderSubEntry: @escaping (Entry) -> AnyView
    ) {
        self.entry = entry
        self.computed = computed
        self.palette = palette
        self.displayMode = displayMode
        self.isExpanded = isExpanded
        self.isStreaming = isStreaming
        self.onToggleExpansion = onToggleExpansion
        self.onOpenDetail = onOpenDetail
        self.renderSubEntry = renderSubEntry
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
                    onOpenDetail: onOpenDetail,
                    renderSubEntry: renderSubEntry
                )
                .padding(.leading, Theme.Indent.subRow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Padding.horizontal)
        .padding(.vertical, Theme.Spacing.verticalStack)
    }

    /// Variant-specific accent color override. nil = palette.primary.
    /// Per-kind color rules per `PARITY_PUNCH_LIST.md` §3.3 + §3.14:
    ///   user            → blue (queued or normal)
    ///   agent           → claude
    ///   system          → per-subType:
    ///                     • localCommand / slashCmd / skill / recap /
    ///                       planMode / editedTextFile / other → cyan
    ///                     • systemReminder                    → yellow
    ///                     • contextUsage                      → dim
    ///   compact         → dim
    ///   synthesized     → per-kind:
    ///                     • branchLink                        → dim
    ///                     • prLink                            → blue
    private var kindAccentColor: Color? {
        switch entry {
        case .user:
            return palette.blue
        case .agent:
            return palette.claude
        case .system(let sys):
            switch sys.subType {
            case .systemReminder:
                return palette.yellow
            case .contextUsage:
                return palette.dim
            case .localCommand,
                 .slashCmdInput,
                 .slashCmdOutput,
                 .skill,
                 .recap,
                 .planMode,
                 .editedTextFile,
                 .other:
                return palette.cyan
            }
        case .compact:
            return palette.dim
        case .synthesized(let syn):
            switch syn.kind {
            case .branchLink: return palette.dim
            case .prLink:     return palette.blue
            }
        }
    }

    /// Pulse the header icon when:
    /// - this is a queued, still-pending UserEntry (user typed
    ///   mid-turn; not yet consumed by the next API call), OR
    /// - this is the agent turn currently streaming.
    private var shouldPulseIcon: Bool {
        switch entry {
        case .user(let user):
            return user.isQueuedPending
        case .agent:
            return isStreaming
        default:
            return false
        }
    }
}
