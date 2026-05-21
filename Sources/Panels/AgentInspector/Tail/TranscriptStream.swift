import Combine
import Foundation

/// Streams `AgentChunk`s built from a transcript file. Agent-agnostic: it
/// dispatches to the right line-decoder + chunk-builder based on the
/// `ResolvedAgentSession.AgentKind`.
///
/// Owns:
///   - a `JSONLTail` reading the file off-main
///   - one of `ClaudeChunkBuilder` / `CodexChunkBuilder` accumulating chunks
///
/// Publishes a debounced `chunks` snapshot on the main actor for SwiftUI
/// consumption. Per cmux's "no state mutation in body" policy, all rebuilds
/// happen in a Task spawned from a Combine subscription, never inside any
/// SwiftUI view's `body`.
@MainActor
final class TranscriptStream: ObservableObject {
    @Published private(set) var chunks: [AgentChunk] = []
    @Published private(set) var lineCount: Int = 0
    @Published private(set) var error: String?

    private var tail: JSONLTail?
    private var claudeBuilder = ClaudeChunkBuilder()
    private var codexBuilder = CodexChunkBuilder()
    private var codexStamps: CodexSyntheticTimestamps?
    private var currentKind: ResolvedAgentSession.AgentKind?
    private let queue = DispatchQueue(label: "com.cmux.agentInspector.transcript", qos: .utility)

    init() {}

    deinit {
        tail?.stop()
    }

    /// Switch to a new transcript file. Resets internal state and starts
    /// streaming. The file's current content is read synchronously here so
    /// the view goes directly from the previous session's chunks to the
    /// new session's chunks with no intermediate empty-state flash; the
    /// async tail then only watches for appends past the current offset.
    func attach(session: ResolvedAgentSession?) {
        guard let session, let path = session.transcriptPath, !path.isEmpty else {
            tail?.stop()
            tail = nil
            chunks = []
            lineCount = 0
            error = nil
            currentKind = nil
            return
        }

        tail?.stop()
        claudeBuilder.reset()
        codexBuilder.reset()
        error = nil
        currentKind = session.agentKind
        if session.agentKind == .codex {
            codexStamps = CodexSyntheticTimestamps.forFile(at: path)
            // Closure captures stamps by value; CodexChunkBuilder stamps each
            // line by index.
            let stamps = codexStamps!
            codexBuilder.stampForIndex = { idx in stamps.stamp(for: idx) }
        }

        // Synchronously ingest the file's current content. For typical
        // claude transcripts (50-200 KB) this is a few-millisecond read +
        // parse on main, far cheaper than a perceptible empty-state flash.
        let initialBytes = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        let initialText = String(data: initialBytes, encoding: .utf8) ?? ""
        let initialLines = initialText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let initialCount = ingestIntoBuilder(initialLines)
        chunks = currentSnapshot()
        lineCount = initialCount

        // Start the tail at the post-existing-content offset so async
        // emissions only deliver new appends, not duplicates of what we
        // just ingested.
        let nextTail = JSONLTail(
            path: path,
            initialOffset: UInt64(initialBytes.count)
        ) { [weak self] lines in
            self?.queue.async {
                self?.ingest(lines)
            }
        }
        tail = nextTail
        nextTail.start()
    }

    private func ingest(_ rawLines: [String]) {
        let localCount = ingestIntoBuilder(rawLines)
        guard localCount > 0 else { return }
        let snapshot = currentSnapshot()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.chunks = snapshot
            self.lineCount += localCount
        }
    }

    /// Decode each raw JSONL line and feed it into the active builder.
    /// Returns the number of lines successfully ingested. Pure compute —
    /// safe to call from any actor; callers handle main-thread snapshot
    /// publishing themselves.
    private func ingestIntoBuilder(_ rawLines: [String]) -> Int {
        guard let kind = currentKind else { return 0 }
        var localCount = 0
        for raw in rawLines {
            guard let data = raw.data(using: .utf8) else { continue }
            switch kind {
            case .claude:
                if let line = try? AgentInspectorJSON.decoder.decode(ClaudeJSONLLine.self, from: data) {
                    claudeBuilder.ingest(line)
                    localCount += 1
                }
            case .codex:
                if let line = try? AgentInspectorJSON.decoder.decode(CodexRolloutLine.self, from: data) {
                    codexBuilder.ingest(line)
                    localCount += 1
                }
            }
        }
        return localCount
    }

    private func currentSnapshot() -> [AgentChunk] {
        guard let kind = currentKind else { return [] }
        switch kind {
        case .claude: return claudeBuilder.snapshot()
        case .codex: return codexBuilder.snapshot()
        }
    }
}
