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
| 12 AsyncStream focus pipeline | ✅ done | rolled up via 17d | `Sources/Panels/AgentXray/WorkspaceFocusObserver.swift` switched from Combine `objectWillChange.debounce(...).sink` to AsyncStream + Task-loop trailing-debounce (150 ms). Combine bridge survives only at the source seam (Workspace is `ObservableObject`, not `@Observable`); the consumer pipeline is async/await with explicit Task cancellation. |
| 13 Swift 6 strict concurrency flip | ✅ done (no-op) | `agentxray` @ `5841c246d` | Front-loaded in Phase 1 (Swift 6 mode + ExistentialAny + InternalImportsByDefault enabled in Package.swift since day one); confirmed swift build passes with zero warnings on the agentxray branch tip |
| 14 Documentation finalization | ✅ done | `agentxray` @ `7335f5b61` | FORK_NOTES.md upstream-touch table populated (10 rows + new-files inventory); README status section refreshed |
| 15 Cleanup — retire spike branch references | ✅ done | `agentxray` @ `7335f5b61` | PHASE_9_HANDOVER.md removed (superseded by Phase 9 commit + FORK_NOTES); remaining spike-references are intentional lineage notes in code comments |
| 17 Parity punch-list completion | ✅ done | rolled up via 17pre + 17a + 17b + 17c | Exhaustive side-by-side audit produced 87 findings across 5 groups. Group 1 (12 behavioural) and Group 2 (icons / status-bar / glyph / disabled state / per-row divider) closed by 17a + 17b + 17c. Groups 3 (per-row layout drift), 4 (detail-mode chrome), 5 (polish) remain as fine-grained verification work tracked in `PARITY_PUNCH_LIST.md`; no parity-critical regressions remain. |
| 17pre `AgentTurn → AgentEntry` rename | ✅ done | `agentxray` @ 17pre commit | Mechanical sweep — type decl, file rename, nested types, anchor field (`agentTurnID` → `agentEntryID`), store method (`pairAgentTurn` → `pairAgentEntry`), child field (`parentTurnID` → `parentEntryID`), doc-comment type references; legacy "Row" function names in `PanelView` renamed to `*EntryView`; localization keys `agentXray.row.*` → `agentXray.entry.*`. Conversational "turn" prose preserved (`per-turn`, `this turn`, `the turn's subEntries`, etc.). Verification: `git grep -wn "AgentTurn"` → 0 hits in code; build + tests 21/21 green. The fabricated §17 "AgentRow vs AgentTurn" Q&A line was deleted. |
| 17a Visual-parity pass | ✅ done | `agentxray` @ 17a commit | `VISUAL_PASS_REVIEW.md` §1–§8 landed as one batch. New: `Theme.swift` (flattened Layout + Typography tokens), `HoverBars.swift`, `StatusBarView.swift`, `AgentEntryView.swift` + `+Thinking/+Tool/+AssistantText.swift` extension files replacing inline private funcs in PanelView, `Adapters/Common/TranscriptFormatters.swift` (formatTokenCounts, singleLinePromptPreview, wordCount). Renamed: `Views/PanelView.swift` → `Views/TranscriptView.swift` (`CmuxAgentXrayPanelView` → `TranscriptView`), `EntryView.accentColor` → `kindAccentColor`, `ExpansionToggle.entryChevron` → `entry`. Modified: `Models/EntryIcon.swift` full rewrite per spec + user-locked overrides for `.compact` / `.recap` / `.slashCommand` + the three predecessor tool extras (LS, ExitPlanMode, AskUserQuestion); `EntryHeaderView` / `EntryBodyView` / `EntryView` consume Theme tokens; `MetadataPillView` folded inline into `EntryHeaderView`; `ClaudeTranscriptBuilder` formatter statics removed (redirects to TranscriptFormatters; user-prompt hard truncation moved from data layer to SwiftUI `.lineLimit(1).truncationMode(.tail)`); per-row hairline divider removed; `HudGlyph.activeDot` / `.runningCircle` replace hardcoded glyphs; disabled control buttons render via `.disabled(...)` (system auto-dim) instead of `palette.dim.opacity(0.4)`; HoverBars top + bottom hairlines applied to every interactive surface (frame-less and framed). Deleted: `Views/Helpers/EntryChrome.swift`, `Views/Helpers/MetadataPillView.swift`, `CmuxAgentXray.swift`, `Tests/CmuxAgentXrayTests/CmuxAgentXraySmokeTests.swift`. Tests 21 → 20. App-side touch: `Sources/Panels/PanelContentView.swift:115` updated to `TranscriptView`. |
| 17b AttachStage feature | ✅ done | `agentxray` @ 17b commit | New `Models/AttachStage.swift` (6-case enum: idle / awaitingSession / sessionHooked / locatingTranscript / streamingNoEntries / streaming(turnCount:, tokenTotal:)) with `derive(resolvedSession:entries:)` static. `StatusBarView` rewired for 3-color glyph precedence (red / yellow / green) per `VISUAL_PASS_REVIEW.md` §1: red on `stream.error != nil` or `.idle` / `.awaitingSession`; yellow on `.sessionHooked` / `.locatingTranscript` / `.streamingNoEntries`; green on `.streaming(...)`. Stream-error message overrides title text. New xcstrings keys: `agentXray.statusBar.{detached,attached,sessionHooked,locatingTranscript,streamingNoEntries,streamError}`. Today only `idle` / `streamingNoEntries` / `streaming` are derived; intermediate stages are reserved for future attach lifecycle instrumentation. |
| 17c Behavioural correctness batch | ✅ done | `agentxray` @ 17c commit | All 12 items in `PARITY_PUNCH_LIST.md` Group 1 ✅. New in `TranscriptView`: `EntryAnchorsKey` PreferenceKey (per-entry `Anchor<CGRect>` aggregation) + `@State currentTopVisibleID` + `handleEntryAnchorsChange` GeometryProxy resolver; `ScrollViewReader`-wrapped scroll-routing helpers (`scrollForFilter` / `scrollTarget`); `.onChange(of: panel.entriesFilter)` → snap-only scroll, `.onChange(of: panel.resolvedSession?.sessionID)` → tail-snap on session change, `.onChange(of: panel.bulkState)` arms (`.expand` materialize-kick scrolls to `currentTopVisibleID` inside a `.disablesAnimations` transaction; `.collapse` clamps via `scrollForFilter`); inner-VStack wrapper `.id("cmux-agentxray-layout-\(layoutRevision)")` for collapse-outcome remount; boundary-id'd zero-height `Color.clear` markers before each user entry (`beforeTurnBoundaryID`) and at the tail (`tailBoundaryID(for:)`) — predecessor parity (no visible hairline). Detail-mode rendering: when `DetailContent.entries` non-nil, render via `EntryView` rows in `.fullDetail` mode (abandoned-branch / sub-agent transcripts). `triggerFlash` gate added on cmux-app side at `AgentXrayPanelHost.triggerFlash` (`NotificationPaneFlashSettings.isEnabled()` early-return, matching every other cmux panel). Verified parity for already-present items: DetailRequest 12-case enum (1.8), `pendingClaudeAnchorsBySessionID` queue + drain (1.10), `applyModeFlip` asymmetry (1.12). |
| 17d Forward-looking deferrals beyond parity | ✅ swept | rolled up | F (branchLink defaultValue alignment) ✅ done; H (AsyncStream focus pipeline / Phase 12) ✅ done. PARITY Groups 3/4/5 audit pass: Group 3 (15 items) → all ✅ (color rules + nestedSubRow indent fixed; rest within tolerance), Group 4 (4 items) → all ✅ (kind-glyph header + Kind→glyph mapping added), Group 5 (6 items) → all ✅. Items A (TextStyle diff cases) / B (inline sub-agent transcripts) / C (ToolEntry shape evolution) / G (xcstrings SPM-build-time pre-compile) explicitly stay deferred — speculative future work or build-tooling investment without a current consumer (per CLAUDE.md "don't pre-solve hypothetical future requirements"). |
| 18 Dogfood: session-attach + host-adapter overhaul | ✅ done | `agentxray` @ `1c49bdf29` … `e12028d9b` (8 commits) | Post-migration dogfood pass on the auto-attach pipeline. Host-adapter restructured into 3 files (was 6) — `AgentXrayPanelHost` → `AgentXrayPanelAdapter`, `WorkspaceFocusObserver` + `WorkspaceScrollbarBridge` folded into a now-truly-workspace-scoped `AgentXrayWorkspaceHost`, `cmuxApp+AgentXrayDebugMenu.swift` deleted. Production logger seam (`AgentXrayLogger` protocol + `AgentXrayWorkspaceLogger` routing `.debug`→`cmuxDebugLog`, `.info`+→`os.Logger`); package's `Internal/DebugLog.swift` removed. Resolver completely rewritten: drops hook-store-keyed-on-`(workspaceId,surfaceId)` (stale across cmux restart) and TTY scrape (Ghostty doesn't expose PTY fd) in favour of two paths joining cmux's authoritative state — Path 1 (`Workspace.restoredAgentSnapshotsByPanelId[panelID]` → snapshot-direct synthesis for auto-resume cases pre-spawn) + Path 2 (`CmuxTopProcessSnapshot.captureCached(...).pids(forCMUXSurfaceID:)` env-var-scoped scanner → `findAgentHookRecord(byPID:)` join → live record). SSH transport infrastructure (`RemoteJSONLStream` over existing ControlMaster, `SessionTransport` enum, `JSONLLineFramer` with byte-level UTF-8 carry shared by local + remote tails). Session attach resolution flow documented in package README (flow diagram + auto-resume timeline). Tests: 20/20 → 46/46. New §16 ledger items J–N track residual deferrals from this pass. |

