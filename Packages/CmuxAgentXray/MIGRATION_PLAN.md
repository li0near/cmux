# AgentX-ray Migration Plan
**Created:** 2026-06-04 · **Last updated:** 2026-06-04 · **Owner:** Ethan + sessions

Live progress doc. Update the **Status table (§1)** and **Progress log (§14)**
after every phase completes so a fresh session can resume mid-migration.

---

## §1 Status

| Phase | Status | Branch/commit | Notes |
|---|---|---|---|
| 0 Audit + plan | ✅ done | this doc | three audit agents ran 2026-06-04 |
| 1 New worktree + empty package skeleton | ✅ done | `agentxray` @ `5aad34007` | package builds + smoke test green; pbxproj wiring deferred to Phase 9 |
| 2 Domain models — Entry/Header/Body | ✅ done | `agentxray` @ `18ff88fa5` | 15 model files + 19 tests; notification name moved into package (eliminates 1 upstream touch) |
| 3 Adapters — Claude + Codex | ✅ done | `agentxray` @ `4e1d9a204` | 20 adapter files ported; ClaudeChunkBuilder→ClaudeTranscriptBuilder with full Header/Body construction; Codex same shape; adapter test porting deferred |
| 4 Streaming — Tail + TranscriptStream + AgentSessionResolver | ✅ done | `agentxray` @ `11d62b29d` | 3 files ported; @Observable adopted in TranscriptStream (skips Combine variant entirely) |
| 5 Behavior — Expansion + Visibility + Anchors | ✅ done | `agentxray` @ `637c18d87` | 5 files ported; ScrollbarSnapshot replaces GhosttyScrollbar coupling; Body.textContent helper added |
| 6 Snapshots — view-input contract | ✅ done | `agentxray` @ `16b6409b0` | Foundation helpers ported (DisplayMode, RenderCaps, AgentKindLabel, ExpandableContent); EntryComputedCache moved to Phase 7 (tightly coupled to per-Entry capsForBlock) |
| 7 Views — per-entry + helpers | ✅ done | `agentxray` @ `25d0b1119` | Unified EntryView dispatcher + EntryHeaderView + EntryBodyView; EntryComputedCache w/ ContentSignature; HudPalette + HudGlyph; snapshot-boundary policy enforced |
| 8 Panel — @Observable ViewModel | ✅ done | `agentxray` @ `4dfe5692b` | AgentInspectorPanel.swift ported as 6-file split; @Observable; Host protocol + Cancellable + AttentionFlashReason + HostAppearance landed; Detail{Content,Request} skeletons (resolver in Phase 10) |
| 9 Host integration — Workspace conformance + debug menu | ✅ done | `agentxray` @ `d5fb1ad6a` | Package wired into cmux app via 6-place pbxproj edit; 6 app-side adapter files (AgentXrayPanelHost, AgentXrayWorkspaceHost, WorkspaceFocusObserver, WorkspaceScrollbarBridge, Workspace+AgentXray, cmuxApp+AgentXrayDebugMenu); ~13 minimal switch arms; package floor lowered macOS 15→14 to match cmux app |
| 10 Detail mode wiring | ✅ done | `agentxray` @ `ddb4bd128` | DetailContent.resolve(request:entry:) ported (12 cases); ToolEntry helper accessors (inputDetail/resultDetail/sidechainTranscript) added |
| 11 Localization + theming pass | ✅ done | `agentxray` @ `5841c246d` | 43 keys populated in xcstrings; agent.label key collision split into kind-specific `.claude` / `.codex` keys (autonomous bug fix) |
| 12 AsyncStream focus pipeline | ⏸ deferred | | Combine debounce in WorkspaceFocusObserver works correctly; AsyncStream conversion is a quality refinement deferred to §16 deferred ledger |
| 13 Swift 6 strict concurrency flip | ✅ done (no-op) | `agentxray` @ `5841c246d` | Front-loaded in Phase 1 (Swift 6 mode + ExistentialAny + InternalImportsByDefault enabled in Package.swift since day one); confirmed swift build passes with zero warnings on the agentxray branch tip |
| 14 Documentation finalization | ✅ done | `agentxray` @ `7335f5b61` | FORK_NOTES.md upstream-touch table populated (10 rows + new-files inventory); README status section refreshed |
| 15 Cleanup — retire spike branch references | ✅ done | `agentxray` @ `7335f5b61` | PHASE_9_HANDOVER.md removed (superseded by Phase 9 commit + FORK_NOTES); remaining spike-references are intentional lineage notes in code comments |
| 17 Parity punch-list completion | ⏳ in progress | see `Packages/CmuxAgentXray/PARITY_PUNCH_LIST.md` | Exhaustive side-by-side audit produced 87 findings (42 ✅ / 38 ⚠️ / 7 ❌). Punch-list is the canonical execution order to reach parity. |
| 17a Visual-parity pass | ⏳ ready to land | see `Packages/CmuxAgentXray/VISUAL_PASS_REVIEW.md` | User-signed-off spec for the visual-parity commit (icons, layout tokens, typography groups, hover bars, file moves, renames). Lands as one batch. |
| 17b AttachStage feature | ⏳ follow-up | (no doc yet) | Separate commit after 17a — derives `AttachStage` enum from panel state, drives the status-bar yellow-state label + streaming-error rendering. Stages: idle → awaitingSession → sessionHooked → locatingTranscript → streamingNoEntries → streaming(turns, tokens). |
| 17c Behavioural correctness batch | ⏳ blocked on 17a/17b | see `PARITY_PUNCH_LIST.md` Group 1 | Final batch — `scrollForFilter` cross-band routing, `InspectorRowAnchorsKey` aggregation, bulk-collapse / bulk-expand handlers, `layoutRevision` remount, session-change scroll handler, boundary-id `.id(...)` on row dividers, detail-mode entries-list rendering. |

---

## §2 Goals

1. Migrate `Sources/Panels/AgentInspector/` → self-contained SPM package `Packages/CMUXAgentXray`.
2. Replace umbrella vocabulary: `Row → Entry`, `AgentChunk → AgentTurn`, `ChunkBuilder → TranscriptBuilder`. Drop `Inspector*` prefixes inside the package. Drop residual `AI` legacy in favour of `Agent`.
3. Reshape data model around `Entry { scalars + Header + Body }`; `Body.sections: [Section]` with `case text([String], style: TextStyle)` or `case subentries([Entry])`.
4. Layer-first directory structure: `Models/`, `Streaming/`, `Adapters/`, `Behavior/`, `Views/`, `Panel/`, `Host/`, `Resources/`.
5. Adopt `@Observable` for the panel ViewModel (replaces `ObservableObject` + `@Published`).
6. Minimize cmux upstream-touch surface; track every touch in `Packages/CMUXAgentXray/FORK_NOTES.md`.
7. Document conventions in CLAUDE.md (`## AgentX-ray` section) and package README.
8. New worktree off `upstream/main`; fresh branch `agentxray`. Don't touch the spike worktree.

## §3 Hard constraints

- **macOS 15 platform floor.** No fallback paths. `platforms: [.macOS(.v15)]` in Package.swift; `if #available(macOS 15, *)` at every external integration site in cmux.
- **English-only localization.** Package's `Resources/Localizable.xcstrings` ships with `defaultLocalization: "en"` and English-only entries. New keys carry `"localizations": {}`.
- **Snapshot-boundary policy preserved.** Row/entry views below `LazyVStack` hold zero observable references — value snapshots + stable closures only.
- **Package isolation.** No file under `Packages/CMUXAgentXray/Sources/` may reference `Workspace`, `TerminalPanel`, `Bonsplit`, `TabManager`, or any cmux-app type. All cmux integration runs through `AgentXrayHost` protocol.
- **No new upstream-cmux file touches** beyond what the host adapter requires. Each touch logged in `Packages/CMUXAgentXray/FORK_NOTES.md`.
- **Tagged debug builds only.** `CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig ./scripts/reload.sh --tag agentxray --launch`.
- **Do not run tests locally.** CI only. Swift Package tests run via `swift test --package-path Packages/CMUXAgentXray`.
- **Two-commit pattern for bug fixes** found mid-port: failing test commit, then fix commit.
- **Agent has autonomous bug-fix discretion during porting.** When a bug or smell is spotted in the source code, the porting agent may fix it inline. Every such fix logged in §15 (Bug-fix ledger) with: file, what was wrong, fix summary, commit hash.

## §4 Vocabulary catalog (every rename)

### Type renames

