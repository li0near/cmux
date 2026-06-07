import AppKit
import CmuxAgentXray
import Foundation
import QuickLookUI
import SwiftUI

// MARK: - Host conformance

/// cmux-side implementation of `AgentXrayHost`'s detail-tab routing
/// + image-open seam. Phase E redirects every non-transcript detail
/// click through cmux's existing panel-open pipeline
/// (`Workspace.openFileSurfaces`) so users get full panel chrome
/// (font / copy / edit / "Open in…" / image zoom) for free instead
/// of in-package embedded renderers.
///
/// The package never imports cmux types; all panel-open construction
/// happens here behind the `AgentXrayHost` protocol seam.
@available(macOS 15, *)
extension AgentXrayWorkspaceHost {
    /// Phase E routing: transcript content keeps the existing
    /// AgentXrayPanel.detail flow; everything else materializes (or
    /// opens an existing path) and dispatches to a real cmux panel
    /// via `openFileInPanel`.
    @discardableResult
    func openDetailTabRouting(
        content: DetailContent,
        fromPanelID panelID: UUID
    ) -> AgentXrayPanel? {
        // 1. Transcript: keep in-package rendering (sub-agent /
        //    abandoned-branch entries are structured Entry arrays,
        //    not file-shaped).
        if let entries = content.entries, !entries.isEmpty {
            guard let workspace else { return nil }
            return workspace.openAgentXrayDetail(
                content: content,
                fromPanelID: panelID
            )?.xrayPanel
        }

        // 2. Already on disk (offloaded `<persisted-output>`): hand
        //    the path straight to cmux's panel pipeline.
        if let existingPath = content.existingFilePath {
            _ = openFileInPanel(
                URL(fileURLWithPath: existingPath),
                activate: false,
                reuseExisting: true
            )
            return nil
        }

        // 3. Inline text content: materialize to a temp file, then open.
        let body = content.body
        let ext = fileExtension(for: content.contentType)
        let key = cacheKey(sourceEntryID: content.sourceEntryID, suffix: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let url = await self.materializeText(body: body, ext: ext, key: key) {
                _ = self.openFileInPanel(
                    url,
                    activate: false,
                    reuseExisting: true
                )
            }
        }
        return nil
    }

    /// Image short-circuit (called from `AgentXrayPanel.openDetail` for
    /// `.image` sections). Decodes base64 off-main, writes a stable
    /// temp PNG/JPEG, and opens it via cmux's panel pipeline — the
    /// resulting `FilePreviewPanel` gives users zoom / pan / rotate
    /// / spacebar QuickLook / "Open in Preview" for free.
    func openImageInPanel(
        source: ImageSource,
        sourceEntryID: String,
        sectionIndex: Int
    ) {
        let key = cacheKey(
            sourceEntryID: sourceEntryID,
            suffix: "img\(sectionIndex)"
        )
        let mediaType = source.mediaType
        let data = source.data
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let url = await self.materializeImage(
                base64: data,
                mediaType: mediaType,
                key: key
            ) {
                _ = self.openFileInPanel(
                    url,
                    activate: false,
                    reuseExisting: true
                )
            }
        }
    }

    // MARK: - Materialization helpers

    /// Write inline text to a temp file with the right extension.
    /// Re-uses an existing file when the key matches (so re-clicks of
    /// the same row dedupe and reuseExisting on `openFileInPanel`
    /// refocuses the existing panel).
    fileprivate func materializeText(
        body: String,
        ext: String,
        key: String
    ) async -> URL? {
        let dir = AgentXrayDetailImageCache.directory(for: workspaceID)
        let url = dir.appendingPathComponent("\(key).\(ext)")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return await Task.detached(priority: .utility) { [dir, url, body] in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try body.write(to: url, atomically: true, encoding: .utf8)
                return url
            } catch {
                return nil
            }
        }.value
    }

    /// Decode + write base64 image bytes to a temp file. Re-uses the
    /// file when the key already exists.
    fileprivate func materializeImage(
        base64: String,
        mediaType: String,
        key: String
    ) async -> URL? {
        let ext = extensionForMediaType(mediaType)
        let dir = AgentXrayDetailImageCache.directory(for: workspaceID)
        let url = dir.appendingPathComponent("\(key).\(ext)")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return await Task.detached(priority: .utility) { [dir, url, base64] in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                guard let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                    return nil
                }
                try bytes.write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }.value
    }

    fileprivate func cacheKey(sourceEntryID: String, suffix: String?) -> String {
        let safe = sourceEntryID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if let suffix { return "\(safe)-\(suffix)" }
        return safe
    }

    fileprivate func fileExtension(for contentType: ContentType) -> String {
        switch contentType {
        case .markdown:           return "md"
        case .json:               return "json"
        case .diff:               return "diff"
        case .plainText:          return "txt"
        case .transcript:         return "txt"
        case .code(let language): return mapLanguageToExtension(language)
        }
    }

    fileprivate func mapLanguageToExtension(_ language: String?) -> String {
        guard let lang = language?.lowercased() else { return "txt" }
        switch lang {
        case "swift":              return "swift"
        case "python", "py":       return "py"
        case "typescript", "ts":   return "ts"
        case "tsx":                return "tsx"
        case "javascript", "js":   return "js"
        case "jsx":                return "jsx"
        case "bash", "sh":         return "sh"
        case "json":               return "json"
        case "markdown", "md":     return "md"
        case "diff":               return "diff"
        case "html":               return "html"
        case "css":                return "css"
        case "yaml", "yml":        return "yml"
        case "rust", "rs":         return "rs"
        case "go":                 return "go"
        case "c":                  return "c"
        case "cpp", "c++":         return "cpp"
        case "objc", "objectivec": return "m"
        default:                   return "txt"
        }
    }

    func detailBodyView(content: DetailContent) -> AnyView {
        AnyView(
            AgentXrayDetailBodyView(
                content: content,
                workspaceID: workspaceID
            )
        )
    }

    func detailImageView(
        source: ImageSource,
        sourceEntryID: String,
        sectionIndex: Int
    ) -> AnyView {
        AnyView(
            AgentXrayDetailImageView(
                source: source,
                sourceEntryID: sourceEntryID,
                sectionIndex: sectionIndex,
                workspaceID: workspaceID
            )
        )
    }
}

