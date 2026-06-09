import AppKit
import Highlighter
import SwiftUI

/// Pure file-extension → highlight.js language alias map. Kept
/// outside the `@available(macOS 15, *)` `SyntaxHighlight` enum so
/// builders (Adapters/Claude) running before that availability
/// requirement can still pick a language hint at parse time.
enum LanguagePicker {
    /// Map a file path's extension to the highlight.js language alias.
    /// Returns nil when unknown — highlight.js then auto-detects.
    static func language(forFilePath path: String?) -> String? {
        guard let path else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":              return "swift"
        case "rs":                 return "rust"
        case "ts", "tsx":          return "typescript"
        case "js", "jsx", "mjs":   return "javascript"
        case "py":                 return "python"
        case "go":                 return "go"
        case "sh", "bash", "zsh":  return "bash"
        case "md", "markdown":     return "markdown"
        case "yml", "yaml":        return "yaml"
        case "json":               return "json"
        case "toml":               return "toml"
        case "html":               return "html"
        case "css":                return "css"
        case "c", "h":             return "c"
        case "cpp", "cc", "hpp":   return "cpp"
        case "java":               return "java"
        case "rb":                 return "ruby"
        case "kt", "kts":          return "kotlin"
        default:                   return nil
        }
    }
}

/// Minimal lazy/memoized wrapper around `Highlighter` (highlight.js via
/// JavaScriptCore). Phase H spike — validates inline syntax-highlighted
/// diff rows + Read-tool bodies without committing to a Coordinator
/// shape yet. If the spike sticks, this becomes a constructor-injected
/// service owned by the panel.
///
/// Cache key is `(language, contentHash)`; entries are AttributedString
/// so callers can pass directly to `Text(attributed)`. Without the
/// cache, every diff-row re-render reruns the JS engine.
@available(macOS 15, *)
@MainActor
enum SyntaxHighlight {

    /// Best-effort highlight. Returns `nil` when highlighter init fails
    /// (missing bundle resources) or the language tokenizer rejects the
    /// input — caller falls back to plain `Text(text)`.
    static func attributed(
        _ text: String,
        language: String?,
        font: NSFont,
        colorScheme: ColorScheme
    ) -> AttributedString? {
        guard let highlighter = Self.highlighter else { return nil }
        let theme = themeName(for: colorScheme)
        let key = CacheKey(text: text, language: language ?? "", theme: theme)
        if let cached = cache[key] { return cached }
        if currentTheme != theme {
            _ = highlighter.setTheme(theme)
            currentTheme = theme
        }
        highlighter.theme.setCodeFont(font)
        guard let ns = highlighter.highlight(text, as: language) else { return nil }
        let attr = bridgeToSwiftUI(ns)
        cache[key] = attr
        return attr
    }

    /// Pick a highlight.js theme matching the system colorScheme.
    /// `monokai` for dark — saturated reds / yellows / greens read
    /// strongly on dark terminals. `github` for light — sober but
    /// clearly differentiated tokens against a white surface.
    private static func themeName(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? "monokai" : "github"
    }

    /// Walk the NSAttributedString's `.foregroundColor` (NSColor) runs
    /// and emit an AttributedString with the equivalent SwiftUI-scope
    /// `foregroundColor: Color` attributes. Plain
    /// `AttributedString(NSAttributedString)` lifts NSColor into the
    /// AppKit attribute scope, which `Text` does NOT consult — so
    /// without this bridging step the highlighted runs render as plain
    /// text. Confirmed empirically on macOS 15 (Phase H spike, 2026-06-09).
    private static func bridgeToSwiftUI(_ ns: NSAttributedString) -> AttributedString {
        var attr = AttributedString(ns.string)
        ns.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: ns.length),
            options: []
        ) { value, nsRange, _ in
            guard let nsColor = value as? NSColor else { return }
            guard let range = Range<AttributedString.Index>(nsRange, in: attr) else { return }
            attr[range].foregroundColor = Color(nsColor: nsColor)
        }
        return attr
    }

    private static let highlighter: Highlighter? = {
        let h = Highlighter()
        if h == nil {
            print("[AgentXray] HighlighterSwift init failed — bundle resources missing?")
        } else {
            print("[AgentXray] HighlighterSwift init OK")
        }
        return h
    }()

    private struct CacheKey: Hashable {
        let text: String
        let language: String
        let theme: String
    }

    private static var cache: [CacheKey: AttributedString] = [:]
    private static var currentTheme: String = ""
}
