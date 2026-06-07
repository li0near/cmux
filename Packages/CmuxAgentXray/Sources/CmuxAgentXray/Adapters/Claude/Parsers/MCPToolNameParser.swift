import Foundation

/// Parses an MCP tool name in the form `mcp__<server>__<tool>` into its
/// server and display components.
///
/// MCP tools follow Claude Code's name-mangling convention: when an MCP
/// server is registered (via `~/.claude.json`'s `mcpServers` map), CC
/// synthesizes a per-tool wire name `mcp__<configured-name>__<tool>`.
/// The wire `tool_use.name` carries this string; the only signal that
/// distinguishes an MCP tool from a built-in (Read, Bash, …) is the
/// `mcp__` prefix.
///
/// Returns `(name, nil)` for non-MCP names. MCP tools display the
/// `<tool>` suffix in `Header.name` and surface `<server>` as a chip;
/// non-MCP tools pass through unchanged.
enum MCPToolNameParser {
    static func parse(_ name: String) -> (display: String, server: String?) {
        let prefix = "mcp__"
        guard name.hasPrefix(prefix) else { return (name, nil) }
        let rest = name.dropFirst(prefix.count)
        let parts = rest.split(separator: "__", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return (name, nil)
        }
        return (String(parts[1]), String(parts[0]))
    }
}