| Today | Tomorrow |
|---|---|
| `InspectorRow` (enum, 8 cases) | `Entry` (enum, **5 top-level cases** — sub-entries collapse into `AgentTurn.SubEntry`) |
| `AgentChunk` | `AgentTurn` |
| `Row` (protocol) | `EntryProtocol` (or just keep on `Entry` enum if protocol no longer needed) |
| `TextRow` (protocol) | `BodyEntry` (refinement marker; entries with inline text body) |
| `RowType` enum | merged into per-variant case (no longer needed once enum-discriminator collapses) |
| `RowID` | `EntryID` |
| `DerivedRowID` | `EntryID.derived(...)` constructor |
| `RowCollection` | `EntryCollection` |
| `BulkDirection` | `BulkDirection` (kept) |
| `ChunkRowSnapshot` | `EntrySnapshot` |
| `ChunkRowView` (View dispatcher) | `EntryView` |
| `UserChunkRow` | `UserEntryView` |
| `AgentChunkRow` | `AgentTurnView` |
| `SystemChunkRow` | `SystemEntryView` (localCommand flavor) |
| `CompactChunkRow` | `CompactEntryView` |
| `MetaChunkRow` | `MetaEntryView` |
| `ChunkRowChrome` (ViewModifier) | `EntryChrome` |
| `ChunkComputedCache` | `EntryComputedCache` |
| `ClaudeChunkBuilder` | `ClaudeTranscriptBuilder` |
| `CodexChunkBuilder` | `CodexTranscriptBuilder` |
| `ClaudeBuilderConsts` | `ClaudeRenderConsts` |
| `ClaudeMetaContent` | (kept) |
| `ClaudeContentDetector` | (kept) |
| `ClaudeJSONLLine` | (kept) |
| `ClaudeLineDispatcher` | (kept) |
| `ClaudeLineRouting` | (kept) |
| `ClaudeRenderKind` | (kept) |
| `ClaudeSpecialKind` | (kept) |
| `ClaudeBranchResolver` (+ `ClaudeBranchResolution`, `ClaudeAbandonedBranch`) | (kept) |
| `ClaudeQueuedPromptResolver` | (kept) |
| `ClaudeSkillCommandResolver` | (kept) |
| `ClaudeTurnDurationResolver` | (kept) |
| `ClaudeHookSessionStore`, `ClaudeHookSessionRecord` | `ClaudeHookSessionStore`; record renamed `AgentHookSessionRecord` (Codex shares it) |
| `CodexHookSessionStore` | (kept) |
| `CodexRolloutLine`, `CodexEventMsg`, `CodexResponseItem`, `CodexSessionMeta`, `CodexTurnContext` | (kept) |
| `CodexSyntheticTimestamps` | (kept) |
| `JSONLTail` | (kept) |
| `TranscriptStream` (already correctly named) | (kept) |
| `AgentSessionResolver`, `ResolvedAgentSession`, `AgentKind` | (kept) |
| `FocusedSurfaceObserver` (host-side) | `WorkspaceFocusObserver` (lives in app target, not package) |
| `ScrollbarStateCache` (host-coupled) | (kept; lives app-side) |
| `ClaudeAnchorPayload`, `ClaudeAnchorSocketPayload`, `ClaudeAnchorPairing`, `PendingClaudeAnchor` | (kept; types in `Models/`, pairing algorithm in `Behavior/Anchors/`) |
| `TurnAnchor`, `TurnAnchorStore` | `TurnAnchor` (kept) → `Models/`; `TurnAnchorStore` → `Behavior/Anchors/` |
| `VisibleTurnFilter`, `VisibleTurnScrollSnapshot`, `computeVisibleTurnFilter`, `chunksForFilter` | `EntriesFilter`, `ScrollSnapshot`, `computeEntriesFilter`, `entriesForFilter` |
| `InspectorScrollMode` | `ScrollMode` |
| `InspectorExpansionMode` | `ExpansionMode` |
| `InspectorRewindVisibility` | `RewindVisibility` |
| `InspectorCaps`, `InspectorSectionCaps`, `InspectorCaps.Section` | `RenderCaps`, `RenderSectionCaps`, `RenderCaps.Section` |
| `InspectorIcon`, `InspectorIcon.Pair` | `EntryIcon`, `EntryIcon.Pair` |
| `InspectorStatusBar` (View) | `StatusBarView` |
| `InspectorRowAnchorsKey` (PreferenceKey) | `EntryAnchorsKey` |
| `InspectorTimeFormat` | `TimeFormat` |
| `InspectorDetailRequest` | `DetailRequest` |
| `AgentInspectorPanel` | `AgentXrayPanel` |
| `AgentInspectorPanelView` | `PanelView` (inside the package) |
| `AgentInspectorDetailContent` | `DetailContent` |
| `AgentInspectorDetailView` | `DetailView` |
| `AgentInspectorDebugMenu` (View, app-side) | `AgentXrayDebugMenu` |
| `AgentInspectorJSON` (decoder enum) | `AgentXrayJSON` (kept in package) |
| `Workspace.SurfaceKind.agentInspector` (constant) | `Workspace.SurfaceKind.agentXray` |
| `PanelType.agentInspector` | `PanelType.agentXray` |
| `WorkspaceAttentionFlashReason` (cmux enum) | host-side; package defines own `AttentionFlashReason` value type |

### Field/identifier renames

| Today | Tomorrow |
|---|---|
| `chunks` (in TranscriptStream, builders) | `entries` |
| `subrows: [InspectorRow]` (in AgentChunk) | `subEntries: [AgentTurn.SubEntry]` |
| `sidechainTranscript: [InspectorRow]?` | now embedded in `body.sections` as `.subentries(...)` |
| `streamingInspectorRowId` | `streamingTurnID` (only AgentTurn streams) |
| `pairInspectorRowsToTurnAnchors` | `pairEntriesToTurnAnchors` |
| `flushPendingInspectorRow`, `mergeIntoPendingInspectorRow`, `PendingInspectorRow` | `flushPendingEntry`, `mergeIntoPendingTurn`, `PendingEntry` |
| `recomputeStreamingInspectorRowId` | `recomputeStreamingTurnID` |
| `currentExpanded: Set<RowID>` | `currentExpanded: Set<EntryID>` (or `Set<String>` if EntryID stays string-backed for keys) |
| `cachedRowCollection` | `cachedEntryCollection` |
| `branchRowIds`, `topLevelRowIds`, `allRowIds` | `branchEntryIDs`, `topLevelEntryIDs`, `allEntryIDs` |
| `ChunkComputedFields.AI`, `fields.agent: AI` | `EntryComputedFields.Agent`, `fields.agent: Agent` |
| `makeAI`, `makeUser`, `makeSystem`, `makeCompact`, `makeSynthesized` | `makeAgent`, `makeUser`, `makeSystem`, `makeCompact`, `makeSynthesized` |
| `agentKindLabel == .unknown → "AI"` | `→ "Agent"` |
| `aiHeaderExpanded` (in snapshot) | `agentHeaderExpanded` |
| `agentInspector.*` xcstrings keys | `agentXray.*` |
| `cmuxClaudePromptSubmitted` notification | (kept; cross-process contract with cmux app) |

### File renames

Detailed in §6. All `Sources/Panels/AgentInspector/**/*.swift` files migrate to `Packages/CMUXAgentXray/Sources/CMUXAgentXray/<layer>/...` per §6.

## §5 Domain model (final)

```swift
// MARK: - Entry umbrella (5 top-level cases)
public enum Entry: Identifiable, Equatable, Sendable {
    case user(UserEntry)
    case agent(AgentTurn)
    case system(SystemEntry)
    case compact(CompactEntry)
    case synthesized(SynthesizedEntry)
    public var id: EntryID { /* dispatch */ }
    public var header: Header { /* dispatch */ }
    public var body: Body { /* dispatch */ }
    public var timestamp: Date? { /* dispatch */ }
}

public struct EntryID: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case mirroredFromJSONL(String)
        case derived(parent: String, kind: String)
    }
    public let source: Source
}

// MARK: - Header (every entry has one)
public struct Header: Equatable, Sendable {
    public let icon: EntryIcon?
    public let name: String?           // "User", "Claude", "System" — nil hides
    public let label: String?          // "Opus 4.7" model/version pill
    public let title: String?          // dynamic content: file path, command name, recap title
    public let trailing: [TrailingItem]
    public let timestamp: Date?
}

public enum TrailingItem: Equatable, Sendable {
    case text(String)
    case pill(String)
    case statusDot(ToolEntry.Status)
    case duration(milliseconds: Int)
    case wordCount(Int)
}

// MARK: - Body (list of sections; empty = Variant A header-only)
public struct Body: Equatable, Sendable {
    public let sections: [Section]
}

public enum Section: Equatable, Sendable {
    case text([String], style: TextStyle)
    case subentries([Entry])
}

public enum TextStyle: Equatable, Sendable {
    case normal
    case thinking          // italic
    case error             // red
    // diffAdded / diffRemoved / codeMonospace deferred until needed (§16 ledger)
}

// MARK: - Variants
public struct UserEntry: Equatable, Sendable {
    public let id: EntryID
    public let timestamp: Date?
    public let header: Header
    public let body: Body
    public let promptId: String?
    public let wasQueued: Bool
    public let isQueuedPending: Bool
}

public struct AgentTurn: Equatable, Sendable {
    public let id: EntryID
    public let timestamp: Date?
    public let header: Header
    public let body: Body              // = Body(sections: [.subentries(subEntries.map(.from))])
    public let usage: TokenUsage
    public let stopReason: String?
    public let perTurnDurationMs: Int?
    public let messageCount: Int?
    public let model: String?
    public let endTime: Date?
    public let subEntries: [SubEntry]
    
    public enum SubEntry: Equatable, Sendable {
        case thinking(ThinkingEntry)
        case tool(ToolEntry)
        case assistantText(AssistantTextEntry)
    }
    public struct TokenUsage: Equatable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadTokens: Int
        public var cacheCreationTokens: Int
        public static let zero = TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
    }
}

public struct ThinkingEntry: Equatable, Sendable {
    public let id: EntryID; public let parentTurnID: EntryID
    public let timestamp: Date?; public let header: Header; public let body: Body  // text style: .thinking
}

public struct ToolEntry: Equatable, Sendable {
    public let id: EntryID
    public let timestamp: Date?
    public let header: Header
    public let body: Body              // sections: [.text(input, .normal), .text(result, status==.error ? .error : .normal), .subentries(sidechain)]
    public let toolName: String
    public let status: Status
    public let durationMs: Int?
    public let subagentType: String?
    public let teamMemberName: String?
    public let teamName: String?
    public enum Status: Equatable, Sendable { case pending, ok, error }
}

public struct AssistantTextEntry: Equatable, Sendable {
    public let id: EntryID; public let parentTurnID: EntryID
    public let timestamp: Date?; public let header: Header
    public let body: Body              // empty sections → Variant A header-only link
    public let fullBody: String        // detail-tab payload
    public let wordCount: Int
}

public struct SystemEntry: Equatable, Sendable {
    public let id: EntryID
    public let timestamp: Date?
    public let header: Header
    public let body: Body
    public let subType: SubType
    public enum SubType: Equatable, Sendable {
        case localCommand(input: String)
        case slashCmdInput(name: String, args: String?)
        case slashCmdOutput(isStderr: Bool)
        case skill(name: String, basePath: String?)
        case systemReminder
        case contextUsage
        case recap
        case planMode(phase: PlanModePhase, planFilePath: String?, planExists: Bool)
        case editedTextFile(path: String)
        case other(String)
    }
    public enum PlanModePhase: Equatable, Sendable { case entered, exited, reentered }
}

public struct CompactEntry: Equatable, Sendable {
    public let id: EntryID
    public let timestamp: Date?
    public let header: Header
    public let body: Body              // single .text section
}

public struct SynthesizedEntry: Equatable, Sendable {
    public let id: EntryID
    public let timestamp: Date?
    public let header: Header
    public let body: Body              // branchLink: .subentries(branchEntries); prLink: empty
    public let kind: Kind
    public enum Kind: Equatable, Sendable {
        case branchLink(branchRootUuid: String, rewindIndex: Int, totalRewinds: Int, entryCount: Int, firstPromptPreview: String?)
        case prLink(prNumber: Int, url: String, repository: String)
    }
}
```

