public import SwiftUI

/// Status bar at the top of the transcript panel:
///
///     [glyph]  attached <session>           scroll: snap   ↻ ⇲ ⇣⇡ ⇡⇣
///
/// 3-color glyph precedence:
///   1. stream error or no resolved session → **red**
///   2. session but no entries yet           → **yellow** (stage label)
///   3. else                                 → **green** (attached title)
///
/// `AttachStage` drives the yellow-state label. Stream errors override
/// the entire status text with the error message.
///
/// **Snapshot-boundary policy:** value-typed inputs and stable closures
/// only. Caller (`TranscriptView`) derives the stage + flags up front
/// and passes them in.
@available(macOS 15, *)
public struct StatusBarView: View {

    public let palette: HudPalette
    public let stage: AttachStage
    public let streamError: String?
    public let attachedTitle: String?
    public let scrollMode: ScrollMode
    public let rewindVisibility: RewindVisibility
    public let expansionMode: ExpansionMode
    public let canCollapse: Bool
    public let canExpand: Bool
    /// When non-nil, render a compact "Change" link beside the
    /// attached-title cluster. Wired by ``TranscriptView`` only when
    /// the resolved session's transport is ``SessionTransport/remote(_:)``
    /// — i.e. the session was attached via path 3's user-supplied id.
    /// Tapping calls the closure to clear the persisted id and re-
    /// surface the prompt.
    public let onClearRemoteSession: (() -> Void)?

    public let onToggleScrollMode: () -> Void
    public let onCycleRewindVisibility: () -> Void
    public let onCycleExpansionMode: () -> Void
    public let onCollapseAll: () -> Void
    public let onExpandAll: () -> Void

    public init(
        palette: HudPalette,
        stage: AttachStage,
        streamError: String?,
        attachedTitle: String?,
        scrollMode: ScrollMode,
        rewindVisibility: RewindVisibility,
        expansionMode: ExpansionMode,
        canCollapse: Bool,
        canExpand: Bool,
        onClearRemoteSession: (() -> Void)? = nil,
        onToggleScrollMode: @escaping () -> Void,
        onCycleRewindVisibility: @escaping () -> Void,
        onCycleExpansionMode: @escaping () -> Void,
        onCollapseAll: @escaping () -> Void,
        onExpandAll: @escaping () -> Void
    ) {
        self.palette = palette
        self.stage = stage
        self.streamError = streamError
        self.attachedTitle = attachedTitle
        self.scrollMode = scrollMode
        self.rewindVisibility = rewindVisibility
        self.expansionMode = expansionMode
        self.canCollapse = canCollapse
        self.canExpand = canExpand
        self.onClearRemoteSession = onClearRemoteSession
        self.onToggleScrollMode = onToggleScrollMode
        self.onCycleRewindVisibility = onCycleRewindVisibility
        self.onCycleExpansionMode = onCycleExpansionMode
        self.onCollapseAll = onCollapseAll
        self.onExpandAll = onExpandAll
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.entryIconText) {
            Text(glyph)
                .font(Theme.StatusBar.icon)
                .foregroundStyle(glyphColor)
            Text(title)
                .font(Theme.StatusBar.title)
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let onClearRemoteSession {
                Button(action: onClearRemoteSession) {
                    Text(changeText)
                        .font(Theme.StatusBar.title)
                        .foregroundStyle(palette.cyan)
                        .underline(true, color: palette.cyan.opacity(Theme.Opacity.dim))
                }
                .buttonStyle(.plain)
                .help(changeTooltip)
            }
            Spacer(minLength: Theme.Spacing.entryIconText)
            HStack(spacing: Theme.Spacing.subEntryIconText) {
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

    private var changeText: String {
        String(
            localized: "agentXray.remote.prompt.button.change",
            defaultValue: "Change",
            bundle: .module
        )
    }

    private var changeTooltip: String {
        String(
            localized: "agentXray.remote.prompt.button.change.tooltip",
            defaultValue: "Clear the saved session id and re-prompt",
            bundle: .module
        )
    }

    // MARK: - State derivation

    private enum ColorState {
        case red, yellow, green
    }

    private var colorState: ColorState {
        if streamError != nil { return .red }
        switch stage {
        case .idle, .awaitingSession:
            return .red
        case .sessionHooked, .locatingTranscript, .streamingNoEntries:
            return .yellow
        case .streaming:
            return .green
        }
    }

    private var glyph: String {
        switch colorState {
        case .red, .yellow: return HudGlyph.activeDot
        case .green:        return HudGlyph.runningCircle
        }
    }

    private var glyphColor: Color {
        switch colorState {
        case .red:    return palette.red
        case .yellow: return palette.yellow
        case .green:  return palette.green
        }
    }

    private var title: String {
        if let streamError {
            return String(
                localized: "agentXray.statusBar.streamError",
                defaultValue: "Stream error: \(streamError)",
                bundle: .module
            )
        }
        switch stage {
        case .idle, .awaitingSession:
            return String(
                localized: "agentXray.statusBar.detached",
                defaultValue: "no agent session focused",
                bundle: .module
            )
        case .sessionHooked(let id):
            return String(
                localized: "agentXray.statusBar.sessionHooked",
                defaultValue: "Session hooked: \(id.prefix(8))",
                bundle: .module
            )
        case .locatingTranscript:
            return String(
                localized: "agentXray.statusBar.locatingTranscript",
                defaultValue: "Locating transcript…",
                bundle: .module
            )
        case .streamingNoEntries:
            return String(
                localized: "agentXray.statusBar.streamingNoEntries",
                defaultValue: "Streaming — no entries yet",
                bundle: .module
            )
        case .streaming:
            return attachedTitle ?? String(
                localized: "agentXray.statusBar.attached",
                defaultValue: "attached",
                bundle: .module
            )
        }
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
    }

    // MARK: - Control buttons

    private var rewindButton: some View {
        let visible = rewindVisibility == .link
        return iconButton(
            // Status-bar pill carries different visual information than
            // the entry header glyph: it's a hide/show toggle indicator,
            // not a "this is a rewind" marker. Keep the original branch
            // fork glyph so the toggle reads as "branching state shown
            // vs hidden" (icon meaning preserved across the entry-icon
            // refresh that introduced the clock-badge variant for entry
            // headers).
            systemName: "arrow.triangle.branch",
            color: visible ? palette.cyan : palette.dim,
            action: onCycleRewindVisibility,
            disabled: false,
            tooltip: visible
                ? "Hide rewind / abandoned-branch links"
                : "Show rewind / abandoned-branch links"
        )
    }

    private var expansionButton: some View {
        let on = expansionMode == .autoExpand
        return iconButton(
            systemName: "arrow.up.left.and.arrow.down.right",
            color: on ? palette.cyan : palette.dim,
            action: onCycleExpansionMode,
            disabled: false,
            tooltip: on
                ? "Auto-expand new entries — click to switch to manual"
                : "Auto-expand new entries (currently off)"
        )
    }

    private var collapseButton: some View {
        iconButton(
            systemName: "rectangle.compress.vertical",
            color: palette.dim,
            action: onCollapseAll,
            disabled: !canCollapse,
            tooltip: "Collapse all entries"
        )
    }

    private var expandButton: some View {
        iconButton(
            systemName: "rectangle.expand.vertical",
            color: palette.dim,
            action: onExpandAll,
            disabled: !canExpand,
            tooltip: "Expand all entries"
        )
    }

    private func iconButton(
        systemName: String,
        color: Color,
        action: @escaping () -> Void,
        disabled: Bool,
        tooltip: String?
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
        .hoverHighlight(palette: palette, tooltip: tooltip)
    }
}
