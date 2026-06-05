import SwiftUI

@available(macOS 15, *)
extension AgentEntryView {

    /// Unified header chrome for every agent sub-entry kind (thinking,
    /// tool, assistant text). One row of:
    ///
    ///     [icon (subRowIconWidth, iconColor)]
    ///     [name (Theme.Row.name, nameAccent)]
    ///     [extras] -- caller-supplied (e.g. tool's magenta chip)
    ///     [title? (Theme.Row.summary, dim, middle-truncated)]
    ///     [Spacer]
    ///     [trailing pills (Theme.SubRow.meta, dim)]
    ///     [timeMarker (e.g. "X ms" for tools)]
    ///
    /// Sub-entries thus render uniformly regardless of kind. The
    /// `extras` builder is for the rare per-kind affordances (today
    /// only the Task tool's magenta sub-agent chip); thinking and
    /// assistant text leave it empty.
    @ViewBuilder
    func subEntryHeader<Extras: View>(
        icon: EntryIcon?,
        isExpanded: Bool,
        iconColor: Color,
        nameAccent: Color,
        name: String,
        title: String? = nil,
        trailing: [TrailingItem] = [],
        timeMarker: TimeMarker? = nil,
        @ViewBuilder extras: () -> Extras = { EmptyView() }
    ) -> some View {
        HStack(spacing: Theme.Spacing.subRowIconText) {
            if let icon {
                Image(systemName: icon.systemName(expanded: isExpanded))
                    .font(Theme.SubRow.icon)
                    .foregroundStyle(iconColor)
                    .frame(width: Theme.Metric.subRowIconWidth)
            }
            Text(name)
                .font(Theme.SubRow.name)
                .foregroundStyle(nameAccent)
                .lineLimit(1)
            extras()
            if let title, !title.isEmpty {
                Text(title)
                    .font(Theme.Row.summary)
                    .foregroundStyle(palette.primary.opacity(Theme.Opacity.detail))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Spacing.tight)
            ForEach(Array(trailing.enumerated()), id: \.offset) { _, item in
                subEntryTrailingItem(item)
            }
            if let timeMarker {
                Text(timeMarker.displayString)
                    .font(Theme.SubRow.meta)
                    .foregroundStyle(palette.dim)
            }
        }
        .padding(.leading, Theme.Indent.subRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Trailing-item rendering for sub-row headers. Sub-rows use the
    /// dim meta font for every kind today; status dots / token pills
    /// are top-level-only and degrade to empty here.
    @ViewBuilder
    private func subEntryTrailingItem(_ item: TrailingItem) -> some View {
        switch item {
        case .text(let s),
             .wordCount(let s),
             .pill(let s):
            Text(s)
                .font(Theme.SubRow.meta)
                .foregroundStyle(palette.dim)
        case .statusDot, .tokenPill:
            EmptyView()
        }
    }
}
