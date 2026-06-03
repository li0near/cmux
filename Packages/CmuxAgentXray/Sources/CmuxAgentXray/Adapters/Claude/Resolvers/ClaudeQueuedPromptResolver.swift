import Foundation

/// Aggregated state about queued prompts in a Claude session.
///
/// Two surfaces are folded into one resolver because they share the
/// same source data (`queue-operation enqueue` lines + their consumers):
///
/// 1. **`wasQueuedSlashUuids`** — UUIDs of `<command-message>` user
///    lines whose reconstructed `/<cmd> [args]` text matched a prior
///    `queue-operation enqueue`. The dispatcher flags these so the
///    resulting `UserEntry` carries `wasQueued: true`.
///
/// 2. **`pendingPrompts`** — descriptors for `enqueue` lines whose
///    content has not been consumed by either an
///    `attachment.queued_command` line or a slash-command user line.
///    The transcript builder turns each into a synthetic
///    `UserEntry(wasQueued: true, isQueuedPending: true)` pinned to
///    the tail of the entry list.
struct ClaudeQueuedPromptResolution: Equatable {
    let wasQueuedSlashUuids: Set<String>
    let pendingPrompts: [ClaudePendingPrompt]

    init(wasQueuedSlashUuids: Set<String>, pendingPrompts: [ClaudePendingPrompt]) {
        self.wasQueuedSlashUuids = wasQueuedSlashUuids
        self.pendingPrompts = pendingPrompts
    }
}

/// Thin data descriptor for one pending queued prompt. The builder
/// constructs the `UserEntry` (with Header + Body) from this.
struct ClaudePendingPrompt: Equatable {
    let id: String
    let timestamp: Date?
    let text: String
}

/// Pure-function resolver. Mirrors `ClaudeBranchResolver`'s shape:
/// safe to call from any thread, no I/O, no shared state.
enum ClaudeQueuedPromptResolver {
    static func resolve(lines: [ClaudeJSONLLine]) -> ClaudeQueuedPromptResolution {
        let slashUuids = computeWasQueuedSlashUuids(lines: lines)
        let pending = computePendingPrompts(lines: lines)
        return ClaudeQueuedPromptResolution(
            wasQueuedSlashUuids: slashUuids,
            pendingPrompts: pending
        )
    }

    /// Identify slash-command user-line UUIDs whose reconstructed
    /// `/cmd args` text matches a prior `queue-operation enqueue`.
    /// Pairing is FIFO by content-equality.
    private static func computeWasQueuedSlashUuids(
        lines: [ClaudeJSONLLine]
    ) -> Set<String> {
        var enqueueCounts: [String: Int] = [:]
        for line in lines
        where line.type == "queue-operation" && line.operation == "enqueue" {
            let text = (line.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                enqueueCounts[text, default: 0] += 1
            }
        }
        var matched: Set<String> = []
        for line in lines {
            guard line.type == "user", let uuid = line.uuid else { continue }
            guard let slashText = consumedSlashCommandText(line) else { continue }
            guard let n = enqueueCounts[slashText], n > 0 else { continue }
            enqueueCounts[slashText] = n - 1
            matched.insert(uuid)
        }
        return matched
    }

    /// Tail-of-list pending queue handling. Matches each `enqueue`
    /// content against the bag of consumed-prompt texts emitted by
    /// `attachment.queued_command` lines and `<command-message>` user
    /// lines. Any leftover enqueue produces a pending-prompt
    /// descriptor.
    private static func computePendingPrompts(
        lines: [ClaudeJSONLLine]
    ) -> [ClaudePendingPrompt] {
        var consumedCounts: [String: Int] = [:]
        for line in lines {
            if line.type == "attachment", line.attachment?.type == "queued_command" {
                let text = (line.attachment?.prompt?.firstText() ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    consumedCounts[text, default: 0] += 1
                }
                continue
            }
            if line.type == "user",
               let slashText = consumedSlashCommandText(line) {
                consumedCounts[slashText, default: 0] += 1
            }
        }

        var pending: [ClaudePendingPrompt] = []
        for line in lines
        where line.type == "queue-operation" && line.operation == "enqueue" {
            let text = (line.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if let n = consumedCounts[text], n > 0 {
                consumedCounts[text] = n - 1
                continue
            }
            let id = "queue-pending:\(line.timestamp?.timeIntervalSince1970 ?? 0):\(text.hashValue)"
            pending.append(ClaudePendingPrompt(
                id: id,
                timestamp: line.timestamp,
                text: text
            ))
        }
        return pending
    }

    /// Reconstructs the `/cmd args` form of a slash-command user line
    /// for matching against `queue-operation enqueue` content. Returns
    /// nil when the line is not a slash-command-shaped user line.
    static func consumedSlashCommandText(_ line: ClaudeJSONLLine) -> String? {
        let raw = line.message?.content?.firstText() ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<command-message>") || trimmed.hasPrefix("<command-name>") else {
            return nil
        }
        guard case let .slashCommandInput(name, args) = ClaudeContentDetector.classify(trimmed) else {
            return nil
        }
        let slashName = name.hasPrefix("/") ? name : "/\(name)"
        if let args, !args.isEmpty {
            return "\(slashName) \(args)"
        }
        return slashName
    }
}