// MARK: - Text content (markdown + fenced code/diff/json/plain)

/// Detail-tab text content view. Routes every non-image
/// `DetailContent` shape through `MarkdownWebRenderer`:
///  - `.markdown` → passed through (full marked.js + highlight.js).
///  - `.code(language)` → wrapped in ` ```<language> ` so
///    highlight.js syntax-colors it.
///  - `.json` / `.diff` → wrapped in ` ```json ` / ` ```diff `;
///    highlight.js handles both natively.
///  - `.plainText` / `.transcript` (transcript fallback) → wrapped
///    in an unannotated ` ``` ` fence so the WebView preserves
///    monospace + whitespace without trying to interpret accidental
///    markdown.
///
/// One `MarkdownRendererSession` per detail-tab instance; SwiftUI
/// holds it via `@State` so the underlying WKWebView survives
/// representable-recreation across body re-evaluations.
@MainActor
@available(macOS 15, *)
private struct AgentXrayDetailBodyView: View {

    let content: DetailContent
    let workspaceID: UUID

    @State private var rendererSession = MarkdownRendererSession()

    private static let defaultBackgroundColor: NSColor = .windowBackgroundColor

    var body: some View {
        let bg = Self.defaultBackgroundColor
        MarkdownWebRenderer(
            markdown: wrap(content),
            theme: MarkdownWebTheme.resolve(backgroundColor: bg),
            backgroundColor: bg,
            panelId: panelIDForContent,
            workspaceId: workspaceID,
            filePath: filePathForContent,
            fontSize: MarkdownFontSizeSettings.resolvedDefault(),
            fontFamily: MarkdownFontFamily.resolvedDefault(),
            maxContentWidth: MarkdownMaxWidthSettings.resolvedDefault(),
            session: rendererSession,
            onRequestPanelFocus: {}
        )
    }

    /// Stable id keyed off the source entry so the WebView coordinator
    /// preserves its identity across content updates of the same tab.
    private var panelIDForContent: UUID {
        if let uuid = UUID(uuidString: content.sourceEntryID) {
            return uuid
        }
        return UUID()
    }

    /// File path is consumed by `MarkdownWebRenderer`'s relative-image
    /// resolver. Detail-tab content has no real path; pass empty.
    private var filePathForContent: String { "" }

    /// Coerce a `DetailContent` into a markdown source string the
    /// WebView can render. Markdown passes through; code/diff/json/
    /// plain are fence-wrapped so highlight.js handles them.
    private func wrap(_ content: DetailContent) -> String {
        switch content.contentType {
        case .markdown:
            return content.body
        case .code(let language):
            let lang = language ?? ""
            return "```\(lang)\n\(content.body)\n```"
        case .json:
            return "```json\n\(content.body)\n```"
        case .diff:
            return "```diff\n\(content.body)\n```"
        case .plainText, .transcript:
            return "```\n\(content.body)\n```"
        }
    }
}

// MARK: - Image content (QuickLookUI)

