import SwiftUI
import AppKit

/// Status bar at the top of the live Agent Inspector panel. Shows session
/// attach state, an icon-pill row of toggles + actions, and the line
/// count. Extracted from `AgentInspectorPanelView` so the pill row's
/// composition is isolated and additions don't bloat the panel view.
struct InspectorStatusBar: View {
    @ObservedObject var panel: AgentInspectorPanel
    let appearance: PanelAppearance

    var body: some View {
        HStack(spacing: 8) {
            Text(statusGlyph)
                .foregroundColor(statusGlyphColor)
            Text(statusText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: appearance.foregroundColor))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            pillRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Pill row

    /// Icon-pill row, left-to-right:
    ///   1. Scroll mode (label-pill, always visible).
    ///   2. Rewinds visibility toggle (icon, always visible).
    ///   3. Snap-expand mode toggle — only relevant in snap mode.
    ///   4. Collapse all (action, always visible).
    ///   5. Expand snap (action) — only relevant in snap mode.
    ///
    /// Pills 3 and 5 are hidden when sync is `.off` because expansion
    /// rules anchored to the snap turn don't apply when every chunk
    /// renders.
    private var pillRow: some View {
        HStack(spacing: 6) {
            syncModePill
            iconButton(
                systemName: InspectorIcon.branchLink.collapsed,
                color: panel.rewindVisibility == .hide ? palette.dim : palette.cyan,
                tooltip: panel.rewindVisibility == .hide
                    ? "Show rewound branch links"
                    : "Hide rewound branch links",
                action: { panel.rewindVisibility = panel.rewindVisibility.cycled() }
            )
            if panel.syncMode == .snap {
                iconButton(
                    systemName: "arrow.up.left.and.arrow.down.right",
                    color: panel.expansionMode == .autoExpandSnap ? palette.cyan : palette.dim,
                    tooltip: panel.expansionMode == .autoExpandSnap
                        ? "Auto-expand snap turn: on"
                        : "Auto-expand snap turn: off",
                    action: { panel.expansionMode = panel.expansionMode.cycled() }
                )
            }
            iconButton(
                systemName: "rectangle.compress.vertical",
                color: palette.dim,
                tooltip: "Collapse: 1st click closes sub-items, 2nd closes everything",
                action: { panel.collapseAll() }
            )
            if panel.syncMode == .snap {
                iconButton(
                    systemName: "rectangle.expand.vertical",
                    color: palette.dim,
                    tooltip: "Expand snap: 1st click opens AI chunks, 2nd opens tools",
                    action: { panel.expandSnap() }
                )
            }
        }
    }

    private var syncModePill: some View {
        Button(action: { panel.syncMode = nextSyncMode(after: panel.syncMode) }) {
            HStack(spacing: 4) {
                Text("scroll:")
                    .foregroundColor(Color(nsColor: appearance.foregroundColor).opacity(0.55))
                Text(panel.syncMode.label)
                    .foregroundColor(syncModeAccent)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(syncModeAccent.opacity(0.45), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func iconButton(
        systemName: String,
        color: Color,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundColor(color)
                .frame(width: 22, height: 22)
                .background(Color.black.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Status glyph + text

    private var palette: HudPalette { HudPalette(appearance: appearance) }

    private var statusGlyph: String {
        panel.resolvedSession == nil ? HudGlyph.activeDot : HudGlyph.runningCircle
    }

    private var statusGlyphColor: Color {
        panel.resolvedSession == nil ? palette.dim : palette.yellow
    }

    private var statusText: String {
        if let session = panel.resolvedSession {
            let prefix = String(session.sessionId.prefix(8))
            return String(
                localized: "agentInspector.status.attached",
                defaultValue: "attached \(session.agentKind.rawValue) \(prefix) — \(session.cwd ?? "")"
            )
        }
        return String(
            localized: "agentInspector.status.detached",
            defaultValue: "no agent attached — focus a terminal running claude"
        )
    }

    private var syncModeAccent: Color {
        switch panel.syncMode {
        case .off: return palette.dim
        case .snap: return palette.green
        }
    }

    private func nextSyncMode(after mode: InspectorSyncMode) -> InspectorSyncMode {
        switch mode {
        case .off: return .snap
        case .snap: return .off
        }
    }
}
