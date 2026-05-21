import Foundation
import Bonsplit

/// Workspace factory for `AgentInspectorPanel`. Mirrors the structure of
/// `Workspace.newMarkdownSurface(inPane:)` (Sources/Workspace.swift:10982).
///
/// Lives in the AgentInspector directory to keep upstream `Workspace.swift`
/// untouched by this fork-side feature; merges from upstream cmux do not need
/// to reconcile this file.
extension Workspace {
    /// Adds an Agent Inspector tab to an existing pane (no split).
    /// Useful when the user wants to stack inspector views as tabs.
    @discardableResult
    func newAgentInspectorSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> AgentInspectorPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)

        let inspectorPanel = AgentInspectorPanel(workspace: self)
        panels[inspectorPanel.id] = inspectorPanel
        panelTitles[inspectorPanel.id] = inspectorPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: inspectorPanel.displayTitle,
            icon: inspectorPanel.displayIcon,
            kind: SurfaceKind.agentInspector,
            isDirty: inspectorPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: inspectorPanel.id)
            panelTitles.removeValue(forKey: inspectorPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = inspectorPanel.id
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            inspectorPanel.id,
            paneId: paneId,
            kind: SurfaceKind.agentInspector,
            origin: "agent_inspector_tab",
            focused: shouldFocusNewTab
        )
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            focusPanel(inspectorPanel.id)
        }
        return inspectorPanel
    }

    /// Splits the target pane and places a new Agent Inspector panel in the
    /// freshly-created sibling pane. This is the canonical entry point for
    /// the "side-by-side" UX described in the implementation plan — the
    /// inspector should sit alongside the focused terminal so future phases
    /// can wire bidirectional scroll-sync between the two panes.
    ///
    /// Mirrors `Workspace.splitPaneWithMarkdown(targetPane:orientation:insertFirst:filePath:)`
    /// at Sources/Workspace.swift:11065.
    @discardableResult
    func splitPaneWithAgentInspector(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool
    ) -> AgentInspectorPanel? {
        let inspectorPanel = AgentInspectorPanel(workspace: self)
        panels[inspectorPanel.id] = inspectorPanel
        panelTitles[inspectorPanel.id] = inspectorPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: inspectorPanel.displayTitle,
            icon: inspectorPanel.displayIcon,
            kind: SurfaceKind.agentInspector,
            isDirty: inspectorPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = inspectorPanel.id

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst
        ) != nil else {
            panels.removeValue(forKey: inspectorPanel.id)
            panelTitles.removeValue(forKey: inspectorPanel.id)
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            return nil
        }

        bonsplitController.selectTab(newTab.id)
        focusPanel(inspectorPanel.id)
        publishCmuxSurfaceCreated(
            inspectorPanel.id,
            paneId: paneId,
            kind: SurfaceKind.agentInspector,
            origin: "agent_inspector_split",
            focused: true
        )
        return inspectorPanel
    }
}

/// Adds the AgentInspector kind alongside Workspace's existing surface kind
/// constants. Defining it as an extension keeps this constant out of the
/// upstream-edited file.
extension Workspace.SurfaceKind {
    static let agentInspector = "agentInspector"
}

extension Workspace {
    /// Opens a sibling **detail** tab in the same pane as the live inspector
    /// that triggered the request. Used by the `↗ Open detail` route in the
    /// transcript renderer when an expandable section overflows the inline
    /// cap.
    ///
    /// The detail tab uses the same `agentInspector` panel kind but in
    /// `.detail(content:)` mode — it does not stream and does not auto-attach
    /// to a session. Closing the detail tab is a normal tab close.
    @discardableResult
    func openAgentInspectorDetail(
        content: AgentInspectorDetailContent,
        fromInspectorPanelId inspectorPanelId: UUID
    ) -> AgentInspectorPanel? {
        guard let paneId = paneId(forPanelId: inspectorPanelId) else {
            return nil
        }

        let detailPanel = AgentInspectorPanel(workspace: self, detail: content)
        panels[detailPanel.id] = detailPanel
        panelTitles[detailPanel.id] = detailPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: detailPanel.displayTitle,
            icon: detailPanel.displayIcon,
            kind: SurfaceKind.agentInspector,
            isDirty: detailPanel.isDirty,
            isLoading: false,
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
            kind: SurfaceKind.agentInspector,
            origin: "agent_inspector_detail",
            focused: true
        )
        bonsplitController.focusPane(paneId)
        bonsplitController.selectTab(newTabId)
        focusPanel(detailPanel.id)
        return detailPanel
    }
}
