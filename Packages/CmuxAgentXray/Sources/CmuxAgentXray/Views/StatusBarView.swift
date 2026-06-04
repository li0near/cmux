public import SwiftUI

/// Status bar at the top of the transcript panel:
///
///     [glyph]  attached <session>           scroll: snap   ↻ ⇲ ⇣⇡ ⇡⇣
///
/// Carries:
/// - Leading glyph (●/◐) — `HudGlyph.activeDot` when detached;
///   `HudGlyph.runningCircle` when attached.
/// - Title — "attached <kind> <session…>  <cwd>" or the
///   localized "no agent session focused" placeholder.
/// - Scroll-mode pill — toggles `.snap` / `.free`.
/// - Four control buttons — rewind toggle, auto-expand toggle,
///   collapse-all, expand-all. Disabled buttons render via
///   SwiftUI's `.disabled(!canX)` modifier (system auto-dim) — no
///   manual opacity overrides.
///
/// **Snapshot-boundary policy:** value-typed inputs and stable closures
/// only. Caller (`TranscriptView`) projects panel state once and
/// passes flags + handlers in.
@available(macOS 15, *)
public struct StatusBarView: View {

    public let palette: HudPalette
    public let resolvedSessionTitle: String?
    public let isAttached: Bool
    public let scrollMode: ScrollMode
    public let rewindVisibility: RewindVisibility
    public let expansionMode: ExpansionMode
    public let canCollapse: Bool
    public let canExpand: Bool

    public let onToggleScrollMode: () -> Void
    public let onCycleRewindVisibility: () -> Void
    public let onCycleExpansionMode: () -> Void
    public let onCollapseAll: () -> Void
    public let onExpandAll: () -> Void

    public init(
        palette: HudPalette,
        resolvedSessionTitle: String?,
        isAttached: Bool,
        scrollMode: ScrollMode,
        rewindVisibility: RewindVisibility,
        expansionMode: ExpansionMode,
        canCollapse: Bool,
        canExpand: Bool,
        onToggleScrollMode: @escaping () -> Void,
        onCycleRewindVisibility: @escaping () -> Void,
        onCycleExpansionMode: @escaping () -> Void,
        onCollapseAll: @escaping () -> Void,
        onExpandAll: @escaping () -> Void
    ) {
        self.palette = palette
        self.resolvedSessionTitle = resolvedSessionTitle
        self.isAttached = isAttached
        self.scrollMode = scrollMode
        self.rewindVisibility = rewindVisibility
        self.expansionMode = expansionMode
        self.canCollapse = canCollapse
        self.canExpand = canExpand
        self.onToggleScrollMode = onToggleScrollMode
        self.onCycleRewindVisibility = onCycleRewindVisibility
        self.onCycleExpansionMode = onCycleExpansionMode
        self.onCollapseAll = onCollapseAll
        self.onExpandAll = onExpandAll
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.rowIconText) {
            Text(isAttached ? HudGlyph.runningCircle : HudGlyph.activeDot)
                .font(Theme.StatusBar.icon)
                .foregroundStyle(isAttached ? palette.yellow : palette.dim)
            Text(title)
                .font(Theme.StatusBar.title)
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Spacing.rowIconText)
            HStack(spacing: Theme.Spacing.subRowIconText) {
                scrollModePill
                rewindButton
                expansionButton
                collapseButton
                expandButton
            }
        }
        .frame(height: Theme.Height.statusBar)
        .padding(.horizontal, Theme.Padding.horizontal)
    }

    private var title: String {
        if let resolvedSessionTitle {
            return resolvedSessionTitle
        }
        return String(
            localized: "agentXray.statusBar.detached",
            defaultValue: "no agent session focused",
            bundle: .module
        )
    }

    // MARK: - Scroll-mode pill

    private var scrollModePill: some View {
        let accent: Color = scrollMode == .snap ? palette.green : palette.dim
        return Button(action: onToggleScrollMode) {
            HStack(spacing: Theme.Spacing.tight) {
                Text("scroll:")
                    .foregroundStyle(palette.dim)
                Text(scrollMode.label)
                    .foregroundStyle(accent)
            }
            .font(Theme.StatusBar.pillLabel)
            .padding(.horizontal, Theme.Padding.pillHorizontal)
            .frame(height: Theme.Height.pill)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.pill)
                    .stroke(accent.opacity(Theme.Opacity.dim), lineWidth: Theme.Stroke.pill)
            )
        }
        .buttonStyle(.plain)
        .hoverBars(palette: palette)
    }

    // MARK: - Control buttons

    private var rewindButton: some View {
        let visible = rewindVisibility == .link
        return iconButton(
            systemName: EntryIcon.branchLink.collapsed,
            color: visible ? palette.cyan : palette.dim,
            action: onCycleRewindVisibility,
            disabled: false
        )
    }

    private var expansionButton: some View {
        let on = expansionMode == .autoExpand
        return iconButton(
            systemName: "arrow.up.left.and.arrow.down.right",
            color: on ? palette.cyan : palette.dim,
            action: onCycleExpansionMode,
            disabled: false
        )
    }

    private var collapseButton: some View {
        iconButton(
            systemName: "rectangle.compress.vertical",
            color: palette.dim,
            action: onCollapseAll,
            disabled: !canCollapse
        )
    }

    private var expandButton: some View {
        iconButton(
            systemName: "rectangle.expand.vertical",
            color: palette.dim,
            action: onExpandAll,
            disabled: !canExpand
        )
    }

    private func iconButton(
        systemName: String,
        color: Color,
        action: @escaping () -> Void,
        disabled: Bool
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(Theme.StatusBar.icon)
                .foregroundStyle(color)
                .frame(width: Theme.Height.iconButton, height: Theme.Height.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .hoverBars(palette: palette)
    }
}