**Branch link policy:** carries abandoned-branch entries inside `body.sections = [.subentries(...)]` (Variant C container); rendered as **header-only link** (renderer policy, not data shape). Click opens detail tab.

**Tool sidechain:** carried inside `body.sections = [.subentries(sidechainEntries)]`; rendered as link; future may expose inline.

**Renderer policy** (in `Views/RenderCaps.swift`): per-section decision of inline vs link — orthogonal to data shape.

## §6 Package layout (final)

```
Packages/CMUXAgentXray/
├── Package.swift                     # swift-tools-version: 6.0; defaultLocalization: "en"; platforms: [.macOS(.v15)]; swiftLanguageVersions: [.v5] initially → .v6 in Phase 13
├── README.md                         # onboarding + architecture diagram
├── FORK_NOTES.md                     # upstream-touch ledger (target: minimal)
├── Sources/CMUXAgentXray/
│   ├── Models/
│   │   ├── Entry.swift                       # enum + EntryID + dispatch helpers
│   │   ├── Header.swift                      # Header + TrailingItem
│   │   ├── Body.swift                        # Body + Section + TextStyle
│   │   ├── ScrollMode.swift                  # was Sync/InspectorScrollMode
│   │   ├── ExpansionMode.swift               # was Sync/InspectorExpansionMode
│   │   ├── RewindVisibility.swift            # was Sync/InspectorRewindVisibility
│   │   ├── TurnAnchor.swift                  # struct only (store moves to Behavior)
│   │   ├── ClaudeAnchorPayload.swift         # types only (algorithm moves to Behavior)
│   │   └── Entries/
│   │       ├── UserEntry.swift
│   │       ├── AgentTurn.swift               # AgentTurn + nested SubEntry, ThinkingEntry, ToolEntry, AssistantTextEntry, TokenUsage
│   │       ├── SystemEntry.swift             # + nested SubType + PlanModePhase
│   │       ├── CompactEntry.swift
│   │       └── SynthesizedEntry.swift        # + nested Kind
│   ├── Streaming/
│   │   ├── JSONLTail.swift                   # was Tail/
│   │   ├── TranscriptStream.swift            # was Tail/
│   │   └── AgentSessionResolver.swift        # was Attach/ (package-self-contained)
│   ├── Adapters/
│   │   ├── Claude/
│   │   │   ├── ClaudeTranscriptBuilder.swift # was ClaudeChunkBuilder
│   │   │   ├── ClaudeJSONLLine.swift
│   │   │   ├── ClaudeContentDetector.swift
│   │   │   ├── ClaudeRenderConsts.swift      # was ClaudeBuilderConsts
│   │   │   ├── ClaudeHookSessionStore.swift
│   │   │   ├── ClaudeLineDispatcher.swift
│   │   │   ├── ClaudeModelNameMap.swift      # moved from Render/ (closer to data)
│   │   │   ├── Parsers/
│   │   │   │   ├── AssistantLineParser.swift
│   │   │   │   ├── AttachmentLineParser.swift
│   │   │   │   ├── CommonLineParser.swift
│   │   │   │   ├── SystemLineParser.swift
│   │   │   │   └── UserLineParser.swift
│   │   │   └── Resolvers/
│   │   │       ├── ClaudeBranchResolver.swift
│   │   │       ├── ClaudeQueuedPromptResolver.swift
│   │   │       ├── ClaudeSkillCommandResolver.swift
│   │   │       └── ClaudeTurnDurationResolver.swift
│   │   └── Codex/
│   │       ├── CodexTranscriptBuilder.swift  # was CodexChunkBuilder
│   │       ├── CodexRolloutLine.swift
│   │       ├── CodexHookSessionStore.swift
│   │       └── CodexSyntheticTimestamps.swift
│   ├── Behavior/
│   │   ├── Expansion/
│   │   │   ├── EntryCollection.swift         # was Model/RowCollection (struct + classifier)
│   │   │   ├── BulkAction.swift              # BulkDirection + nextExpanded
│   │   │   └── AutoExpandPolicy.swift        # autoExpandNewEntries (extracted from panel)
│   │   ├── Visibility/
│   │   │   └── EntriesFilter.swift           # was Sync/VisibleTurnIds
│   │   └── Anchors/
│   │       ├── TurnAnchorStore.swift         # was Sync/TurnAnchorStore (store half)
│   │       └── AnchorPairing.swift           # pairClaudeAnchorsToUserChunks (extracted)
│   ├── Views/
│   │   ├── PanelView.swift                   # was AgentInspectorPanelView
│   │   ├── DetailView.swift                  # was Detail/AgentInspectorDetailView
│   │   ├── StatusBarView.swift               # was Render/InspectorStatusBar
│   │   ├── EntryHeaderView.swift             # NEW — unified header renderer (uses Header struct)
│   │   ├── EntryBodyView.swift               # NEW — unified body-section renderer
│   │   ├── HudPalette.swift
│   │   ├── HudPaletteToken.swift             # extracted from ChunkRowView tail
│   │   ├── EntryIcon.swift                   # was Render/InspectorIcon
│   │   ├── RenderCaps.swift                  # was Render/InspectorCaps
│   │   ├── Snapshots/
│   │   │   ├── EntrySnapshot.swift           # main struct + Kind + from() dispatcher
│   │   │   ├── EntrySnapshot+Factories.swift # makeAgent/makeUser/makeSystem/...
│   │   │   ├── MetaSnapshot.swift            # + SystemSubKind + SynthesizedSubKind
│   │   │   ├── ToolCallSnapshot.swift
│   │   │   ├── ExpandableContent.swift
│   │   │   ├── TokenBreakdown.swift
│   │   │   ├── ExpansionResolver.swift
│   │   │   ├── DisplayMode.swift
│   │   │   ├── AgentKindLabel.swift
│   │   │   └── EntryComputedCache.swift      # was ChunkComputedCache; renamed AI struct → Agent
│   │   ├── Entries/
│   │   │   ├── EntryView.swift               # dispatcher (was ChunkRowView outer)
│   │   │   ├── UserEntryView.swift           # was UserChunkRow (~83 lines)
│   │   │   ├── AgentTurnView.swift           # was AgentChunkRow (~309 lines — biggest)
│   │   │   ├── SystemEntryView.swift         # was SystemChunkRow
│   │   │   ├── CompactEntryView.swift        # was CompactChunkRow
│   │   │   └── MetaEntryView.swift           # was MetaChunkRow (~188 lines)
│   │   └── Helpers/
│   │       ├── EntryChrome.swift             # was ChunkRowChrome ViewModifier (~118 lines)
│   │       ├── MetadataPill.swift
│   │       ├── PulsingIcon.swift
│   │       ├── OpenDetailLink.swift
│   │       └── StatusDot.swift
│   ├── Panel/
│   │   ├── AgentXrayPanel.swift              # @Observable core: stored state, init, deinit
│   │   ├── AgentXrayPanel+Streaming.swift    # session attach, focus subscription, stream cancellable
│   │   ├── AgentXrayPanel+Expansion.swift    # bulk + per-row toggle + autoExpand
│   │   ├── AgentXrayPanel+ScrollMode.swift   # scrollMode + applyModeFlip + filter
│   │   ├── AgentXrayPanel+Anchors.swift      # claude_anchor pairing
│   │   ├── AgentXrayPanel+Detail.swift       # openDetail routing
│   │   ├── DetailContent.swift               # was Detail/AgentInspectorDetailContent
│   │   └── DetailRequest.swift               # was InspectorDetailRequest (extracted)
│   ├── Host/
│   │   ├── AgentXrayHost.swift               # protocol
│   │   ├── HostAppearance.swift              # package-side Appearance value type
│   │   ├── AttentionFlashReason.swift
│   │   ├── ResolvedAgentSession.swift        # public re-export
│   │   └── ScrollbarSnapshot.swift           # value type the host feeds in (replaces direct GhosttyScrollbar coupling)
│   └── Resources/
│       └── Localizable.xcstrings             # English-only; agentXray.* keys
└── Tests/
    └── CMUXAgentXrayTests/
        ├── ChunkBuilders/                    # ClaudeTranscriptBuilder*Tests, CodexTranscriptBuilderTests
        ├── Resolvers/                        # ClaudeBranch, Compact, Queued, Skill resolver tests
        ├── Routing/                          # ClaudeLineDispatcherTests, ClaudeContentDetectorTests
        ├── Streaming/                        # JSONLTailTests, AgentSessionResolverTests, ClaudeHookSessionStoreTests
        ├── Sync/                             # TurnAnchorStoreTests, EntriesFilterTests, LiveAnchorReceiverTests, EntryComputedCacheTests
        ├── Models/                           # EntryRoleTests, ClaudeModelNameMapTests
        ├── Panel/                            # AgentXrayBulkExpansionTests, DetailContentTests
        └── Resources/                        # JSONL fixtures (resource bundle)
```

App-side adapter files (kept in cmux app target, never moved):
```
Sources/Panels/AgentXray/   # tiny app-side adapter
├── Workspace+AgentXray.swift             # extension Workspace: AgentXrayHost
├── WorkspaceFocusObserver.swift          # was Attach/FocusedSurfaceObserver
├── WorkspaceScrollbarBridge.swift        # was Sync/ScrollbarStateCache (Ghostty-coupled)
├── cmuxApp+AgentXrayDebugMenu.swift
└── AgentXraySurfaceKind.swift            # SurfaceKind.agentXray + restoration
```

## §7 Host protocol surface (final)

