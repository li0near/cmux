import Foundation

/// CmuxAgentXray — self-contained Swift package providing the AgentX-ray
/// feature for cmux: a side-by-side companion panel that mirrors the
/// Claude Code or Codex session running in the workspace's currently
/// focused terminal.
///
/// Architecture (data flow):
///
///     JSONL file
///       → Streaming        (file watch, line stream)
///       → Adapters         (Claude / Codex transcript builders)
///       → Models           (Entry tree: Entry { Header + Body })
///       → Behavior         (expansion / visibility / anchors)
///       → Snapshots        (view-input DTOs)
///       → Views            (LazyVStack rendering)
///       → Panel            (@Observable ViewModel)
///       ⇄  Host            (cmux app integration via AgentXrayHost protocol)
///
/// Vocabulary inside this package:
/// - **Entry** — umbrella for every transcript item (5 top-level cases:
///   user, agent, system, compact, synthesized).
/// - **Transcript** — a `[Entry]` document.
/// - **AgentTurn** — the only container Entry; carries `subEntries`.
/// - **Header** / **Body** — every Entry's display contract.
///
/// The package never imports cmux types. All cmux integration runs
/// through `AgentXrayHost`. See `Packages/CmuxAgentXray/README.md` and
/// `~/.claude/plans/agentxray-migration-2026-06-04.md` for details.
@available(macOS 15, *)
public enum AgentXrayModule {
    /// Module marker. Phase 1 placeholder kept for the smoke test;
    /// type renamed from `CmuxAgentXray` → `AgentXrayModule` to avoid
    /// shadowing the module name (callers spelling
    /// `CmuxAgentXray.AgentXrayPanel` would otherwise parse as enum
    /// case access).
    public static let moduleName: String = "CmuxAgentXray"
}
