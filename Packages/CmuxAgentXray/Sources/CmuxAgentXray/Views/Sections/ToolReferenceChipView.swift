import SwiftUI

/// Inline chip for a ``Section/toolReference(toolName:)`` produced by
/// CC's client-side `ToolSearch` deferred-tool loader.
///
/// Renders the bare tool name (post-`mcp__<server>__` strip) with a
/// small wrench glyph + the MCP server chip when applicable. The chip
/// IS the rendering — there's no detail-tab interaction for tool refs.
///
/// MCP-server parsing reuses the same `mcp__<server>__<tool>` shape as
/// ``ToolEntry/mcpServer``. A fresh parse here keeps the view
/// self-contained (no need to plumb mcpServer through the Section).
@available(macOS 15, *)
struct ToolReferenceChipView: View {

    let toolName: String
    let palette: HudPalette

    var body: some View {
        let parsed = parse(toolName)
        HStack(spacing: 4) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 10))
                .foregroundStyle(palette.dim)
            Text(parsed.bareToolName)
                .font(Theme.Entry.title)
                .foregroundStyle(palette.primary)
            if let server = parsed.mcpServer {
                Text(server)
                    .font(Theme.Entry.meta)
                    .foregroundStyle(palette.cyan)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(palette.cyan.opacity(0.4), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(palette.expandedBackground)
        )
    }

    /// Strip `mcp__<server>__` prefix when present. Same convention as
    /// `parseMcpToolName` in the Claude builder; duplicated here to keep
    /// the view self-contained without forcing a dependency on the
    /// adapter layer.
    private func parse(_ name: String) -> (bareToolName: String, mcpServer: String?) {
        let prefix = "mcp__"
        guard name.hasPrefix(prefix) else { return (name, nil) }
        let afterPrefix = name.dropFirst(prefix.count)
        guard let sepRange = afterPrefix.range(of: "__") else { return (name, nil) }
        let server = String(afterPrefix[..<sepRange.lowerBound])
        let bare = String(afterPrefix[sepRange.upperBound...])
        return (bare, server.isEmpty ? nil : server)
    }
}