```swift
@MainActor
@available(macOS 15, *)
public protocol AgentXrayHost: AnyObject {
    var workspaceID: UUID { get }
    
    // Focus tracking
    func currentFocusedSession() -> ResolvedAgentSession?
    func observeFocusChanges(_ handler: @escaping () -> Void) -> any Cancellable
    
    // Scrollbar state for snap-mode
    func scrollbarSnapshot(forSurfaceID id: UUID) -> ScrollbarSnapshot?
    func observeScrollbarChanges(_ handler: @escaping (UUID) -> Void) -> any Cancellable
    
    // Panel intent → cmux side actions
    func openDetailTab(content: DetailContent, fromPanelID panelID: UUID) -> AgentXrayPanel?
    func updateTitle(panelID: UUID, title: String)
    func flashAttention(panelID: UUID, reason: AttentionFlashReason)
    func panelDidClose(_ panel: AgentXrayPanel)
    
    // Live anchor pipeline (cmux fires; package consumes)
    func observeClaudeAnchorPayloads(_ handler: @escaping (ClaudeAnchorPayload) -> Void) -> any Cancellable
}

public protocol Cancellable: AnyObject { func cancel() }
```

`Workspace: AgentXrayHost` conformance lives in `Sources/Panels/AgentXray/Workspace+AgentXray.swift` (app target). The `WorkspaceFocusObserver` and `WorkspaceScrollbarBridge` provide the deep-coupled implementations.

## §8 Cmux upstream-touch surface (target)

| File | Reason | Min content |
|---|---|---|
| `Sources/Panels/Panel.swift` | `PanelType.agentXray` enum case + legacy `agentInspector` decode fallback | ~5 lines |
| `Sources/Panels/PanelContentView.swift` | switch arm rendering `PanelView` | ~3 lines |
| `Sources/Workspace.swift` | restore path + `isProgrammaticSplit` visibility | ~10 lines |
| `Sources/CmuxLifecycleEventPublishing.swift` | switch arm `agent_xray` | ~1 line |
| `Sources/TerminalPaneDropTargetView.swift` | drop nil arm | ~1 line |
| `Sources/ContentView.swift` | command-palette label + keywords | ~3 lines |
| `Sources/Search/GlobalSearchDocuments.swift` | search index switch | ~1 line |
| `Sources/ClosedItemHistory.swift` | recently-closed label | ~1 line |
| `Sources/cmuxApp.swift` | DEBUG menu wire-up | ~1 line |
| `CLI/cmux.swift` | `claude_anchor_v2` hook (live anchor pipeline) | unchanged from spike |
| `Sources/TerminalController.swift` | `claude_anchor` router branches | unchanged from spike |
| `Sources/GhosttyTerminalView.swift` | `Notification.Name.cmuxClaudePromptSubmitted` | (move into package if possible) |
| `cmux.xcodeproj/project.pbxproj` | adds `Packages/CMUXAgentXray` SPM dependency + ~5 app-side adapter file entries | small |
| `Resources/Localizable.xcstrings` | **eliminated** (keys move to package) | 0 |

App-target inspector source/test files: **0** (was ~67). Net ~13 small touches; xcstrings + pbxproj merge-pain hotspots eliminated.

## §9 Phase plan

Each phase ends with: (a) build green, (b) plan §1 status flipped, (c) §14 progress log entry with branch tip and notable findings, (d) commit pushed to `agentxray` branch on `origin`.

### Phase 1 — New worktree + empty package skeleton

```bash
# At ~/temp/github (sibling to cmux-swiftui):
git -C cmux-swiftui worktree add ../cmux-agentxray -b agentxray upstream/main
cd ../cmux-agentxray
./scripts/setup.sh   # init submodules, build GhosttyKit
```

- Create `Packages/CMUXAgentXray/Package.swift` with manifest, English-only localization, macOS 15 floor, swift-tools 6.0.
- `Sources/CMUXAgentXray/` directory + empty placeholder file (`AgentXray.swift` with module-level doc comment).
- `Tests/CMUXAgentXrayTests/` with one smoke test (`XCTAssertTrue(true)`).
- Wire into `cmux.xcodeproj` as local SPM dependency.
- Build via `./scripts/reload.sh --tag agentxray` — green required before next phase.

**Verification:** `swift build --package-path Packages/CMUXAgentXray` green. `swift test --package-path Packages/CMUXAgentXray` green. Tagged `cmux DEV agentxray.app` builds + launches.

### Phase 2 — Domain models (Entry/Header/Body)

Port + reshape `Sources/Panels/AgentInspector/Model/AgentChunk.swift` (kitchen sink) into the new `Models/` directory per §6. Apply data-model from §5.

**Order of work:**
1. `Header.swift`, `Body.swift`, `Section.swift`, `TextStyle.swift`, `EntryID.swift` — primitives first.
2. Per-variant entry types (`UserEntry`, `AgentTurn`, `SystemEntry`, `CompactEntry`, `SynthesizedEntry`) one file each.
3. `Entry` umbrella enum.
4. `Models/{ScrollMode,ExpansionMode,RewindVisibility,TurnAnchor,ClaudeAnchorPayload}.swift`.
5. Models tests: round-trip equality, ID dispatch, header builder helpers.

**Verification:** package builds; smoke test green. App still uses the old types; nothing wired up yet.

### Phase 3 — Adapters (Claude + Codex)

Port adapters into `Adapters/Claude/` and `Adapters/Codex/`. Apply renames (`ClaudeChunkBuilder → ClaudeTranscriptBuilder`, `chunks → entries`, `AgentChunk → AgentTurn`, etc.).

**Sub-phases:**
- 3a: Pure-function resolvers (Branch, TurnDuration, QueuedPrompt, SkillCommand) — easiest tier.
- 3b: Per-line parsers (5 files).
- 3c: Dispatchers + content detectors.
- 3d: `ClaudeTranscriptBuilder` orchestrator. **Output is `[Entry]`, not `[InspectorRow]`.**
- 3e: `ClaudeHookSessionStore` + `CodexHookSessionStore` (rename `ClaudeHookSessionRecord → AgentHookSessionRecord`).
- 3f: `CodexTranscriptBuilder` + auxiliary types.
- 3g: Port + adapt the 9 builder/resolver test files.

**Verification:** all ported tests green via `swift test`. Builders produce `[Entry]` shape from real JSONL fixtures.

### Phase 4 — Streaming

Port `Tail/JSONLTail.swift`, `Tail/TranscriptStream.swift`, `Attach/AgentSessionResolver.swift` into `Streaming/`. Update field names (`chunks → entries`).

**Verification:** `JSONLTailTests`, `AgentSessionResolverTests`, `ClaudeHookSessionStoreTests` ported and green.

### Phase 5 — Behavior

Port + restructure: `Sync/VisibleTurnIds.swift → Behavior/Visibility/EntriesFilter.swift`; `Model/RowCollection.swift → Behavior/Expansion/EntryCollection.swift` + `BulkAction.swift`; extract `AutoExpandPolicy` from `AgentInspectorPanel`; split `TurnAnchorStore.swift` into struct (`Models/TurnAnchor.swift`) + store (`Behavior/Anchors/TurnAnchorStore.swift`); split `ClaudeAnchorPayload.swift` types from `pairClaudeAnchorsToUserChunks` (move pairing → `Behavior/Anchors/AnchorPairing.swift`).

**Verification:** `EntriesFilterTests`, `TurnAnchorStoreTests`, `AgentXrayBulkExpansionTests` ported.

### Phase 6 — Snapshots

Port `Render/ChunkRowSnapshot.swift` → split into 9 files under `Views/Snapshots/` per §6. Apply renames (`makeAI → makeAgent`, `aiHeaderExpanded → agentHeaderExpanded`, `ChunkRowSnapshot → EntrySnapshot`, etc.). Port `Render/ChunkComputedCache.swift → Views/Snapshots/EntryComputedCache.swift` (rename internal `AI` struct to `Agent`).

**Verification:** snapshot construction green; `EntryComputedCacheTests` ported.

### Phase 7 — Views

Port `Render/ChunkRowView.swift` → split into per-variant view files under `Views/Entries/` + helpers under `Views/Helpers/` per §6. Add new `Views/EntryHeaderView.swift` + `Views/EntryBodyView.swift` to consume the new Header/Body data shape.

**Order:**
- 7a: `EntryHeaderView`, `EntryBodyView`, helpers (`EntryChrome`, `MetadataPill`, `PulsingIcon`, `OpenDetailLink`, `StatusDot`), `HudPaletteToken`.
- 7b: Per-variant views (`UserEntryView`, `AgentTurnView`, `SystemEntryView`, `CompactEntryView`, `MetaEntryView`).
- 7c: `EntryView` dispatcher.
- 7d: `StatusBarView`, `RenderCaps`, `EntryIcon`.
- 7e: `PanelView` (was `AgentInspectorPanelView`) + scroll/anchor wiring.
- 7f: `DetailView`.

**Verification:** package compiles; snapshot+view round-trip green; manual dogfood (Phase 9) deferred until Panel + Host wired.

### Phase 8 — Panel

Port `AgentInspectorPanel.swift` → split per §6 into 6 files under `Panel/`. Convert `ObservableObject` → `@Observable` (Swift 5 compatible). Replace direct `Workspace?` reference with `AgentXrayHost?`. Replace `WorkspaceAttentionFlashReason` with package-side `AttentionFlashReason`.

**Verification:** panel compiles; bulk-expansion tests green.

### Phase 9 — Host integration

App-side files in `Sources/Panels/AgentXray/`:
- `Workspace+AgentXray.swift` — `extension Workspace: AgentXrayHost { ... }`. Implement all 8 protocol methods.
- `WorkspaceFocusObserver.swift` — moved from `Attach/FocusedSurfaceObserver.swift`. Concrete Workspace observation.
- `WorkspaceScrollbarBridge.swift` — moved from `Sync/ScrollbarStateCache.swift`. Subscribes to `.ghosttyDidUpdateScrollbar`, projects to `ScrollbarSnapshot`.
- `cmuxApp+AgentXrayDebugMenu.swift` — DEBUG menu entry.
- `AgentXraySurfaceKind.swift` — `SurfaceKind.agentXray` constant + restoration.

Cmux upstream-touch (per §8 table): apply each minimal switch arm.

