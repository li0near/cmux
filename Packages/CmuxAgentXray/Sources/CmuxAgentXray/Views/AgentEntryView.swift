public import SwiftUI

/// Specialized renderer for a single `AgentEntry`. Renders the entry's
/// header through `EntryHeaderView`; when expanded, dispatches each
/// child `SubEntry` to its per-kind extension method
/// (``thinkingSection``, ``toolSection``, ``assistantTextSection``).
///
/// Per-kind agent sub-entry rendering doesn't fit the unified
/// `EntryView`'s generic recursion path because thinking / tool /
/// assistantText each need bespoke chrome (line counts, status dots,
/// sub-agent chips, italic body, link-style assistant response).
/// Splitting into extension files (`AgentEntryView+Thinking.swift`,
/// `+Tool.swift`, `+AssistantText.swift`) mirrors the pattern used in
/// `Panel/AgentXrayPanel+*.swift`.
///
/// **Snapshot-boundary policy:** holds only value-typed inputs and
/// stable closures — never an `@ObservedObject` / `@Bindable`
/// reference. The parent panel view computes the expansion / streaming
/// flags up front and passes them through; sub-entry expansion is
/// projected via the `isSubEntryExpanded` lookup closure so child
/// extensions don't need direct panel access either.
@available(macOS 15, *)
public struct AgentEntryView: View {

    public let entry: AgentEntry
    public let palette: HudPalette
    /// Whether this entry's body is currently expanded.
    public let isExpanded: Bool
    /// True when this is the trailing agent turn currently streaming —
    /// drives the header glyph's pulse animation.
    public let isStreaming: Bool
    /// Lookup closure: given a sub-entry expansion key, report whether
    /// it's currently in the expanded set. Used by per-kind extensions.
    public let isSubEntryExpanded: (String) -> Bool
    /// Bubble an expansion toggle up to the panel.
    public let onToggleExpansion: (AgentXrayPanel.ExpansionToggle) -> Void
    /// Bubble a detail-tab open request up to the panel.
    public let onOpenDetail: (DetailRequest) -> Void

    public init(
        entry: AgentEntry,
        palette: HudPalette,
        isExpanded: Bool,
        isStreaming: Bool,
        isSubEntryExpanded: @escaping (String) -> Bool,
        onToggleExpansion: @escaping (AgentXrayPanel.ExpansionToggle) -> Void,
        onOpenDetail: @escaping (DetailRequest) -> Void
    ) {
        self.entry = entry
        self.palette = palette
        self.isExpanded = isExpanded
        self.isStreaming = isStreaming
        self.isSubEntryExpanded = isSubEntryExpanded
        self.onToggleExpansion = onToggleExpansion
        self.onOpenDetail = onOpenDetail
    }

    public var body: some View {
        let entryID = entry.id.stableString
        VStack(alignment: .leading, spacing: Theme.Spacing.verticalStack) {
            Button {
                onToggleExpansion(.entry(id: entryID))
            } label: {
                EntryHeaderView(
                    header: entry.header,
                    palette: palette,
                    pulseIcon: isStreaming,
                    kindAccentColor: palette.claude,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(entry.subEntries, id: \.id.stableString) { sub in
                    subEntrySection(sub: sub)
                }
            }
        }
        .padding(.horizontal, Theme.Padding.horizontal)
        .padding(.vertical, Theme.Spacing.verticalStack)
        .id(entryID)
    }

    /// Dispatch on the `Entry` sub-entry — only `.text` / `.tool`
    /// cases ever appear inside an agent turn (post-G1.5; the builder
    /// + `Transcript.append`'s DEBUG assert enforce this). Other
    /// cases fall through to a no-op rather than crashing in release.
    @ViewBuilder
    private func subEntrySection(sub: Entry) -> some View {
        switch sub {
        case .text(let t):
            textSection(text: t)
        case .tool(let tool):
            toolSection(tool: tool)
        case .user, .agent, .system, .compact, .synthesized:
            EmptyView()
        }
    }
}
