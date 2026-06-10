public import Foundation
public import Observation

/// `@Observable` companion model for an agent-transcript x-ray panel.
///
/// Operates in two modes:
/// - `.live` (default): subscribes to focus / scrollbar / claude-anchor
///   events through the `host: any AgentXrayHost`, drives a
///   `TranscriptStream`, and exposes the live entry list + view-driving
///   state (expansion, scroll mode, anchors, streaming pulse).
/// - `.detail(content:)`: renders one frozen `DetailContent` snapshot
///   without streaming or auto-attach. Used for the "↗ Open detail"
///   route from the live panel when an expandable section overflows the
///   inline cap. Detail panels open as sibling tabs in the same pane.
///
/// **Snapshot-boundary policy**: this class is observable, but the entry
/// view layer (`EntryView`, `EntryHeaderView`, `EntryBodyView`) never
/// holds a reference to it. The panel view projects observable state
/// into immutable value snapshots (`ExpandableContent`, `HudPalette`,
/// closure bundles) before passing them to `LazyVStack` entries.
@MainActor
@available(macOS 15, *)
@Observable
public final class AgentXrayPanel {

    // MARK: - Identity

    /// Stable id for this panel instance — used by the host to route
    /// title updates and attention flashes back here.
    public let id: UUID

    /// Workspace this panel belongs to. Mirrors `host.workspaceID`.
    public let workspaceID: UUID

    public enum Mode: Equatable, Sendable {
        case live
        case detail(content: DetailContent)
    }

    public let mode: Mode

    /// Host abstraction. `unowned` because the host (typically the
    /// cmux `Workspace`) outlives the panel and avoiding a strong
    /// retain cycle is the host's contract.
    @ObservationIgnored
    public unowned var host: any AgentXrayHost

    // MARK: - View-facing observable state

    /// Bumped whenever the host requests an attention flash. The view
    /// observes the token and triggers a flash effect on change.
    public internal(set) var focusFlashToken: Int = 0

    /// Currently attached agent session. nil before the first attach
    /// or in `.detail` mode.
    public internal(set) var resolvedSession: ResolvedAgentSession?

    /// Visible-entries filter mode. `.free` shows the entire
    /// transcript; `.snap` filters to the turn(s) currently visible
    /// in the paired terminal viewport (with implicit live tail at
    /// the bottom).
    ///
    /// On flip: `applyModeFlip(from:to:)` runs an **asymmetric**
    /// policy. `.free → .snap` resets bulk state, bumps
    /// `layoutRevision` (forces a LazyVStack remount that drops stale
    /// lazy-entry geometry), and re-derives `entriesFilter`. `.snap →
    /// .free` only relaxes `entriesFilter` to `.all`; user-fiddled
    /// state is preserved.
    public var scrollMode: ScrollMode = .snap {
        didSet { applyModeFlip(from: oldValue, to: scrollMode) }
    }

    /// Three-way visible-turn filter computed by
    /// `computeEntriesFilter`. The view switches on this:
    ///   - `.all` → render every entry (free scroll)
    ///   - `.turns(set)` → render entries whose containing turn's
    ///     user-entry-id is in `set` (anchored zone)
    ///   - `.preAnchored` → render entries whose containing turn has
    ///     no anchor (pre-panel zone, free scroll within history)
    public internal(set) var entriesFilter: EntriesFilter = .all

    /// Id of the trailing AgentEntry while it's still streaming. Drives
    /// the pulsing icon glyph in the agent header. Cleared when no
    /// agent turn is the latest, or when the latest agent turn's
    /// `endTime` is more than `streamingFreshnessWindow` in the past.
    public internal(set) var streamingEntryID: String?

    /// Rewound-branch visibility toggle. Persisted via UserDefaults
    /// (key `agentXray.rewindVisibility`).
    public var rewindVisibility: RewindVisibility = .link {
        didSet {
            UserDefaults.standard.set(
                rewindVisibility.rawValue,
                forKey: AgentXrayPanel.rewindVisibilityKey
            )
        }
    }

    /// Per-turn auto-expand toggle. Persisted via UserDefaults
    /// (key `agentXray.expansionMode`).
    ///
    /// **Concerns NEW items only.** When `.autoExpand` is active in
    /// `.snap` mode, every entry / tool id that first appears in the
    /// stream is inserted into `currentExpanded` for its applicable
    /// expansion keys (entry id for the entry's chevron, derived id
    /// for the agent thinking sub-entry, tool id for each tool sub-
    /// entry). Existing items keep whatever expansion state the user
    /// has fiddled them into; disabling the toggle stops writing
    /// future overrides but never touches prior ones. This is the
    /// clean separation from the bulk Collapse/Expand pills, which
    /// concern EXISTING items by advancing `bulkState`.
    public var expansionMode: ExpansionMode = .allCollapsed {
        didSet {
            UserDefaults.standard.set(
                expansionMode.rawValue,
                forKey: AgentXrayPanel.expansionModeKey
            )
        }
    }