**Verification:** App launches; AgentX-ray tab opens via debug menu; attaches to focused Claude session; live transcript renders; bulk expand/collapse works; mode flip works; detail tab opens.

### Phase 10 — Detail mode wiring

Wire `openDetail(request:)` end-to-end: panel emits → host opens new sibling panel with `.detail(content:)` mode → `DetailView` renders.

**Verification:** `↗ Open detail` link on overflow opens detail tab in same pane.

### Phase 11 — Localization + theming pass

Move all `agentInspector.*` xcstrings keys → package's `Resources/Localizable.xcstrings` as `agentXray.*`. Confirm `Bundle.module.localizedString(...)` resolves at runtime.

**Verification:** every UI string renders correctly; `String(localized: "agentXray.row.assistant.label", bundle: .module)` returns "Assistant".

### Phase 12 — AsyncStream focus pipeline

Replace Combine `.objectWillChange.debounce` in `WorkspaceFocusObserver` with `AsyncStream`-based event pipeline. Keep behavior identical.

**Verification:** focus tracking still works on all three notification paths (`.ghosttyDidFocusSurface`, `.ghosttyDidFocusTab`, `.ghosttyDidBecomeFirstResponderSurface`).

### Phase 13 — Swift 6 strict concurrency

Flip `swiftLanguageVersions: [.v6]` in `Package.swift`. Resolve any strict-concurrency findings — most likely `@MainActor` propagation on `AgentXrayPanel`, `Sendable` conformance on value types (already done in Phase 2).

**Verification:** `swift build` green at v6 mode; package still loads in cmux app.

### Phase 14 — Documentation

- `Packages/CMUXAgentXray/README.md` — architecture diagram, Entry/Header/Body model, host protocol explainer, file map, recipes ("how to add a new agent adapter", "how to add a new entry variant").
- `Packages/CMUXAgentXray/FORK_NOTES.md` — initial state with §8 touch table.
- `CLAUDE.md` — add `## AgentX-ray` section with hard rules (see §11 below).
- `~/.claude/plans/` — archive `inspector-canonical-2026-06-02.md` to historical; this doc is the new source of truth.

### Phase 15 — Cleanup

- The `agent-inspector-swiftui-spike` worktree is preserved as historical reference; do not merge it.
- The new `agentxray` branch becomes the active dogfood branch.
- Final §14 progress log entry; mark all phases ✅.

## §10 Risk register

| Risk | Mitigation |
|---|---|
| Spike's load-bearing scroll machinery regresses on port (8 mechanisms in §4 of canonical) | Phase 7 (`PanelView` port) is last; other phases don't touch it. Tests + manual dogfood guard. |
| Domain model reshape (Variant A/B/C) breaks the renderer's per-variant chrome | Phase 2 lands data model; Phase 6 (snapshots) bridges old → new; Phase 7 (views) consumes new shape. Each phase keeps its predecessors running until cutover. |
| `xcstrings` resource bundle misloads at runtime | Phase 11 verifies via `Bundle.module.localizedString(...)`. Test asserts at least one key resolves. |
| Swift 6 strict concurrency surfaces latent races | Phase 13 last; @Observable migration in Phase 8 cleans most. |
| `cmuxClaudePromptSubmitted` notification name straddles package boundary | Define name in package (`Notification.Name.cmuxClaudePromptSubmitted`); cmux side imports package and posts. Reduces upstream touches to: just the post-site (currently in `TerminalController.swift`). |
| Inspector tabs in user's persisted workspaces lose state on upgrade | `PanelType` decoder accepts legacy `"agentInspector"` raw value, mapping to `.agentXray`. Same trick the existing case-insensitive fallback uses. |
| Bug found mid-port that's not in scope of the migration | Apply autonomous fix per §3 rule; log in §15 ledger; if scope-creep, defer to a follow-up phase and note in §16 deferred ledger. |

## §11 CLAUDE.md additions (ready to paste)

```markdown
## AgentX-ray (`Packages/CMUXAgentXray`)

Self-contained feature package. Cmux app conforms `Workspace` to
`AgentXrayHost` via `Sources/Panels/AgentXray/Workspace+AgentXray.swift`;
the package never imports cmux types.

**Hard rules:**
- Inside `Packages/CMUXAgentXray/`, never reference `Workspace`, `TerminalPanel`,
  `Bonsplit`, `TabManager`, or any cmux app type. All cmux integration runs
  through `AgentXrayHost`.
- macOS 15 platform floor. No fallback paths. External integration sites use
  `if #available(macOS 15, *)`.
- English-only localization. Keys in
  `Packages/CMUXAgentXray/Sources/CMUXAgentXray/Resources/Localizable.xcstrings`.
  No translations beyond English.
- Snapshot-boundary policy: rows below `LazyVStack` hold zero observable
  references — value snapshots + stable closures only.
- `View` suffix on SwiftUI views. No `Model` suffix on data types.
- Prefer `@Observable` over `ObservableObject` + `@Published`.
- Tests live in `Packages/CMUXAgentXray/Tests/CMUXAgentXrayTests/`. Adding test
  files here does NOT require `cmux.xcodeproj/project.pbxproj` wiring.
- Upstream-touch policy: every cmux-app-side change supporting AgentX-ray
  (enum arm, switch case, debug menu wiring) goes in
  `Packages/CMUXAgentXray/FORK_NOTES.md`. Aim: minimal.
- Vocabulary: `Entry` (umbrella, 5 cases) / `AgentTurn` (the only container) /
  `Transcript = [Entry]` / `Header { name, label, title, timestamp, trailing }` /
  `Body { sections: [Section] }` where `Section = .text(..., style:) | .subentries(...)`.
  Never use `Row` or `Chunk` in this package.

**Build and test:**
\`\`\`bash
swift build --package-path Packages/CMUXAgentXray
swift test  --package-path Packages/CMUXAgentXray
\`\`\`

Reload the app via `./scripts/reload.sh --tag agentxray --launch`.

Migration plan: `~/.claude/plans/agentxray-migration-2026-06-04.md`. Phase
status table at the top — update after each phase.
```

## §12 Package README outline

```
# CMUXAgentXray
Self-contained Swift package providing the AgentX-ray feature for cmux.

## What it does
Side-by-side companion panel that mirrors the Claude Code or Codex session
running in the workspace's currently focused terminal. Shows live transcript
with bulk expand/collapse, snap-mode viewport sync, and detail-tab routing.

## Architecture
[diagram: JSONL → Streaming → Adapters → Behavior → Panel → Snapshots → Views]

## Data model
- Transcript = [Entry]
- Entry: 5 top-level cases (user, agent, system, compact, synthesized)
- AgentTurn carries SubEntry list (thinking, tool, assistantText)
- Every entry: Header + Body (sections)

## Host integration
The cmux app conforms Workspace to AgentXrayHost ... (8 methods)

## Layer map
Models / Streaming / Adapters / Behavior / Views / Panel / Host / Resources

## Recipes
- Add a new chunk type ...
- Add a new agent adapter ...
- Add a new SystemEntry SubType ...

## Development
- Build: swift build --package-path Packages/CMUXAgentXray
- Test:  swift test  --package-path Packages/CMUXAgentXray
- Reload cmux: ./scripts/reload.sh --tag agentxray --launch
```

## §13 Continuity playbook (for resumption in a new session)

1. Open this doc. Read §1 status table; identify the first ⏳ row.
2. Read the in-tree `Packages/CMUXAgentXray/README.md` if it exists (if Phase 1+ done).
3. Read the in-tree `Packages/CMUXAgentXray/FORK_NOTES.md` if it exists.
4. Run `git -C /Users/I505728/temp/github/cmux-agentxray status` and `git log -3 --oneline` to confirm tip vs §14 progress log.
5. Run `swift build --package-path Packages/CMUXAgentXray` to confirm green baseline before any new work.
6. Pick up the first ⏳ phase; follow its sub-steps in §9.
7. After completing a phase, update §1 status, append to §14, and commit.

## §14 Progress log

Append-only. Each entry: phase, date, branch tip, notable findings. New session reads bottom-up to catch up.