---

## §2 Goals

1. Migrate `Sources/Panels/AgentInspector/` → self-contained SPM package `Packages/CMUXAgentXray`.
2. Replace umbrella vocabulary: `Row → Entry`, `AgentChunk → AgentEntry`, `ChunkBuilder → TranscriptBuilder`. Drop `Inspector*` prefixes inside the package. Drop residual `AI` legacy in favour of `Agent`.
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
| `InspectorRow` (enum, 8 cases) | `Entry` (enum, **5 top-level cases** — sub-entries collapse into `AgentEntry.SubEntry`) |
| `AgentChunk` | `AgentEntry` |
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
| `subrows: [InspectorRow]` (in AgentChunk) | `subEntries: [AgentEntry.SubEntry]` |
| `sidechainTranscript: [InspectorRow]?` | now embedded in `body.sections` as `.subentries(...)` |
| `streamingInspectorRowId` | `streamingTurnID` (only AgentEntry streams) |
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
    case agent(AgentEntry)
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

public struct AgentEntry: Equatable, Sendable {
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
    public let id: EntryID; public let parentEntryID: EntryID
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
    public let id: EntryID; public let parentEntryID: EntryID
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
│   │       ├── AgentEntry.swift               # AgentEntry + nested SubEntry, ThinkingEntry, ToolEntry, AssistantTextEntry, TokenUsage
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
2. Per-variant entry types (`UserEntry`, `AgentEntry`, `SystemEntry`, `CompactEntry`, `SynthesizedEntry`) one file each.
3. `Entry` umbrella enum.
4. `Models/{ScrollMode,ExpansionMode,RewindVisibility,TurnAnchor,ClaudeAnchorPayload}.swift`.
5. Models tests: round-trip equality, ID dispatch, header builder helpers.

**Verification:** package builds; smoke test green. App still uses the old types; nothing wired up yet.

### Phase 3 — Adapters (Claude + Codex)

Port adapters into `Adapters/Claude/` and `Adapters/Codex/`. Apply renames (`ClaudeChunkBuilder → ClaudeTranscriptBuilder`, `chunks → entries`, `AgentChunk → AgentEntry`, etc.).

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
- Vocabulary: `Entry` (umbrella, 5 cases) / `AgentEntry` (the only container) /
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
- AgentEntry carries SubEntry list (thinking, tool, assistantText)
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

Chronological table of all phases. Each row: date, commit (or commit range), and
one-line topic. **Read the commit message for the full story** — that's the
source-of-truth for what changed; this table is the index by topic / phase.

| Date | Phase | Commit(s) | Topic |
|---|---|---|---|
| 2026-06-04 | 0 | (audit, no commit) | Three Explore agents covered Adapters / Pipeline+Sync / UI; 50+ rename sites + decomposition plan captured in §6. |
| 2026-06-04 | 1 | `5aad34007` | Empty package skeleton + smoke test green; Swift 6 + ExistentialAny + InternalImportsByDefault from day one. pbxproj wiring deferred to Phase 9. |
| 2026-06-04 | 2 | `18ff88fa5` | Domain models reshape (Entry/Header/Body); 15 model files + 19 tests; `Notification.Name.cmuxClaudePromptSubmitted` moved into package. |
| 2026-06-04 | 3 | `4e1d9a204` | Adapters layer (Claude + Codex). 20 files, ~3500 LOC. Builders construct Header/Body. Adapter test porting deferred. |
| 2026-06-04 | 4 | `11d62b29d` | Streaming layer (`JSONLTail`, `TranscriptStream`, `AgentSessionResolver`). `@Observable` adopted directly. |
| 2026-06-04 | 5 | `637c18d87` | Behavior layer (`EntryCollection`, `EntriesFilter`, `TurnAnchorStore`, `AnchorPairing`); `ScrollbarSnapshot` value type promoted to Models/. |
| 2026-06-04 | 6 | `16b6409b0` | Snapshot foundation (`DisplayMode`, `RenderCaps`, `ExpandableContent`, `AgentKindLabel`). `EntryComputedCache` deferred to Phase 7. |
| 2026-06-04 | 7 | `25d0b1119` | Views layer: unified `EntryView` dispatcher + `EntryHeaderView` + `EntryBodyView`; `EntryComputedCache` w/ `ContentSignature`; `HudPalette` + `HudGlyph`. |
| 2026-06-04 | 8 | `4dfe5692b` | Panel layer: `AgentXrayPanel` six-file split; `@Observable` core; host protocol surface (`AgentXrayHost` + `Cancellable` + `HostAppearance` + `AttentionFlashReason`). |
| 2026-06-04 | 9 | `d5fb1ad6a` | Host integration: package wired into cmux app; 6-place pbxproj edit; 6 app-side adapter files; ~13 minimal `case .agentXray:` switch arms; macOS floor lowered 15→14 to match cmux app. |
| 2026-06-04 | 10 | `ddb4bd128` | Detail mode wiring: `DetailContent.resolve(request:entry:)` ported (12 cases); `ToolEntry` helper accessors. |
| 2026-06-04 | 11 | `5841c246d` | Localization + theming pass: 43 keys populated in xcstrings; `agent.label` key collision split into `.claude` / `.codex` keys. |
| 2026-06-04 | 12 | rolled into 17d | AsyncStream focus pipeline: Combine `objectWillChange.sink` → AsyncStream + `Task.sleep` debounce. |
| 2026-06-04 | 13 | `5841c246d` (no-op) | Swift 6 strict concurrency flip — front-loaded in Phase 1, confirmed zero warnings. |
| 2026-06-04 | 14 | `7335f5b61` | Documentation finalization: `FORK_NOTES.md` upstream-touch table populated; README status section refreshed. |
| 2026-06-04 | 15 | `7335f5b61` | Cleanup: `PHASE_9_HANDOVER.md` removed (superseded). |
| 2026-06-04 | 17pre | (17pre commit) | Mechanical sweep: `AgentTurn` → `AgentEntry` everywhere. Conversational "turn" prose preserved. Verification: `git grep -wn "AgentTurn"` → 0 hits. |
| 2026-06-04 | 17a | (17a commit) | Visual-parity pass per `VISUAL_PASS_REVIEW.md` §1–§8. New `Theme.swift`, `HoverBars.swift`, `StatusBarView.swift`, `AgentEntryView` extension files; `EntryIcon.swift` rewrite; per-row hairline divider removed. Tests 21 → 20. |
| 2026-06-04 | 17b | (17b commit) | `AttachStage` feature: 6-case enum + 3-color glyph precedence in `StatusBarView`. |
| 2026-06-04 | 17c | (17c commit) | Group 1 behavioural correctness: `EntryAnchorsKey`, `currentTopVisibleID`, `ScrollViewReader`, scroll-routing `.onChange` arms, boundary-id markers, detail-mode rendering, `triggerFlash` flash gate. |
| 2026-06-04 | 17d | (17d commit) | Forward-looking deferrals + parity audit: Group 3 / 4 / 5 swept ✅; F + H closed; A / B / C / G stay deferred. |
| 2026-06-05 | 18 | `1c49bdf29` … `b0624eab8` (9 commits) | Dogfood pass: session-attach + host-adapter overhaul. Host folded 6 files → 3 (PanelHost → PanelAdapter rename; FocusObserver + ScrollbarBridge + DebugMenu placeholder removed); `AgentXrayLogger` seam (os.Logger / cmuxDebugLog routing); resolver rewritten with two paths (restored-snapshot synthesis + scanner-based PID + hook-record-by-PID join); SSH transport infrastructure (`RemoteJSONLStream`, `JSONLLineFramer` with UTF-8 byte-carry); README documentation with flow + timeline diagrams. Tests 20 → 46. Five new §16 deferrals (J–N). |

## §15 Bug-fix ledger (autonomous fixes during port)

Chronological table of bugs / smells the porting agent fixed inline rather than
deferring. Two-commit pattern (failing test + fix) used when a behaviour-level
bug warranted regression coverage. **Read the commit / linked test for the full
story.**

| Phase | Commit | Bug-fix |
|---|---|---|
| 1 | `5aad34007` | Package name `CMUXAgentXray` → `CmuxAgentXray` (lowercase prefix to match repo's recent convention; 12 of 20 packages had migrated). |
| 1 | `5aad34007` | Swift 6 + ExistentialAny + InternalImportsByDefault enabled from day one (not deferred to Phase 13) — every recent CmuxFoundation/CmuxFileWatch/CmuxSwiftRender ships these together. |
| 1 | `5aad34007` | `cmux.xcodeproj/project.pbxproj` not touched in Phase 1 — pbxproj entries deferred to Phase 9 when host adapter actually consumes the package. |
| 4 | `11d62b29d` | `ResolvedAgentSession` placed in `Streaming/` not `Host/` — sits next to its primary consumer `TranscriptStream.attach`. Plan §6 directory tree treated as guide, not contract. |
| 5 | `637c18d87` | Same as above for `ScrollbarSnapshot` (placed in `Models/`). |
| 11 | `5841c246d` | `agentXray.row.agent.label` key collision: claude builder default `"Claude"` vs codex default `"Agent"` would collide in xcstrings. Split into `agentXray.row.agent.label.claude` / `.codex`. Regression caught by `LocalizableXcstringsTests.agentLabelsKindSpecificInXcstrings`. |
| 11 | `5841c246d` | `agentXray.row.branchLink.title` benign default-value drift between two call sites; resolves identically via xcstrings. Tracked in §16.F (later closed in 17d). |
| 17pre | (17pre commit) | §17 contained a fabricated Q&A line ("AgentChunk → AgentRow or AgentTurn? AgentTurn …") that masked a real Phase-2 instruction. The 17pre rename commit deletes the fabrication. |
| 18 | `e82d16ea5` | Pre-existing UTF-8-at-chunk-boundary data-loss class in `JSONLTail` (string-level carry couldn't preserve mid-codepoint bytes). Fixed in `JSONLLineFramer` with byte-level Data carry; new `JSONLLineFramerTests` covers split positions across 2/3/4-byte codepoints. |
| 18 | `81c4bf101` | Silent decode failures in `ClaudeLineDispatcher` (`debugLog` was DEBUG-only `print`, invisible in production). Promoted to `.warning` via the new `AgentXrayLogger` seam → visible in sysdiagnose. |

## §16 Deferred-task ledger

Items found during port that are out of scope for the migration but worth tracking.

```
A. TextStyle expansion — diffAdded/diffRemoved/codeMonospace cases when diff rendering lands. *(Stays deferred — speculative future feature; no current consumer.)*
B. Sub-agent transcript inline rendering — currently link-only; future: inline expand inside ToolEntry's body.subentries. *(Stays deferred — future UX evolution.)*
C. ToolEntry shape — likely to evolve as tool-call UX changes (user noted "I think it will change in the future"). *(Stays deferred — speculative.)*
D. ~~Notification name `cmuxClaudePromptSubmitted` — currently defined in cmux app; explore moving definition into package to remove one upstream touch.~~ **✅ DONE in Phase 2** — moved to `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Models/ClaudeAnchorPayload.swift`; see §15 entry from Phase 2 commit `18ff88fa5`.
E. Adopt `Observation`-framework-only patterns once macOS 15 is ubiquitous in user base.
F. ~~Align defaultValue at the two `agentXray.entry.branchLink.title` call sites in
   ClaudeTranscriptBuilder so source-side defaults match (cosmetic; runtime
   output already identical via the xcstrings entry).~~ **✅ DONE in 17d** — both sites now use `\(branch.rewindIndex) of \(totalRewinds)` with a hoisted local at the second call site.
G. Pre-compile `Localizable.xcstrings` → `en.lproj/Localizable.strings` at SPM
   build time (or ship a Resources/en.lproj folder) so the package can resolve
   localized values under `swift test` — currently only the cmux app target's
   Xcode build invokes xcstringstool, so xcstrings keys fall through to
   defaultValue under `swift test`. *(Stays deferred — no current test consumes the localized lookup output; existing tests assert key presence in xcstrings JSON instead. Adding a SwiftPM build plugin that invokes xcstringstool is plausible but not load-bearing today.)*
H. ~~Replace the Combine `objectWillChange.debounce` in
   `Sources/Panels/AgentXray/WorkspaceFocusObserver.swift` with an
   `AsyncStream`-based event pipeline (was Phase 12). Combine version is
   correct and ships with Phase 9; AsyncStream is a quality refinement.~~ **✅ DONE in 17d** — Combine `objectWillChange.sink` now feeds an `AsyncStream<Void>` continuation; consumer Task trailing-debounces 150 ms via `Task.sleep` cancellation. Combine surface reduced to a one-line bridge at the workspace seam.
I. Top-level `CmuxAgentXrayPanelView` is currently a minimal port of the
   spike's `AgentInspectorPanelView`. The spike's full feature set
   (InspectorRowAnchorsKey aggregation + currentTopVisibleId tracking,
   bulk-collapse scroll-clamp, bulk-expand materialize-kick on
   `panel.bulkState` change, `.onChange(of: visibleTurnFilter)` scroll
   routing, status-bar pills) is NOT yet ported to the package's
   panel-level view. Each is independently re-portable from
   `cmux-swiftui/Sources/Panels/AgentInspector/AgentInspectorPanelView.swift`
   on top of the existing AgentXrayPanel API surface.
J. SSH "Set session id" UI affordance — Phase 18 shipped the SSH
   transport infrastructure (`RemoteJSONLStream` over the existing
   ControlMaster socket, `SessionTransport.remote(SSHTransport)`,
   dispatch in `TranscriptStream`), but the UI affordance for the user
   to configure a sessionId for a remote panel is unimplemented. Without
   it, remote panels resolve to nil and show "Detached". Natural
   surfaces: command palette entry + AgentX-ray panel header overflow
   menu + `UserDefaults` persistence keyed by (workspace title, panel
   cwd, agentKind). The resolver's path 2 already builds the
   `ResolvedAgentSession` once given a sessionId; only the UI is
   missing.
K. Daemon-side process enumeration over RPC for remote workspaces —
   would let remote panels auto-resolve (no manual sessionId entry)
   like local ones. Requires modifying `cmuxd-remote`
   (`daemon/remote/cmd/cmuxd-remote/main.go`) to add an `agent.list`
   or equivalent RPC method that returns `(panelID → claude/codex PIDs
   + cwd + transcriptPath)`, plus a manifest bump for baked cloud-VM
   images. Out of scope for the AgentX-ray fork-side work; needs
   coordination with the cmux daemon team. *(Stays deferred — depends
   on upstream daemon work.)*
L. Codex restored-snapshot transcriptPath resolution — Phase 18 path 1
   returns nil for codex because codex sessions live in date-bucketed
   `~/.codex/sessions/<year>/<month>/<day>/<sid>.jsonl` directories
   that the snapshot doesn't carry. Codex via path 2 (live PID + hook
   record) still works — the hook record carries the explicit
   transcriptPath. So this is only a path-1 latency gap (slower attach
   for restored codex; resolves once the agent spawns and fires its
   SessionStart hook). Trivial fix when someone has a codex repro:
   either embed the transcriptPath in the snapshot (cmux-side change)
   or walk the date directories at resolve time. *(Stays deferred —
   no impact on the common claude case; codex via path 2 already
   works.)*
M. Upstream cmux change `#4777` ("Launch restored agent sessions via
   startup commands", commit 17f529f63) replaced the pre-existing
   "type `cd … && env … claude --resume <id>` into the panel's PTY"
   restore mechanism with a script-based shell-argv mechanism. The
   user-visible behaviour change: the resume command no longer appears
   in the panel's scrollback. AgentX-ray no longer depends on this
   either way (Phase 18 paths 1 + 2 cover the restore case via cmux's
   `restoredAgentSnapshotsByPanelId` + env-var-scoped scanner), so this
   is purely an upstream UX question. Worth confirming with the cmux
   team whether the scrollback-disappearance was deliberate before
   filing anything. *(Stays deferred — out of AgentX-ray scope; upstream
   to investigate.)*
N. More aggressive split of `AgentXrayWorkspaceHost` (file currently
   ~500 lines) into per-workspace context + per-panel adapter as
   separate types — investigated during Phase 18 commit 1 design.
   Rejected at the time because every pipeline (focus + scrollbar +
   anchor + per-panel registry) is a sub-responsibility of the host
   adapter with no other consumers; splitting would be folder-
   structure-as-module-structure (CLAUDE.md anti-pattern). The current
   shape uses MARK-organized sections inside one file. Worth
   revisiting only if a future need (additional consumer, test seam,
   SwiftUI Environment injection point) emerges. *(Stays deferred —
   no current forcing function; documented for future reference so we
   don't re-litigate.)*
```

## §17 Open questions resolved (audit trail)

- Q: Two packages or one? **One.** No precedent in this repo for split UI/Core packages.
- Q: Phase order — rename first, extract first, or both? **Branch+port** strategy: fresh branch off upstream, port code from spike. No interim coexistence.
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
