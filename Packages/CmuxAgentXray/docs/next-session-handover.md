# SUPERSEDED — see G6 commit (b53b3e776)

This handover described the streaming-dispatcher state mid-Phase-G.
Phase G (G0 → G6) has fully landed. The current per-line dispatch
model is documented in:

- `Packages/CmuxAgentXray/docs/claude-jsonl-mapping.md` §6 (per-line
  dispatch + universal alias rule + awaitingParent pool).
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Adapters/Claude/ClaudeTranscriptBuilder.swift`
  doc-comment header.
- `Packages/CmuxAgentXray/Sources/CmuxAgentXray/Models/Transcript.swift`
  doc-comment header (index-aliasing semantics, slice scope).

This file is preserved only for code archaeology — its descriptions
of `ClaudeBranchResolver`, `ClaudeTurnDurationResolver`,
`ClaudeQueuedPromptResolver`, `ClaudeSkillCommandResolver`, the
`PendingTurn` scratchpad, the skeleton-tracking variables, and the
`closePendingTurn` boundary all describe machinery deleted by Phase G.
None of them exist in the codebase anymore.