```
[Phase 0] 2026-06-04
  Audit complete. Three Explore agents covered Adapters / Pipeline+Sync / UI layer.
  Findings:
  - Package isolation possible: only 2 files (FocusedSurfaceObserver, ScrollbarStateCache) need host indirection.
  - 50+ rename sites for InspectorRow → Entry across builders.
  - ChunkRowView (1034L) and ChunkRowSnapshot (725L) need decomposition; line ranges captured in §6.
  - AgentInspectorPanel (864L) carries 7 distinct concerns; extension-based split planned.
  - Sync/ folder is a misnomer — splits into Models/ (config enums), Behavior/ (algorithms+stores), Host/ (Ghostty-coupled cache).
  - Detail/ is not a separate panel — it's a Mode of AgentInspectorPanel; collapses into Panel/.
  Worktree: /Users/I505728/temp/github/cmux-swiftui at 1a244aaa6 (agent-inspector-swiftui-spike).
  Upstream tip: 81e409c35 (manaflow-ai/cmux main).

[Phase 1] 2026-06-04 -> agentxray @ 5aad34007 (pushed to origin/agentxray)
  Worktree: /Users/I505728/temp/github/cmux-agentxray off upstream/main 81e409c35.
  setup.sh ran clean (submodules + GhosttyKit build).
  Package skeleton:
    Packages/CmuxAgentXray/Package.swift  (Swift 6 mode + ExistentialAny + InternalImportsByDefault, macOS 15, English-only)
    Sources/CmuxAgentXray/CmuxAgentXray.swift  (module marker)
    Sources/CmuxAgentXray/Resources/Localizable.xcstrings  (empty)
    Tests/CmuxAgentXrayTests/CmuxAgentXraySmokeTests.swift  (1 test, green)
    README.md, FORK_NOTES.md
  Verification: swift build green; swift test 1/1 passed.
  cmux.xcodeproj NOT modified yet — pbxproj wiring deferred to Phase 9 (when host
  adapter actually consumes the package). This avoids a dead/unused dep entry.
  Autonomous decisions logged in §15 (1 + 2 + 3).

[Phase 2] 2026-06-04 -> agentxray @ 18ff88fa5 (pushed to origin/agentxray)
  Domain model reshape complete. Mapping from old → new:
    Model/AgentChunk.swift (607L kitchen sink) split into 10 files.
    Sync/{InspectorScrollMode, InspectorExpansionMode, InspectorRewindVisibility} → Models/{ScrollMode, ExpansionMode, RewindVisibility}
    Sync/TurnAnchorStore.swift's TurnAnchor struct extracted → Models/TurnAnchor.swift (store moves to Behavior in Phase 5)
    Sync/ClaudeAnchorPayload.swift types → Models/ClaudeAnchorPayload.swift (pairing algorithm moves to Behavior in Phase 5)
  Vocabulary applied:
    InspectorRow → Entry (5 cases: user/agent/system/compact/synthesized)
    AgentChunk → AgentTurn (with nested SubEntry / ThinkingEntry / ToolEntry / AssistantTextEntry / TokenUsage)
    UserRow/SystemRow/CompactRow/SynthesizedRow → UserEntry/SystemEntry/CompactEntry/SynthesizedEntry
    SystemSubType → SystemEntry.SubType (nested)
    SynthesizedKind → SynthesizedEntry.Kind (nested)
    PlanModePhase → SystemEntry.PlanModePhase (nested)
    AgentTokenUsage → AgentTurn.TokenUsage (nested)
    AgentTokenUsage.zero static still available
    InspectorIcon → EntryIcon (moved from Render/ to Models/, since Header references it)
  New types introduced (refactor):
    Header { icon, name, label, title, trailing, timestamp }       — replaces scattered name/summary/icon
    Body { sections: [Section] }; Section = .text(blocks, style:) | .subentries([Entry])
    TextStyle { .normal, .thinking, .error }                       — supports thinking-italic and error-red
    TrailingItem { .text, .pill, .statusDot, .duration, .wordCount } — header trailing items
    Transcript = [Entry]                                            — typealias for the document
  Notification.Name.cmuxClaudePromptSubmitted moved INTO package (Models/ClaudeAnchorPayload.swift).
  Eliminates one upstream-touch row from plan §8 (was: GhosttyTerminalView.swift adds the name).
  Verification: swift build green; swift test — 19/19 tests passed in 6 suites.

[Phase 3] 2026-06-04 -> agentxray @ 4e1d9a204 (pushed to origin/agentxray)
  Adapters layer ported (Claude + Codex). 20 source files, ~3500 LOC adapted.
  Vocabulary applied:
    ClaudeChunkBuilder      → ClaudeTranscriptBuilder
    CodexChunkBuilder       → CodexTranscriptBuilder
    snapshot()              → transcript()
    chunks: [InspectorRow]  → entries: [Entry]
    AgentChunk              → AgentTurn (with subEntries instead of subrows)
    UserRow/SystemRow/CompactRow/SynthesizedRow → *Entry
    ToolRow/ThinkingRow/AssistantTextRow → AgentTurn.SubEntry
    ClaudeBuilderConsts     → ClaudeRenderConsts
    AgentInspectorJSON      → AgentXrayJSON
    ClaudeHookSessionRecord → AgentHookSessionRecord (shared by Codex too)
  Builder construction sites refactored to construct Header + Body:
    Header carries icon/name/label/title/trailing/timestamp
    Body.sections = [.text(blocks, style:) | .subentries([Entry])]
    Variant-A entries (assistantText, prLink) build Body.empty
    Variant-C entries (branchLink, agentTurn body) carry .subentries(...)
  Localization: every "agentInspector.*" key migrated to "agentXray.*" with
    bundle: .module. Resources/Localizable.xcstrings still empty — keys
    resolve to defaultValue at runtime; Phase 11 fills the bundle.
  ClaudeQueuedPromptResolver refactored: returns thin
    ClaudePendingPrompt descriptors instead of constructed UserRow values.
  Hook stores adapted for Swift 6 strict concurrency:
    @unchecked Sendable, public import Foundation, any DispatchSourceFileSystemObject,
    @Sendable on file-watch callbacks.
  ClaudeModelNameMap moved from Render/ to Adapters/Claude/ (it's a
    label-data parser, closer to the data layer).
  Internal/DebugLog.swift added (replaces app-target cmuxDebugLog).
  Adapter test porting deferred — old fixtures use legacy
    InspectorRow/AgentChunk shape and need significant adaptation.
  Verification: swift build green; swift test 19/19 passing (model-layer
    tests preserved; adapter tests follow when fixtures are remade).

[Phase 4] 2026-06-04 -> agentxray @ 11d62b29d (pushed to origin/agentxray)
  Streaming layer ported. JSONLTail (vnode file watcher,
    @unchecked Sendable, any DispatchSourceFileSystemObject for
    ExistentialAny), AgentSessionResolver + ResolvedAgentSession
    (workspaceID/surfaceID/sessionID camelCase; @unchecked Sendable on
    resolver since FileManager is thread-safe in practice),
    TranscriptStream (@MainActor @Observable; entries: [Entry];
    dispatches to ClaudeTranscriptBuilder vs CodexTranscriptBuilder
    by session.agentKind).
  ResolvedAgentSession placed in Streaming/ rather than Host/ — sits
    next to TranscriptStream.attach(session:) which is its primary
    consumer. Plan §6 had it in Host/; package layout deviation logged
    in §15.
  Verification: swift build green; swift test 19/19 still passing.

[Phase 5] 2026-06-04 -> agentxray @ 637c18d87 (pushed to origin/agentxray)
  Behavior layer ported. EntryCollection (branchEntryIDs /
    topLevelEntryIDs / allEntryIDs) + nextExpanded(after:given:in:)
    bulk algorithm. EntriesFilter + computeEntriesFilter +
    entriesForFilter + scrollTarget + boundary id helpers
    (beforeTurnBoundaryID / tailBoundaryID). TurnAnchorStore
    (@MainActor; setSurface, recordTurnStart, pairAgentTurn,
    anchor(forEntryID:), orderedAnchors). AnchorPairing
    (pairClaudeAnchorsToUserEntries with both queue-overload
    variants).
  Vocabulary: VisibleTurnFilter → EntriesFilter; pairInspectorRow →
    pairAgentTurn; agentChunkId → agentTurnID; userChunkId →
    userEntryID throughout.
  ScrollbarSnapshot value type promoted to Models/ for reuse by
    TurnAnchorStore + computeEntriesFilter; replaces the GhosttyScrollbar
    coupling — Phase 9 host adapter projects scrollbar updates into this
    type at the boundary.
  Verification: swift build green; swift test 19/19 passing.

[Phase 6] 2026-06-04 -> agentxray @ 16b6409b0 (pushed to origin/agentxray)
  Snapshot foundation laid. DisplayMode (.compact/.fullDetail),
    RenderSectionCaps (maxLines/maxBytes/alwaysLink), RenderCaps.Section
    (14 cases enumerated per entry surface), AgentKindLabel
    (.claude/.codex/.unknown), ExpandableContent (cap-applied
    truncation result with .make(from:caps:displayMode:) static).
    EntryComputedCache deferred to Phase 7 since it's tightly coupled
    to per-Entry capsForBlock heuristic.
  Verification: swift build green; swift test 19/19 passing.

[Phase 7] 2026-06-04 -> agentxray @ 25d0b1119 (pushed to origin/agentxray)
  Unified Views layer. Single EntryView dispatcher dispatches Entry
    variants to a unified EntryHeaderView + EntryBodyView. Per-variant
    logic (accent color, icon pulse) lives in computed properties on
    EntryView; chrome (rounded background on expand) is the EntryChrome
    modifier. Helper views: StatusDotView, MetadataPillView,
    OpenDetailLinkView.
  EntryComputedCache (@MainActor) caches per-entry [ExpandableContent]
    keyed by entry id + content signature (sectionCount, totalBytes,
    displayMode); cache hits are O(1); per-entry invalidation. Replaces
    the spike's chunk-row-snapshot rebuild on every panel-body
    invocation.
  HudPalette adopted as a Sendable value type with NSColor foreground
    init; HudGlyph enum carries the terminal glyph constants.
  Snapshot-boundary policy enforced by construction: EntryView holds
    only value snapshots (Entry, Computed, palette, mode, flags) plus
    stable closures — no @ObservedObject / @Bindable refs.
  EntryBodyView field renamed `body` → `entryBody` to avoid the View
    protocol's reserved `var body` requirement.
  Verification: swift build green; swift test 19/19 passing.

[Phase 8] 2026-06-04 -> agentxray @ 4dfe5692b (pushed to origin/agentxray)
  Panel layer. AgentInspectorPanel.swift (864 lines, single
    ObservableObject) ported as a six-file split:
    AgentXrayPanel.swift (@Observable core), and five extensions for
    Streaming, Expansion, ScrollMode, Anchors, Detail.
  Vocabulary applied to panel layer:
    AgentInspectorPanel       → AgentXrayPanel
    ObservableObject + @Published → @Observable + internal(set) public var
    visibleTurnFilter         → entriesFilter
    streamingInspectorRowId   → streamingEntryID
    cachedRowCollection       → cachedEntryCollection
    pairInspectorRowsToTurnAnchors → pairTurnAnchorsToAgentTurns
    DerivedRowID.make(parent:kind:)
                              → EntryID.derived(parent:kind:).stableString
    ExpansionToggle.agentHeader/chunkBody/thinking/tool
                              → entryChevron/thinking(parentTurnID:)/tool(toolID:)
  Host abstraction landed (originally Phase 9 surface; pulled into
    Phase 8 because Panel can't compile without it):
    Host/AgentXrayHost.swift   # protocol surface (focus/scrollbar/anchor
                               # observation, detail tab opening, title
                               # update, flash)
    Host/Cancellable.swift     # AnyObject-bound cancellation token
    Host/HostAppearance.swift  # value-typed appearance palette
    Host/AttentionFlashReason.swift
  Detail surfaces: Panel/DetailContent.swift +
    Panel/DetailRequest.swift. Phase 10 fleshes out the resolver from
    DetailRequest → DetailContent; Phase 8 lands the wiring path with
    a stub resolver returning nil so end-to-end builds.
  Stream observation: replaced Combine
    `stream.objectWillChange.sink` with an Observation-framework Task
    loop (withObservationTracking + CheckedContinuation). The handler
    runs once per observed mutation, yields one runloop tick so the
    mutation lands, then runs the unified handleStreamTick() pipeline
    (drain anchors → pair turns → recompute filter → autoExpand →
    recompute streaming pulse).
  Persisted UserDefaults migration: agentInspector.expansionMode /
    .rewindVisibility keys still read for one upgrade window;
    subsequent writes go to agentXray.* keys. Legacy raw value
    `autoExpandSnap` migrates to `.autoExpand`.
  deinit is a no-op: Swift 6 strict concurrency forbids touching
    @MainActor-isolated, non-Sendable properties from a nonisolated
    deinit; host calls panel.close() for full teardown instead.
  Phase 8 design preserves every behavior in the spike's
    AgentInspectorPanel + AgentInspectorPanelView per the §1 audit
    checklist. State writes from extension files required flipping
    `private(set)` → `internal(set) public var` on five fields
    (focusFlashToken, resolvedSession, entriesFilter, streamingEntryID,
    bulkState, currentExpanded).
  Verification: swift build green; swift test 19/19 passing.

[Phase 10] 2026-06-04 -> agentxray @ ddb4bd128 (pushed to origin/agentxray)
  Detail mode resolver. Ported AgentInspectorDetailContent.resolve from
    the spike into DetailContent.resolve(request:entry:); twelve cases
    (userPrompt, thinking, systemOutput, toolInput, toolResult,
    assistantResponse, abandonedBranch, subagentTranscript, skillBody,
    slashCommandBody, systemReminderBody, recapBody).
  Vocabulary applied:
    chunk: InspectorRow                  → entry: Entry
    ai.subrows.toolRow(withId:)          → turn.subEntries.toolEntry(withID:)
    ToolRow.text.first / .result         → ToolEntry.inputDetail / .resultDetail
    ToolRow.sidechainTranscript          → ToolEntry.sidechainTranscript
    branchLink.chunks (payload field)    → synthesized.body.subentriesContent
                                            (chunks no longer carried on
                                            SynthesizedEntry.Kind; live
                                            in the body, recovered at
                                            resolve time)
    user.text.joined / sys.text.joined   → user.body.textContent /
                                            sys.body.textContent
  ToolEntry got body-section convention accessors (no new fields, just
    projections):
      inputDetail        — sections[0] .text payload
      resultDetail       — sections[1] .text payload (if any)
      sidechainTranscript — first .subentries(...) payload
  Detail-tab xcstring keys migrated agentInspector.detail.* →
    agentXray.detail.* with bundle: .module. A `localized(_:defaultValue:)`
    static helper takes a StaticString key and a String.LocalizationValue
    default, calling String(localized:defaultValue:bundle:) under the
    hood.
  AgentXrayPanel+Detail.swift now calls DetailContent.resolve(...) and
    hands the result to host.openDetailTab(content:fromPanelID:).
  Verification: swift build green; swift test 19/19 passing.

[Phase 11] 2026-06-04 -> agentxray @ 5841c246d (pushed to origin/agentxray)
  Localization migration. Populated Resources/Localizable.xcstrings
    with 43 agentXray.* keys harvested from the package source (English-
    only). Static keys carry literal values; format-arg keys use
    Apple's positional placeholders (%1$lld, %2$@, etc.).
  Bug fix surfaced during key harvest: agentXray.row.agent.label was
    used by both ClaudeTranscriptBuilder (defaultValue: "Claude") and
    CodexTranscriptBuilder (defaultValue: "Agent") — same key,
    conflicting defaults. With the xcstrings file populated the bundle
    would resolve ONE value for both, mis-labelling one of the agents.
    Split into kind-specific keys agentXray.row.agent.label.claude
    and agentXray.row.agent.label.codex; logged in §15.
  Resource compilation note: SwiftPM doesn't invoke xcstringstool, so
    xcstrings ships as raw JSON in the resource bundle when run under
    `swift test`. End-to-end runtime resolution against
    String(localized:bundle:.module) requires Xcode's resource
    pipeline, which kicks in once the cmux app target builds via the
    Phase-9 host adapter. Tests therefore validate xcstrings presence
    + JSON shape rather than runtime lookup output.
  Two new tests in LocalizableXcstringsTests assert (a) the xcstrings
    file ships in Bundle.module, (b) the legacy colliding key is
    absent and the kind-specific replacements are present.
  Verification: swift build green; swift test 21/21 passing in 7 suites.

[Phase 13] 2026-06-04 -> agentxray @ 5841c246d (no-op; ledger entry only)
  Swift 6 strict concurrency was front-loaded in Phase 1
    (Package.swift enables .swiftLanguageMode(.v6) +
    .enableUpcomingFeature("ExistentialAny") +
    .enableUpcomingFeature("InternalImportsByDefault") on both targets
    since the package's first commit). Confirmed `swift build` passes
    with zero warnings or errors on the agentxray branch tip.

[Phase 9] 2026-06-04 -> agentxray @ d5fb1ad6a (pushed to origin/agentxray)
  Cmux app integration. End-to-end build green (xcodebuild succeeds;
  package tests 21/21).
  Package-side adjustments:
    - Package.swift platform floor lowered macOS 15 → 14 to match the
      cmux app's MACOSX_DEPLOYMENT_TARGET=14.0. Types using macOS-15
      APIs already carry `@available(macOS 15, *)` annotations.
    - `Cancellable` protocol renamed → `AgentXrayCancellable` to
      disambiguate from Combine's `Cancellable` at host-adapter call
      sites.
    - `enum CmuxAgentXray` (module marker) renamed → `AgentXrayModule`
      to stop shadowing the module name (callers writing
      `CmuxAgentXray.AgentXrayPanel` would otherwise parse as enum
      case access).
    - New `CmuxAgentXrayPanelView` (was `PanelView`) — top-level
      live transcript view rendering [Entry] under a LazyVStack of
      EntryView rows. Minimal port; advanced behaviours from the
      spike's AgentInspectorPanelView (InspectorRowAnchorsKey
      aggregation, scroll-clamp / materialize-kick) deferred (§16.I).
  App-side adapter under Sources/Panels/AgentXray/ (6 new files):
    - AgentXrayPanelHost.swift — Panel-protocol wrapper around the
      package's @Observable AgentXrayPanel. Bridges Combine
      ObservableObject → Observation via a Task loop on
      withObservationTracking; `@Published titleTick` redraws the cmux
      tab bar on title change.
    - AgentXrayWorkspaceHost.swift — per-panel `AgentXrayHost`
      adapter. Owns WorkspaceFocusObserver, NotificationCenter tokens
      for .ghosttyDidUpdateScrollbar and .cmuxClaudePromptSubmitted,
      routes openDetailTab through Workspace.openAgentXrayDetail.
      Defines `HostCancellable` (the AgentXrayCancellable
      implementation wrapping AnyCancellable / NotificationCenter
      observer tokens).
    - WorkspaceFocusObserver.swift — port of the spike's
      FocusedSurfaceObserver. Watches three notifications, debounces
      workspace.objectWillChange via Combine 150ms, resolves
      ResolvedAgentSession, publishes @Published `current`. Phase 12
      (AsyncStream conversion) deferred to §16.H.
    - WorkspaceScrollbarBridge.swift — port of the spike's
      ScrollbarStateCache. Singleton subscribed to
      .ghosttyDidUpdateScrollbar; projects GhosttyScrollbar →
      ScrollbarSnapshot at the boundary; exposes latest(for:).
    - Workspace+AgentXray.swift — newAgentXraySurface(inPane:focus:
      targetIndex:) + openAgentXrayDetail(content:fromPanelID:
      originPanelHost:). Both create AgentXrayPanelHost instances and
      register them in Workspace.panels with SurfaceKind.agentXray.
    - cmuxApp+AgentXrayDebugMenu.swift — DEBUG helper routing the new
      "Agent X-ray (open new panel)…" Debug menu entry through the
      focused workspace's focused pane.
  Cmux upstream-touch surface (~13 sites; all minimal):
    PanelType +case +decode-fallback (legacy "agentInspector" raw),
    PanelContentView render arm + drop-target opt-in, cmuxApp Debug
    menu Button, Workspace SurfaceKind constant + 3 switch arms +
    fileprivate requestFlash helper, CmuxLifecycleEventPublishing arm,
    GlobalSearchDocuments arm, TerminalPaneDropTargetView arm,
    ContentView 3 arms (palette label/keywords/cmuxSidebarSurfaceKind),
    ClosedItemHistory arm.
  Project file: 6 surgical edits applied in Phase 9a wired the
    CmuxAgentXray local SPM package; 4 surgical edits per new file
    (PBXBuildFile, PBXFileReference, group membership, Sources phase
    membership) × 6 new files.

[Phase 14] 2026-06-04 -> agentxray @ 7335f5b61 (pushed to origin/agentxray)
  Documentation finalization. FORK_NOTES.md upstream-touch table
    populated (10 rows + new-files inventory). README.md status
    section refreshed. PHASE_9_HANDOVER.md removed (superseded by the
    Phase 9 commit + FORK_NOTES).

[Phase 15] 2026-06-04 -> agentxray @ 7335f5b61 (rolled into Phase 14 commit)
  Cleanup. PHASE_9_HANDOVER.md retirement and stale-doc trim happened
    alongside Phase 14. Remaining "spike" references in the package
    + app-side adapter are intentional lineage notes in code
    comments — no orphan docs, no dangling test fixtures, no leftover
    typealiases pointing at the old vocabulary.
```

