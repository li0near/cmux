import AppKit
import Bonsplit
import CmuxAgentXray
import Foundation

/// Workspace-side factory methods + detail-tab routing for AgentX-ray
/// panels. Mirrors the spike's `Workspace+AgentInspector.swift` shape.
@available(macOS 15, *)
extension Workspace {

    /// Open a new live AgentX-ray panel as a tab in the given pane.
    /// Returns the host-wrapper panel; nil on tab creation failure.
    @discardableResult
    func newAgentXraySurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> AgentXrayPanelHost? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)

        let panel = AgentXrayPanelHost(workspace: self)
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.agentXray,
            isDirty: false,
            isLoading: false,
            isAudioMuted: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = panel.id

        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }

        publishCmuxSurfaceCreated(
            panel.id,
            paneId: paneId,
            kind: SurfaceKind.agentXray,
            origin: "agent_xray_tab",
            focused: shouldFocusNewTab
        )

        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            panel.focus()
        }

        return panel
    }

    /// Detail-tab routing path. Called by `AgentXrayWorkspaceHost
    /// .openDetailTab` when a row's `↗ Open detail` link fires. Opens
    /// a sibling AgentX-ray tab in the same pane as the source live
    /// panel, in `.detail` mode.
    @discardableResult
    func openAgentXrayDetail(
        content: DetailContent,
        fromPanelID: UUID,
        originPanelHost: AgentXrayPanelHost
    ) -> AgentXrayPanelHost? {
        // Find the pane that hosts the source panel.
        guard let sourceTabId = surfaceIdFromPanelId(fromPanelID),
              let paneId = bonsplitController.allPaneIds.first(where: { paneId in
                  bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == sourceTabId })
              }) else {
            return nil
        }

        let detailPanel = AgentXrayPanelHost(workspace: self, detail: content)
        panels[detailPanel.id] = detailPanel
        panelTitles[detailPanel.id] = detailPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: detailPanel.displayTitle,
            icon: detailPanel.displayIcon,
            kind: SurfaceKind.agentXray,
            isDirty: false,
            isLoading: false,
            isAudioMuted: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: detailPanel.id)
            panelTitles.removeValue(forKey: detailPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = detailPanel.id
        publishCmuxSurfaceCreated(
            detailPanel.id,
            paneId: paneId,
            kind: SurfaceKind.agentXray,
            origin: "agent_xray_detail",
            focused: true
        )
        bonsplitController.focusPane(paneId)
        bonsplitController.selectTab(newTabId)
        detailPanel.focus()

        return detailPanel
    }
}
