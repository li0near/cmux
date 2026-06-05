import Foundation

/// Builds an `[Entry]` transcript from a stream of Codex rollout JSONL
/// lines.
///
/// Codex's rollout format only carries user prompts and assistant
/// text — there's no structured tool-call schema in the rollout (tool
/// calls live in a sidecar audit log). The panel surfaces user/assistant
/// turns plus session/turn metadata captured from `session_meta` /
/// `turn_context`.
///
/// Codex lacks per-line timestamps; the caller injects synthetic
/// timestamps via the `stampForIndex` callback (typically backed by
/// `CodexSyntheticTimestamps`).
struct CodexTranscriptBuilder {

    private(set) var entries: [Entry] = []

    /// Most recent `turn_context` payload seen — applied to the next
    /// agent turn as its model label.
    private var pendingModel: String?

    private var pendingTurn: PendingTurn?

    private(set) var sessionMeta: CodexSessionMeta?

    /// Synthetic timestamp generator. Caller increments per ingested line.
    var stampForIndex: (Int) -> Date = { _ in .distantPast }

    private var lineIndex = 0

    init() {}

    mutating func ingest(_ line: CodexRolloutLine) {
        defer { lineIndex += 1 }
        let stamp = stampForIndex(lineIndex)
        if let meta = line.sessionMeta {
            sessionMeta = meta
            return
        }
        if let ctx = line.turnContext, let m = ctx.model {
            pendingModel = m
            return
        }
        if let evt = line.eventMsg {
            handleEventMsg(evt, timestamp: stamp)
            return
        }
        if let item = line.responseItem {
            handleResponseItem(item, timestamp: stamp)
            return
        }
    }

    func transcript() -> [Entry] {
        guard let pending = pendingTurn else { return entries }
        return entries + [.agent(pending.finalize())]
    }

    mutating func reset() {
        entries.removeAll()
        pendingTurn = nil
        pendingModel = nil
        sessionMeta = nil
        lineIndex = 0
    }

    // MARK: - Handlers

    private mutating func handleEventMsg(_ evt: CodexEventMsg, timestamp: Date) {
        switch evt.innerType {
        case "user_message":
            guard let msg = evt.message,
                  let real = realCodexUserMessage(msg) else { return }
            flushPendingTurn()
            entries.append(.user(makeUser(
                id: "evt-\(lineIndex)",
                text: real,
                timestamp: timestamp
            )))
        default:
            break
        }
    }

    private mutating func handleResponseItem(_ item: CodexResponseItem, timestamp: Date) {
        let combined = item.textBlocks
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { return }
        switch item.role {
        case "user":
            guard let real = realCodexUserMessage(combined) else { return }
            flushPendingTurn()
            entries.append(.user(makeUser(
                id: "resp-\(lineIndex)",
                text: real,
                timestamp: timestamp
            )))
        case "assistant":
            if pendingTurn == nil {
                pendingTurn = PendingTurn(
                    id: "resp-ai-\(lineIndex)",
                    startTime: timestamp,
                    model: pendingModel
                )
            }
            if pendingTurn?.assistantText.isEmpty == false {
                pendingTurn?.assistantText.append("\n")
            }
            pendingTurn?.assistantText.append(combined)
        default:
            break
        }
    }

    private mutating func flushPendingTurn() {
        guard let pending = pendingTurn else { return }
        entries.append(.agent(pending.finalize()))
        pendingTurn = nil
    }

    private func makeUser(id: String, text: String, timestamp: Date) -> UserEntry {
        UserEntry(
            id: .fromJSONL(id),
            header: Header(
                icon: .user,
                name: String(
                    localized: "agentXray.entry.user.label",
                    defaultValue: "User",
                    bundle: .module
                ),
                timeMarker: .clock(timestamp)
            ),
            body: .text([text]),
            promptId: nil,
            wasQueued: false,
            isQueuedPending: false
        )
    }

    private struct PendingTurn {
        var id: String
        var startTime: Date
        var assistantText: String = ""
        var model: String?

        func finalize() -> AgentEntry {
            var subEntries: [AgentEntry.SubEntry] = []
            let trimmed = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let words = wordCount(trimmed)
                subEntries.append(.text(TextSubEntry(
                    kind: .assistant,
                    id: .derived(parent: id, kind: "assistantText"),
                    parentEntryID: .fromJSONL(id),
                    header: Header(
                        icon: .assistantText,
                        name: String(
                            localized: "agentXray.entry.assistantText.label",
                            defaultValue: "Assistant",
                            bundle: .module
                        ),
                        trailing: [.wordCount("\(words) words")],
                        timeMarker: .clock(startTime)
                    ),
                    body: Body(sections: [.text([trimmed], style: .normal)]),
                    wordCount: words
                )))
            }
            return AgentEntry(
                id: .fromJSONL(id),
                header: Header(
                    icon: .agent,
                    name: String(
                        localized: "agentXray.entry.agent.label.codex",
                        defaultValue: "Agent",
                        bundle: .module
                    ),
                    label: model,
                    timeMarker: .clock(startTime)
                ),
                body: Body(sections: []),  // Codex turns surface only via subEntries
                usage: .zero,
                model: model,
                subEntries: subEntries
            )
        }
    }

    /// Codex stuffs synthetic system reminders into
    /// `event_msg.user_message` payloads (e.g. `<system-reminder>` from
    /// the host). Those are not real user input — strip them.
    private func realCodexUserMessage(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let noiseWraps = ["<system-reminder>", "<environment_context>", "<user-instructions>"]
        for tag in noiseWraps {
            let close = "</" + tag.dropFirst()
            if trimmed.hasPrefix(tag) && trimmed.hasSuffix(close) {
                return nil
            }
        }
        return trimmed
    }
}
