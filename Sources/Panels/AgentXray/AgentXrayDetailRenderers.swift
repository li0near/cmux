import AppKit
import CmuxAgentXray
import Foundation
import QuickLookUI
import SwiftUI

// MARK: - Host conformance

/// cmux-side implementation of `AgentXrayHost`'s detail-tab rich
/// rendering methods. Routes text content through cmux's existing
/// markdown WebView (with fenced-block coercion driving highlight.js
/// for code/diff/json) and image content through Apple's
/// `QLPreviewView` (`QuickLookUI`, the canonical embeddable
/// QuickLook surface — verified mid-2026 against Apple's DocC
/// data endpoints).
///
/// The package never imports cmux types; all renderer construction
/// happens here behind the `AgentXrayHost` protocol seam.
@available(macOS 15, *)
extension AgentXrayWorkspaceHost {
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