    /// Bulk-action signal. The view observes this to drive its
    /// post-bulk scroll handling (collapse-clamp, expand-kick) and
    /// LazyVStack remount via `layoutRevision`.
    public internal(set) var bulkState: BulkExpansionState = BulkExpansionState(
        tick: 0,
        lastDirection: nil,
        layoutRevision: 0
    )

    /// Per-entry expansion state. The set of keys (`EntryID.stableString`
    /// or derived sub-id) the panel is currently rendering as expanded.
    /// Membership is the single source of truth — `currentExpanded
    /// .contains(id)` is the per-entry read in O(1), no fallback step.
    ///
    /// Default-expansion (branches yes, leaves no) is materialised at
    /// observation time by `autoExpandNewEntries()`: every newly
    /// observed branch (AgentEntry) gets inserted; leaves get inserted
    /// only when the auto-expand pill is on and the entry is post-
    /// attach.
    public internal(set) var currentExpanded: Set<String> = []

    /// True while a remote-attach submission is awaiting host-side work
    /// (remote `$HOME` resolution, UserDefaults write, focus recompute).
    /// The view binds this to a "Connecting…" spinner. Cleared when the
    /// next ``handleSessionChange(_:)`` arrives.
    public internal(set) var remoteAttachInFlight: Bool = false

    // MARK: - Owned subsystems

    /// Live transcript stream — empty in detail mode.
    @ObservationIgnored
    public let stream: TranscriptStream

    /// Per-entry computed-fields cache. Reset on session change.
    @ObservationIgnored
    public let computedCache = EntryComputedCache()

    /// Turn anchors keyed by user-entry id. Populated by exact
    /// `claude_anchor` host events for live prompts — never by
    /// approximation.
    @ObservationIgnored
    public let turnAnchorStore = TurnAnchorStore()

    // MARK: - Private state

    /// Auto-expand bookkeeping: ids of every entry / tool the
    /// auto-expand handler has already observed. Detects first
    /// observation via `insert(id).inserted`. Pre-attach entries are
    /// seeded eagerly so they don't trigger auto-expand; only post-
    /// attach arrivals do. Reset only on session change.
    @ObservationIgnored
    var observedEntryIDs: Set<String> = []

    /// Cached structural classification of `stream.entries`. Lazily
    /// computed by `currentEntryCollection()` and invalidated on every
    /// `stream` tick, plus on session change and `.free → .snap`
    /// mode flip.
    @ObservationIgnored
    var cachedEntryCollection: EntryCollection?

    /// Queues of `claude_anchor` events keyed by Claude session id.
    /// Records can arrive while the panel is following another
    /// terminal; queueing them lets the session attach later and still
    /// snap turns submitted in the current app run.
    @ObservationIgnored
    var pendingClaudeAnchorsBySessionID: [String: [PendingClaudeAnchor]] = [:]

    /// Coalesces high-frequency scrollbar updates. Set when an event
    /// matching the paired surface arrives; cleared when the trailing
    /// recompute fires.
    @ObservationIgnored
    var hasPendingScrollbarRecompute = false

    /// One-shot timer that re-checks `streamingEntryID` after the
    /// freshness window elapses. Cleared on every recompute.
    @ObservationIgnored
    var streamingFreshnessTimer: Timer?

    /// AgentEntries whose `endTime` is within this many seconds of "now"
    /// are considered actively streaming. Picked to be loose enough
    /// that inter-line gaps during a turn don't stutter the pulse,
    /// tight enough that the pulse settles soon after the turn ends.
    static let streamingFreshnessWindow: TimeInterval = 1.5

    // MARK: - Host subscriptions (cancelled in close())

    @ObservationIgnored
    var focusSubscription: (any AgentXrayCancellable)?
    @ObservationIgnored
    var scrollbarSubscription: (any AgentXrayCancellable)?
    @ObservationIgnored
    var claudeAnchorSubscription: (any AgentXrayCancellable)?
    @ObservationIgnored
    var streamObservationTask: Task<Void, Never>?

    // MARK: - UserDefaults keys

    static let rewindVisibilityKey = "agentXray.rewindVisibility"
    static let expansionModeKey = "agentXray.expansionMode"

    // MARK: - Init / deinit

