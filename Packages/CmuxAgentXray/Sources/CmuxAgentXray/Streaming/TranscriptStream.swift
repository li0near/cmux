import Foundation
public import Observation

/// Streams `Entry` values built from a transcript file. Agent-agnostic:
/// dispatches to the right line-decoder + transcript-builder based on
/// the resolved `ResolvedAgentSession.AgentKind`.
///
/// Owns:
///   - a `JSONLTail` reading the file off-main and delivering line
///     batches onto the main actor via `Task { @MainActor in … }`
///   - one of `ClaudeTranscriptBuilder` / `CodexTranscriptBuilder`
///     accumulating entries
///
/// All builder mutations and `entries` updates happen on the main
/// actor — the class is `@MainActor`-isolated and there is no shared
/// mutable state touched off-main. SwiftUI consumers observe via the
/// `@Observable` macro's tracking mechanism (macOS 15 Observation
/// framework).
@MainActor
@available(macOS 15, *)
@Observable
public final class TranscriptStream {
    public private(set) var entries: [Entry] = []
    public private(set) var lineCount: Int = 0
    public private(set) var error: String?

    @ObservationIgnored private var tail: JSONLTail?
    @ObservationIgnored private var remoteStream: RemoteJSONLStream?
    @ObservationIgnored private var claudeBuilder: ClaudeTranscriptBuilder
    @ObservationIgnored private var codexBuilder: CodexTranscriptBuilder
    @ObservationIgnored private var codexStamps: CodexSyntheticTimestamps?
    @ObservationIgnored private var currentKind: ResolvedAgentSession.AgentKind?
    @ObservationIgnored private let logger: any AgentXrayLogger

    public init(logger: any AgentXrayLogger = NoOpAgentXrayLogger()) {
        self.logger = logger
        self.claudeBuilder = ClaudeTranscriptBuilder(logger: logger)
        self.codexBuilder = CodexTranscriptBuilder()
    }

    deinit {
        tail?.stop()
        remoteStream?.stop()
    }

    /// Switch to a new transcript file. Resets internal state and
    /// starts streaming. The file's current content is read
    /// synchronously so the view goes directly from the previous
    /// session's entries to the new session's entries with no
    /// intermediate empty-state flash; the async tail then only
    /// watches for appends past the current offset.
    ///
    /// Local sessions stream via `JSONLTail` (DispatchSource vnode
    /// watch on the local file). Remote sessions stream via
    /// `RemoteJSONLStream` (`ssh exec tail -F` over the existing
    /// SSH ControlMaster socket); the initial-fill content arrives
    /// over the wire as part of the same `tail -n +1 -F` stream
    /// rather than being read synchronously.
    public func attach(session: ResolvedAgentSession?) {
        guard let session, let path = session.transcriptPath, !path.isEmpty else {
            tail?.stop()
            tail = nil
            remoteStream?.stop()
            remoteStream = nil
            entries = []
            lineCount = 0
            error = nil
            currentKind = nil
            return
        }

        tail?.stop()
        tail = nil
        remoteStream?.stop()
        remoteStream = nil
        claudeBuilder.reset()
        codexBuilder.reset()
        entries = []
        lineCount = 0
        error = nil
        currentKind = session.agentKind
        if session.agentKind == .codex {
            let stamps = CodexSyntheticTimestamps.forFile(at: path)
            codexStamps = stamps
            codexBuilder.stampForIndex = { idx in stamps.stamp(for: idx) }
        }

        switch session.transport {
        case .local:
            attachLocal(path: path)
        case .remote(let sshTransport):
            attachRemote(path: path, transport: sshTransport)
        }
    }

    // MARK: - Local transport

    private func attachLocal(path: String) {
        // Synchronously ingest current content (~few ms on main).
        let initialBytes = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        let initialText = String(data: initialBytes, encoding: .utf8) ?? ""
        let initialLines = initialText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let initialCount = ingestIntoBuilder(initialLines)
        entries = currentTranscript()
        lineCount = initialCount

        // Start the tail at post-existing-content offset.
        let nextTail = JSONLTail(
            path: path,
            initialOffset: UInt64(initialBytes.count),
            logger: logger
        ) { [weak self] lines in
            Task { @MainActor [weak self] in
                self?.ingest(lines)
            }
        }
        tail = nextTail
        nextTail.start()
    }

    // MARK: - Remote transport

    private func attachRemote(path: String, transport: SSHTransport) {
        // Remote initial fill arrives via the same stream as appends
        // (`tail -n +1 -F` re-emits from the start). No synchronous
        // round-trip on main.
        let stream = RemoteJSONLStream(
            transport: transport,
            remotePath: path,
            logger: logger
        ) { [weak self] lines in
            Task { @MainActor [weak self] in
                self?.ingest(lines)
            }
        }
        remoteStream = stream
        stream.start()
    }

    private func ingest(_ rawLines: [String]) {
        let localCount = ingestIntoBuilder(rawLines)
        guard localCount > 0 else { return }
        entries = currentTranscript()
        lineCount += localCount
    }

    private func ingestIntoBuilder(_ rawLines: [String]) -> Int {
        guard let kind = currentKind else { return 0 }
        var localCount = 0
        for raw in rawLines {
            guard let data = raw.data(using: .utf8) else { continue }
            switch kind {
            case .claude:
                if let line = try? AgentXrayJSON.decoder.decode(
                    ClaudeJSONLLine.self, from: data
                ) {
                    claudeBuilder.ingest(line)
                    localCount += 1
                }
            case .codex:
                if let line = try? AgentXrayJSON.decoder.decode(
                    CodexRolloutLine.self, from: data
                ) {
                    codexBuilder.ingest(line)
                    localCount += 1
                }
            }
        }
        return localCount
    }

    private func currentTranscript() -> [Entry] {
        guard let kind = currentKind else { return [] }
        switch kind {
        case .claude: return claudeBuilder.transcript()
        case .codex:  return codexBuilder.transcript()
        }
    }
}