/// Detail-tab image preview. Materializes the inline-base64 bytes
/// to a temp file (lifecycle owned by the host, evicted when the
/// host deinits or at app launch) and points Apple's
/// `QLPreviewView` at the file URL. Inherits zoom (pinch /
/// Cmd-scroll) and pan (drag) from the system component for free;
/// no rotate (`FilePreviewPanel`'s extra is not exposed by
/// `QLPreviewView`, acceptable for the screenshot-shaped corpus).
///
/// Decode runs on `Task.detached` to keep the main thread free —
/// matches `ImageSource`'s documented lazy-decode pattern.
@MainActor
@available(macOS 15, *)
private struct AgentXrayDetailImageView: View {

    let source: ImageSource
    let sourceEntryID: String
    let sectionIndex: Int
    let workspaceID: UUID

    @State private var resolvedURL: URL?
    @State private var failureMessage: String?

    var body: some View {
        Group {
            if let url = resolvedURL {
                QLPreviewViewRepresentable(url: url)
            } else if let message = failureMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: cacheKey) {
            await materializeIfNeeded()
        }
    }

    private var cacheKey: String { "\(sourceEntryID)-\(sectionIndex)" }

    private func materializeIfNeeded() async {
        let directory = AgentXrayDetailImageCache.directory(for: workspaceID)
        let url = directory.appendingPathComponent("\(cacheKey).\(extensionForMediaType(source.mediaType))")
        if FileManager.default.fileExists(atPath: url.path) {
            resolvedURL = url
            return
        }

        let captured = source.data
        let result: Result<URL, Error> = await Task.detached(priority: .utility) { [directory, url] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard let bytes = Data(base64Encoded: captured, options: .ignoreUnknownCharacters) else {
                    return .failure(AgentXrayDetailImageError.invalidBase64)
                }
                try bytes.write(to: url, options: .atomic)
                return .success(url)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let url):
            resolvedURL = url
        case .failure(let error):
            failureMessage = String(
                localized: "agentXray.detail.image.failed",
                defaultValue: "Failed to materialize image: \(error.localizedDescription)"
            )
        }
    }
}

private enum AgentXrayDetailImageError: LocalizedError {
    case invalidBase64

    var errorDescription: String? {
        switch self {
        case .invalidBase64:
            return "Image data is not valid base64."
        }
    }
}

private func extensionForMediaType(_ mediaType: String) -> String {
    switch mediaType.lowercased() {
    case "image/png":  return "png"
    case "image/jpeg", "image/jpg": return "jpg"
    case "image/gif":  return "gif"
    case "image/webp": return "webp"
    case "image/heic": return "heic"
    case "image/svg+xml": return "svg"
    default:           return "bin"
    }
}

// MARK: - QLPreviewView wrapper

/// Embeds Apple's `QLPreviewView` (the modern `QuickLookUI`
/// framework, macOS 12+; legacy `Quartz.QLPreviewView` re-export
/// 404s on Apple's DocC site) as a SwiftUI subview. NOT cmux's
/// existing private `QuickLookPreviewView` — that wrapper is
/// hard-coupled to `FilePreviewPanel` (`setPanel(_:)` lifecycle,
/// `panel.nativeViewSessions.quickLook`) and unusable from the
/// `AgentXrayPanel` context.
///
/// Style `.normal` gives the chrome-less full-bleed preview that
/// fills the parent. Pinch/Cmd-scroll-zoom and click-drag-pan are
/// native to `QLPreviewView`.
@MainActor
@available(macOS 15, *)
private struct QLPreviewViewRepresentable: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as any QLPreviewItem
        view.autostarts = true
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? URL) != url {
            nsView.previewItem = url as any QLPreviewItem
        }
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}

// MARK: - Temp-file cache

/// Workspace-scoped cache directory for materialized inline-base64
/// images. Lifecycle is host-owned: the directory is created lazily
/// on first materialization, cleared when the workspace tears down,
/// and the parent `cmux-agentxray-images/` is purged at app launch
/// (see `App/CmuxApp.swift`).
enum AgentXrayDetailImageCache {

    /// Root directory under `NSTemporaryDirectory()` shared by every
    /// workspace. Purged at app launch from `CmuxApp.applicationDidFinishLaunching`.
    static let rootURL: URL = URL(
        fileURLWithPath: NSTemporaryDirectory(),
        isDirectory: true
    ).appendingPathComponent("cmux-agentxray-images", isDirectory: true)

    /// Per-workspace subdirectory. Creates lazily.
    static func directory(for workspaceID: UUID) -> URL {
        rootURL.appendingPathComponent(workspaceID.uuidString, isDirectory: true)
    }

    /// Removes the workspace's directory and everything inside it.
    /// Call from `AgentXrayWorkspaceHost.deinit`.
    static func clear(workspaceID: UUID) {
        let url = directory(for: workspaceID)
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes the root directory. Call once at app launch so stale
    /// images from a prior session don't accumulate.
    static func purgeAll() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