    /// Live-mode initializer.
    public init(host: any AgentXrayHost) {
        self.id = UUID()
        self.workspaceID = host.workspaceID
        self.mode = .live
        self.host = host
        self.stream = TranscriptStream(logger: host.logger)

        restorePersistedToggles()
        wireHostSubscriptions()
    }

    /// Detail-mode initializer. Renders a frozen, non-streaming
    /// snapshot of one expanded section from the live panel.
    public init(host: any AgentXrayHost, detail: DetailContent) {
        self.id = UUID()
        self.workspaceID = host.workspaceID
        self.mode = .detail(content: detail)
        self.host = host
        self.stream = TranscriptStream(logger: host.logger)
        // No subscriptions — detail panels are frozen.
    }

    deinit {
        // Resource cleanup runs through `close()`, called by the
        // embedding host before deinit. Swift 6 strict concurrency
        // forbids touching MainActor-isolated, non-Sendable
        // properties from a nonisolated deinit, so we leave the
        // cleanup contract on `close()` and trust the host to invoke
        // it at panel teardown.
    }

    // MARK: - Public lifecycle

    /// Drop all host subscriptions and detach the stream. Idempotent.
    /// Called by the embedding workspace when the panel is removed.
    public func close() {
        focusSubscription?.cancel()
        focusSubscription = nil
        scrollbarSubscription?.cancel()
        scrollbarSubscription = nil
        claudeAnchorSubscription?.cancel()
        claudeAnchorSubscription = nil
        streamObservationTask?.cancel()
        streamObservationTask = nil
        streamingFreshnessTimer?.invalidate()
        streamingFreshnessTimer = nil
        pendingClaudeAnchorsBySessionID.removeAll(keepingCapacity: false)
        stream.attach(session: nil)
    }

    /// Trigger an attention flash on this panel. Bumps
    /// `focusFlashToken` so the view's `.onChange` fires.
    public func triggerFlash(reason: AttentionFlashReason) {
        _ = reason
        focusFlashToken &+= 1
    }

    // MARK: - Private setup

    private func restorePersistedToggles() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: AgentXrayPanel.rewindVisibilityKey),
           let v = RewindVisibility(rawValue: raw) {
            self.rewindVisibility = v
        }
        if let raw = defaults.string(forKey: AgentXrayPanel.expansionModeKey),
           let v = ExpansionMode(rawValue: raw) {
            self.expansionMode = v
        }
    }

    /// Configures the per-host observers. Each subscription is stored
    /// so `close()` can cancel it.
    private func wireHostSubscriptions() {
        focusSubscription = host.observeFocusChanges { [weak self] in
            self?.handleSessionChange(self?.host.currentFocusedSession())
        }
        scrollbarSubscription = host.observeScrollbarChanges { [weak self] surfaceID in
            self?.queueScrollbarUpdate(surfaceID: surfaceID)
        }
        claudeAnchorSubscription = host.observeClaudeAnchorPayloads { [weak self] payload in
            self?.handleClaudeAnchorPayload(payload)
        }
        // The host's `observeFocusChanges` contract delivers the
        // observer's current value to the handler at subscribe time
        // via `observer.$current.receive(on: .main).sink`. The first
        // emission is the initial value at subscribe time; subsequent
        // transitions (focus changes, restoration completing) emit
        // normally through the same path.
    }

    // MARK: - Bulk-action signal

    public struct BulkExpansionState: Equatable, Sendable {
        public let tick: Int
        public let lastDirection: BulkDirection?
        public let layoutRevision: Int

        public init(tick: Int, lastDirection: BulkDirection?, layoutRevision: Int) {
            self.tick = tick
            self.lastDirection = lastDirection
            self.layoutRevision = layoutRevision
        }
    }

    // MARK: - Convenience derived state

    /// User-entry ids that currently have an anchor. View reads this
    /// to partition entries for the `.preAnchored` filter case while
    /// preserving the snapshot-boundary policy (no direct anchor-store
    /// access from the view).
    public var anchoredUserEntryIDs: Set<String> {
        Set(turnAnchorStore.orderedAnchors.map(\.userEntryID))
    }

    /// Single source of truth for "is the panel currently locked onto
    /// a specific snap turn?". True iff snap mode is on AND the active
    /// filter is `.turns(...)`.
    public var isLockedToTurn: Bool {
        guard scrollMode == .snap else { return false }
        if case .turns = entriesFilter { return true }
        return false
    }

    /// True iff the auto-expand pill is currently visible AND enabled.
    /// Read once per new-item observation in `autoExpandNewEntries()`.
    public var shouldAutoExpandNewItems: Bool {
        isLockedToTurn && expansionMode == .autoExpand
    }
}
