import AppKit
import CmuxAgentXray
import Foundation
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
    /// the same row dedupe and `reuseExisting` on `openFileInPanel`
    /// refocuses the existing panel).
    fileprivate func materializeText(
        body: String,
        ext: String,
        key: String
    ) async -> URL? {
        let dir = AgentXrayDetailFileCache.directory(for: workspaceID)
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
        let dir = AgentXrayDetailFileCache.directory(for: workspaceID)
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

// MARK: - Temp-file cache

/// Workspace-scoped cache directory for materialized AgentX-ray
/// detail-tab files. Lifecycle is host-owned: the directory is
/// created lazily on first materialization, cleared when the
/// workspace tears down, and the parent `cmux-agentxray-files/` is
/// purged at app launch (see `App/CmuxApp.swift`).
enum AgentXrayDetailFileCache {

    /// Root directory under `NSTemporaryDirectory()` shared by every
    /// workspace. Purged at app launch from `applicationDidFinishLaunching`.
    static let rootURL: URL = URL(
        fileURLWithPath: NSTemporaryDirectory(),
        isDirectory: true
    ).appendingPathComponent("cmux-agentxray-files", isDirectory: true)

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

    /// Removes the root directory + the legacy Phase D-rev
    /// `cmux-agentxray-images/` directory. Call once at app launch
    /// so stale files from a prior session don't accumulate.
    static func purgeAll() {
        try? FileManager.default.removeItem(at: rootURL)
        // Legacy Phase D-rev location; clean up after the rename.
        let legacy = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("cmux-agentxray-images", isDirectory: true)
        try? FileManager.default.removeItem(at: legacy)
    }
}
