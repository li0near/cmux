import SwiftUI

@available(macOS 15, *)
extension AgentEntryView {

    /// Render a text sub-entry — either a thinking block or an
    /// assistant response. Both share the same chrome (unified
    /// `subEntryHeader`) plus the shared `cappedTextBlock` body. The
    /// `kind` discriminator selects per-kind icon / color / italic
    /// flag at the view layer; the data model stays merged in
    /// `TextSubEntry`.
    @ViewBuilder
    func textSection(text: TextSubEntry) -> some View {
        let key = text.id.stableString
        let isExpanded = isSubEntryExpanded(key)
        let trailing: [TrailingItem] = text.wordCount > 0
            ? [.wordCount("\(text.wordCount) words")]
            : []

        let icon: EntryIcon = (text.kind == .thinking) ? .thinking : .assistantText
        let accent: Color = palette.claude
        let displayName = (text.kind == .thinking) ? "thinking" : "assistant"

        VStack(alignment: .leading, spacing: 2) {
            Button {
                onToggleExpansion(.text(subEntryID: key))
            } label: {
                subEntryHeader(
                    icon: icon,
                    isExpanded: isExpanded,
                    iconColor: accent,
                    nameAccent: accent,
                    name: displayName,
                    trailing: trailing
                )
            }
            .buttonStyle(.plain)
            .hoverHighlight(palette: palette)

            if isExpanded {
                cappedBody(text.body) { sectionIndex in
                    onOpenDetail(.bodySection(
                        targetID: text.id.stableString,
                        sectionIndex: sectionIndex
                    ))
                }
                .padding(.leading, Theme.Indent.nestedSubEntry)
            }
        }
    }
}
