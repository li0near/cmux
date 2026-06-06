import AppKit
import SwiftUI

/// Inline thumbnail for an ``ImageSource``-bearing ``Section/image(_:)``.
///
/// Renders an 80×80 thumbnail in the row body. Click opens the detail
/// tab (full-size rendering ships in Phase D's renderer pass; for Phase B
/// the detail tab shows the same thumbnail size).
///
/// Decoding is **lazy and off-main**: a `Task.detached` decodes the
/// base64 + constructs an `NSImage` only after the view appears. Result
/// is cached in `@State` so re-renders don't re-decode. ~150 KB / image
/// in the corpus today, so eager decode at builder time would block the
/// main thread.
@available(macOS 15, *)
struct ImageThumbnailView: View {

    let source: ImageSource
    let action: () -> Void

    @State private var image: NSImage?
    @State private var failed: Bool = false

    var body: some View {
        Button(action: action) {
            content
        }
        .buttonStyle(.plain)
        .frame(width: 80, height: 80)
        .accessibilityLabel(
            String(
                localized: "agentXray.section.image.a11yLabel",
                defaultValue: "Image",
                bundle: .module
            )
        )
        .task(id: source.data) {
            await decode()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if failed {
            placeholder(
                systemName: "photo.badge.exclamationmark",
                label: String(
                    localized: "agentXray.section.image.failed",
                    defaultValue: "Image (failed to decode)",
                    bundle: .module
                )
            )
        } else {
            placeholder(
                systemName: "photo",
                label: String(
                    localized: "agentXray.section.image.loading",
                    defaultValue: "Loading image…",
                    bundle: .module
                )
            )
        }
    }

    private func placeholder(systemName: String, label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemName)
                .font(.system(size: 22))
            Text(label)
                .font(.system(size: 9))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(width: 80, height: 80)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.1))
        )
    }

    private func decode() async {
        let data = source.data
        let decoded: NSImage? = await Task.detached(priority: .utility) {
            guard let bytes = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else {
                return nil
            }
            return NSImage(data: bytes)
        }.value
        if let decoded {
            image = decoded
        } else {
            failed = true
        }
    }
}