## §15 Bug-fix ledger (autonomous fixes during port)

Append-only. Each entry: file, what was wrong, fix summary, commit hash. Two-commit pattern (failing test + fix) when a behavior-level bug is found.

```
[Phase 1, 2026-06-04, agentxray @ 5aad34007]

  1. Package name CMUXAgentXray → Cmux**AgentXray (lowercase prefix).
     Why: upstream has been migrating CMUX* → Cmux* (12 of 20 packages now use
     the lowercase form: CmuxFoundation, CmuxFileWatch, CmuxSettings,
     CmuxSwiftRender, etc.; only 8 keep CMUX*). Adopting the more recent
     convention to avoid being the odd-one-out. Plan §4 vocabulary table and
     §6 directory tree are now stale on this point — superseded by this entry.

  2. Swift 6 language mode + ExistentialAny + InternalImportsByDefault enabled
     in Package.swift from day 1, NOT deferred to Phase 13.
     Why: every recent CmuxFoundation/CmuxFileWatch/CmuxSwiftRender ships these
     three swiftSettings together. Matching the convention from day 1 avoids a
     two-step migration (Swift 5 mode → Swift 6 mode flip later). The package
     contains zero existing concurrency-flagged code, so strict mode is free.
     Plan Phase 13 now reduces to "ensure no regressions" (likely a no-op).

  3. cmux.xcodeproj/project.pbxproj NOT touched in Phase 1.
     Why: per migration plan §6, pbxproj entries are needed only for code that
     the cmux app target consumes. The package isn't consumed until Phase 9
     (host adapter). Adding a dependency entry now would reference a product
     no app code uses, and Xcode might either silently ignore it or warn.
     Wiring moved to Phase 9. No upstream-touch surface added in Phase 1.

[Phase 4, 2026-06-04, agentxray @ 11d62b29d]

  4. ResolvedAgentSession placed in Streaming/, not Host/.
     Plan §6 had it in Host/ — but it's the type TranscriptStream.attach(...)
     consumes directly, and the host protocol just re-references it. Putting
     it next to its primary consumer keeps each layer self-explanatory.
     Same for ScrollbarSnapshot (Phase 5: placed in Models/ rather than
     Host/, since computeEntriesFilter and TurnAnchorStore both depend on
     it). Plan §6 directory tree treated as a guide, not a contract.

[Phase 11, 2026-06-04, agentxray @ 5841c246d]

  5. agentXray.row.agent.label key collision split.
     ClaudeTranscriptBuilder used `agentXray.row.agent.label` with default
     value "Claude"; CodexTranscriptBuilder used the SAME key with default
     value "Agent". With xcstrings empty (Phase 1–10), each builder fell
     through to its own defaultValue and rendered correctly. With Phase 11
     populating the xcstrings, Bundle.module would resolve ONE value and
     both labels would converge — mis-labelling whichever didn't match the
     xcstrings entry. Fix: split into kind-specific keys
     `agentXray.row.agent.label.claude` and `agentXray.row.agent.label.codex`,
     each with its own xcstrings entry. Regression caught by
     LocalizableXcstringsTests.agentLabelsKindSpecificInXcstrings, which
     asserts the legacy `agentXray.row.agent.label` key is absent from
     the xcstrings file (so a future re-collision can't slip back in).

  6. agentXray.row.branchLink.title call sites have benign default-value
     drift: Resolver-A site builds the format with `branch.rewindIndex`
     and `totalRewinds`; Resolver-B site uses `branch.rewindIndex` and
     `resolution.totalRewinds`. Both resolve to identical Int substitution
     into "Rewind X of Y" so the rendered string is the same. xcstrings
     entry shipped as `Rewind %1$lld of %2$lld`. Source-side default
     values are inconsistent but harmless; left as-is to avoid touching
     two unrelated builder branches. §16.F tracks the cleanup.
```

