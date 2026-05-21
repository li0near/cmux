import Foundation

/// Friendly model-name parser for Anthropic model ids. Mirrors
/// `claude-devtools/src/renderer/utils/modelParser.ts` lines 34-137 — it
/// understands both the new `claude-{family}-{major}-{minor}-{date}` format
/// (e.g. `claude-sonnet-4-5-20250929` → `Sonnet 4.5`) and the legacy
/// `claude-3-5-sonnet-20241022` / `claude-3-opus-20240229` shapes.
///
/// Returns nil when the id doesn't match any known shape so the caller can
/// fall back to displaying the raw id.
enum ClaudeModelNameMap {
    static func friendlyName(for modelId: String) -> String? {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        guard lowered.hasPrefix("claude") else {
            // Non-claude model ids (e.g. opencode/codex) — return as-is so
            // the renderer still shows something useful.
            return trimmed
        }

        let stripped = String(lowered.dropFirst("claude".count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let parts = stripped.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }

        // New format: `{family}-{major}-{minor}[-{suffix}|-{date}]`
        // e.g. `sonnet-4-5-20250929`, `opus-4-7`, `haiku-4-5-20251001`.
        if let family = parseFamily(parts[0]),
           parts.count >= 3,
           let major = Int(parts[1]),
           let minor = Int(parts[2]) {
            return "\(family.display) \(major).\(minor)"
        }

        // Legacy format: `{majorVersion}-{minorVersion?}-{family}-{date}`
        // e.g. `3-5-sonnet-20241022` or `3-opus-20240229`.
        if let major = Int(parts[0]) {
            // Detect optional minor version
            if parts.count >= 4,
               let minor = Int(parts[1]),
               let family = parseFamily(parts[2]) {
                return "\(family.display) \(major).\(minor)"
            }
            if parts.count >= 3,
               let family = parseFamily(parts[1]) {
                return "\(family.display) \(major)"
            }
        }

        return nil
    }

    private struct Family {
        let display: String
    }

    private static func parseFamily(_ token: String) -> Family? {
        switch token.lowercased() {
        case "opus": return Family(display: "Opus")
        case "sonnet": return Family(display: "Sonnet")
        case "haiku": return Family(display: "Haiku")
        default: return nil
        }
    }
}
