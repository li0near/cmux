import Foundation
import SwiftUI

/// Pretty-printed JSON content renderer (foundation stub).
///
/// Phase D foundation only — renders pretty-printed JSON as a
/// monospaced `Text(...)` with no syntax coloring. Real JSON
/// renderer (key/value coloring, collapsible nodes) ships in a
/// follow-up PR — see `MIGRATION_PLAN.md` §14 for the rollout.
@available(macOS 15, *)
struct JsonSectionView: View {

    let text: String
    let palette: HudPalette

    var body: some View {
        Text(prettyPrinted(text))
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(palette.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Best-effort pretty-print. Returns the original text on parse
    /// failure — the shape sniffer should have validated JSON before
    /// dispatching here, so falling back to raw is safe.
    private func prettyPrinted(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
              ),
              let string = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return string
    }
}