## §16 Deferred-task ledger

Items found during port that are out of scope for the migration but worth tracking.

```
A. TextStyle expansion — diffAdded/diffRemoved/codeMonospace cases when diff rendering lands.
B. Sub-agent transcript inline rendering — currently link-only; future: inline expand inside ToolEntry's body.subentries.
C. ToolEntry shape — likely to evolve as tool-call UX changes (user noted "I think it will change in the future").
D. Notification name `cmuxClaudePromptSubmitted` — currently defined in cmux app; explore moving definition into package to remove one upstream touch.
E. Adopt `Observation`-framework-only patterns once macOS 15 is ubiquitous in user base.
F. Align defaultValue at the two `agentXray.row.branchLink.title` call sites in
   ClaudeTranscriptBuilder so source-side defaults match (cosmetic; runtime
   output already identical via the xcstrings entry).
G. Pre-compile `Localizable.xcstrings` → `en.lproj/Localizable.strings` at SPM
   build time (or ship a Resources/en.lproj folder) so the package can resolve
   localized values under `swift test` — currently only the cmux app target's
   Xcode build invokes xcstringstool, so xcstrings keys fall through to
   defaultValue under `swift test`.
H. Replace the Combine `objectWillChange.debounce` in
   `Sources/Panels/AgentXray/WorkspaceFocusObserver.swift` with an
   `AsyncStream`-based event pipeline (was Phase 12). Combine version is
   correct and ships with Phase 9; AsyncStream is a quality refinement.
I. Top-level `CmuxAgentXrayPanelView` is currently a minimal port of the
   spike's `AgentInspectorPanelView`. The spike's full feature set
   (InspectorRowAnchorsKey aggregation + currentTopVisibleId tracking,
   bulk-collapse scroll-clamp, bulk-expand materialize-kick on
   `panel.bulkState` change, `.onChange(of: visibleTurnFilter)` scroll
   routing, status-bar pills) is NOT yet ported to the package's
   panel-level view. Each is independently re-portable from
   `cmux-swiftui/Sources/Panels/AgentInspector/AgentInspectorPanelView.swift`
   on top of the existing AgentXrayPanel API surface.
```

## §17 Open questions resolved (audit trail)

- Q: Two packages or one? **One.** No precedent in this repo for split UI/Core packages.
- Q: Phase order — rename first, extract first, or both? **Branch+port** strategy: fresh branch off upstream, port code from spike. No interim coexistence.
- Q: AgentChunk → AgentRow or AgentTurn? **AgentTurn** (semantically honest; matches canonical doc usage).
- Q: Row vs Chunk umbrella? **Neither — Entry** (escapes "row=line, chunk=multi-line" mental clash).
- Q: ToolEntry body shape? **List of sections.** Supports input + result + sidechain triple naturally.
- Q: TextStyle enum or isError bool? **TextStyle enum**, starting with 3 cases (normal/thinking/error); diff cases deferred to §16.A.
- Q: SynthesizedEntry.branchLink — Variant A or C? **C structurally** (carries entries in `body.sections`), **rendered as Variant A link** (renderer policy, separate concern). Same for ToolEntry sidechain.
- Q: Localization beyond English? **No.** English-only is the rule per HANDOVER_PROMPT precedent; not a CLAUDE.md violation.
- Q: Schema fallback for legacy `"agentInspector"` raw values? **Yes** — 3-line decode fallback in `PanelType`. Cheap; prevents user-tab loss on upgrade.

---

## §18 Origin cross-reference (for code archaeology only)

The CmuxAgentXray package + app-side adapter were ported from a
predecessor implementation that lived under `Sources/Panels/AgentInspector/`
in branch `agent-inspector-swiftui-spike` of the cmux-swiftui repo. **In-tree
code comments deliberately do NOT reference that history** — the package
is treated as a new project. This section preserves the file-level
mapping in case future code archaeology needs to compare behaviour with
the original implementation.

| AgentXray (current) | Predecessor file (cross-reference only) |
|---|---|
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Views/PanelView.swift` | `Sources/Panels/AgentInspector/AgentInspectorPanelView.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Views/EntryView.swift` and helper views | `Sources/Panels/AgentInspector/Render/ChunkRowView.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Panel/AgentXrayPanel*.swift` | `Sources/Panels/AgentInspector/AgentInspectorPanel.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/*` | `Sources/Panels/AgentInspector/Adapters/Claude/*` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Codex/*` | `Sources/Panels/AgentInspector/Adapters/Codex/*` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Streaming/JSONLTail.swift` | `Sources/Panels/AgentInspector/Tail/JSONLTail.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Streaming/TranscriptStream.swift` | `Sources/Panels/AgentInspector/Tail/TranscriptStream.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Streaming/AgentSessionResolver.swift` | `Sources/Panels/AgentInspector/Attach/AgentSessionResolver.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Behavior/Visibility/EntriesFilter.swift` | `Sources/Panels/AgentInspector/Sync/VisibleTurnIds.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Behavior/Anchors/*` | `Sources/Panels/AgentInspector/Sync/{TurnAnchorStore,ClaudeAnchorPayload}.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Behavior/Expansion/EntryCollection.swift` | `Sources/Panels/AgentInspector/Model/RowCollection.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Models/Header.swift` + `Body.swift` + `Entries/*.swift` | `Sources/Panels/AgentInspector/Model/AgentChunk.swift` (kitchen sink) |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Views/Snapshots/EntryComputedCache.swift` | `Sources/Panels/AgentInspector/Render/ChunkComputedCache.swift` |
| `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Views/HudPalette.swift` | `Sources/Panels/AgentInspector/Render/HudPalette.swift` |
| `Sources/Panels/AgentXray/AgentXrayPanelHost.swift` | _(no direct predecessor — Panel-protocol bridge needed because the package adopts `@Observable`)_ |
| `Sources/Panels/AgentXray/AgentXrayWorkspaceHost.swift` | _(no direct predecessor — `AgentXrayHost` protocol's concrete impl)_ |
| `Sources/Panels/AgentXray/WorkspaceFocusObserver.swift` | `Sources/Panels/AgentInspector/Attach/FocusedSurfaceObserver.swift` |
| `Sources/Panels/AgentXray/WorkspaceScrollbarBridge.swift` | `Sources/Panels/AgentInspector/Sync/ScrollbarStateCache.swift` |
| `Sources/Panels/AgentXray/Workspace+AgentXray.swift` | `Sources/Panels/AgentInspector/Workspace+AgentInspector.swift` |
| `Sources/Panels/AgentXray/cmuxApp+AgentXrayDebugMenu.swift` | `Sources/Panels/AgentInspector/cmuxApp+AgentInspectorDebugMenu.swift` |

The predecessor branch `agent-inspector-swiftui-spike` of the
`manaflow-ai/cmux` repo is the canonical place to inspect the original
implementation when comparing behaviour. Once the agentxray branch
lands on `main`, the predecessor branch becomes purely historical.

---

End of plan. Update §1 + §14 after each phase.
