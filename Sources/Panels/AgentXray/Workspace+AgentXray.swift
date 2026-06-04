import AppKit
import Bonsplit
import CmuxAgentXray
import Foundation

/// Workspace-side factory methods + detail-tab routing for AgentX-ray
/// panels.
///
/// All factories instantiate `AgentXrayPanelAdapter` (which lazy-binds
/// to the workspace's shared `AgentXrayWorkspaceHost`). The detail
/// routing helper is invoked by the host's `openDetailTab(...)` method
/// — kept here as an extension on `Workspace` because it does Workspace
/// bookkeeping (panels dictionary, surface-id mapping, bonsplit tab
/// creation) that's natural to express on the Workspace itself.
@available(macOS 15, *)
extension Workspace {

    /// Split a pane and place a new live AgentX-ray panel in the new
    /// sibling. Mirrors `splitPaneWithMarkdown`'s shape. Used by the
    /// Debug-menu entry so the AgentX-ray panel sits side-by-side with
    /// the focused terminal across multiple terminal-tab switches in
    /// the original pane.
    @discardableResult
    func splitPaneWithAgentXray(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool
    ) -> AgentXrayPanelAdapter? {
        let panel = AgentXrayPanelAdapter(workspace: self)
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle

        let newTab = Bonsplit.Tab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.agentXray,
            isDirty: false,
            isLoading: false,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = panel.id

        guard bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst
        ) != nil else {
            #if DEBUG
            cmuxDebugLog("agentXray.split.fail panel=\(panel.id.uuidString.prefix(6))")
            #endif
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            return nil
        }

        bonsplitController.selectTab(newTab.id)
        focusPanel(panel.id)

        publishCmuxSurfaceCreated(
            panel.id,
            paneId: paneId,
            kind: SurfaceKind.agentXray,
            origin: "agent_xray_split",
            focused: true
        )

        #if DEBUG
        cmuxDebugLog("agentXray.split.created panel=\(panel.id.uuidString.prefix(6)) tab=\(newTab.id) origin=\(paneId)")
        #endif
        return panel
    }

    @discardableResult
    func newAgentXraySurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> AgentXrayPanelAdapter? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)

        let panel = AgentXrayPanelAdapter(workspace: self)
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle

        #if DEBUG
        cmuxDebugLog("agentXray.factory.created panel=\(panel.id.uuidString.prefix(6)) title=\(panel.displayTitle) pane=\(paneId)")
        #endif

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
            #if DEBUG
            cmuxDebugLog("agentXray.factory.fail reason=createTab_returned_nil panel=\(panel.id.uuidString.prefix(6))")
            #endif
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = panel.id

        #if DEBUG
        cmuxDebugLog("agentXray.factory.tab_created tab=\(newTabId) panel=\(panel.id.uuidString.prefix(6))")
        #endif

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
            #if DEBUG
            cmuxDebugLog("agentXray.factory.focused tab=\(newTabId)")
            #endif
        }

        return panel
    }

    /// Detail-tab routing path. Called by `AgentXrayWorkspaceHost
    /// .openDetailTab(content:fromPanelID:)` when a row's `↗ Open
    /// detail` link fires. Opens a sibling AgentX-ray tab in the same
    /// pane as the source live panel, in `.detail` mode.
    @discardableResult
    func openAgentXrayDetail(
        content: DetailContent,
        fromPanelID: UUID
    ) -> AgentXrayPanelAdapter? {
        // Find the pane that hosts the source panel.
        guard let sourceTabId = surfaceIdFromPanelId(fromPanelID),
              let paneId = bonsplitController.allPaneIds.first(where: { paneId in
                  bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == sourceTabId })
              }) else {
            return nil
        }

        let detailPanel = AgentXrayPanelAdapter(workspace: self, detail: content)
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
