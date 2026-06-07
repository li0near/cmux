import AppKit
import CmuxAgentXray
import Foundation
import SwiftUI

// MARK: - Host conformance

/// cmux-side implementation of `AgentXrayHost`'s detail-tab routing.
/// Switches on `DetailSource` directly: file paths open via cmux's
/// panel pipeline, inline text / image content materializes to a
/// temp file with the suggested basename (extension drives cmux's
/// dispatch — `.md` → `MarkdownPanel`; everything else →
/// `FilePreviewPanel`), and transcripts keep in-package detail-mode
/// rendering.
///
/// The package never imports cmux types; all panel-open construction
/// happens here behind the `AgentXrayHost` protocol seam.
@available(macOS 15, *)
extension AgentXrayWorkspaceHost {
    @discardableResult
    func openDetailTabRouting(
        content: DetailContent,
        fromPanelID panelID: UUID,
        activate: Bool
    ) -> AgentXrayPanel? {
        switch content.source {
        case .file(let path):
            _ = openFileInPanel(
                URL(fileURLWithPath: path),
                activate: activate,
                reuseExisting: true
            )
            return nil

        case .text(let body, let filename):
            let key = cacheKey(
                sourceEntryID: content.sourceEntryID,
                filename: filename
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let url = await self.materializeText(
                    body: body,
                    filename: filename,
                    key: key
                ) {
                    _ = self.openFileInPanel(
                        url,
                        activate: activate,
                        reuseExisting: true
                    )
                }
            }
            return nil

        case .image(let source, let filename):
            let key = cacheKey(
                sourceEntryID: content.sourceEntryID,
                filename: filename
            )
            let mediaType = source.mediaType
            let data = source.data
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let url = await self.materializeImage(
                    base64: data,
                    mediaType: mediaType,
                    filename: filename,
                    key: key
                ) {
                    _ = self.openFileInPanel(
                        url,
                        activate: activate,
                        reuseExisting: true
                    )
                }
            }
            return nil

        case .transcript:
            guard let workspace else { return nil }
            return workspace.openAgentXrayDetail(
                content: content,
                fromPanelID: panelID
            )?.xrayPanel
        }
    }

    // MARK: - Materialization helpers

    /// Write inline UTF-8 text to a temp file at `<workspace>/<key>`,
    /// where the key embeds the suggested basename so the on-disk
    /// extension matches what cmux's panel dispatch expects. Re-uses
    /// an existing file when the key matches (so re-clicks of the
    /// same row dedupe and `reuseExisting` on `openFileInPanel`
    /// refocuses the existing panel).
    fileprivate func materializeText(
        body: String,
        filename: String,
        key: String
    ) async -> URL? {
        let dir = AgentXrayDetailFileCache.directory(for: workspaceID)
        let url = dir.appendingPathComponent(key)
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

    /// Decode + write base64 image bytes to a temp file at
    /// `<workspace>/<key>`. The key embeds `filename` so the on-disk
    /// extension matches the image's media type.
    fileprivate func materializeImage(
        base64: String,
        mediaType: String,
        filename: String,
        key: String
    ) async -> URL? {
        let dir = AgentXrayDetailFileCache.directory(for: workspaceID)
        let url = dir.appendingPathComponent(key)
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

    /// Cache key combines the source entry id with the suggested
    /// filename so two clicks on the same row produce the same path
    /// (re-uses the existing materialized file) but two different
    /// rows that happen to share content (rare) still get distinct
    /// files. The id-side is sanitized for filesystem safety.
    fileprivate func cacheKey(sourceEntryID: String, filename: String) -> String {
        let safe = sourceEntryID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(safe)-\(filename)"
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
