public import SwiftUI

/// Inline prompt rendered from ``TranscriptView``'s empty-state branch
/// when the focused terminal is on an SSH transport but no claude
/// session has been resolved yet (resolver path 3 input is missing).
///
/// Layout matches the existing empty-state typography:
///
///     Set Claude session id
///     Attaching to <destination>. Run `claude --resume <id>` on the
///     remote and paste the id below.
///     [Claude session id            ] [Attach]
///
/// Submitting calls ``AgentXrayPanel/setRemoteClaudeSessionID(_:)``
/// which forwards to the host. The host runs `ssh exec echo $HOME` if
/// the remote home isn't cached yet (~1 round-trip), writes the
/// id, then triggers a focus recompute that lets resolver path 3 fire.
@available(macOS 15, *)
public struct RemoteAttachPromptView: View {

    @Bindable public var panel: AgentXrayPanel
    public let palette: HudPalette
    public let destination: String?

    @State private var draftSessionID: String = ""
    @FocusState private var inputFocused: Bool

    public init(
        panel: AgentXrayPanel,
        palette: HudPalette,
        destination: String?
    ) {
        self.panel = panel
        self.palette = palette
        self.destination = destination
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headerText)
                .font(Theme.Row.name)
                .foregroundStyle(palette.primary)
            Text(detailText)
                .font(Theme.Row.summary)
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField(placeholderText, text: $draftSessionID)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Row.summary)
                    .focused($inputFocused)
                    .disabled(panel.remoteAttachInFlight)
                    .onSubmit { submit() }

                Button(action: submit) {
                    if panel.remoteAttachInFlight {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(connectingText)
                        }
                    } else {
                        Text(submitText)
                    }
                }
                .disabled(submitDisabled)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { inputFocused = true }
    }

    // MARK: - Actions

    private var trimmedDraft: String {
        draftSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var submitDisabled: Bool {
        panel.remoteAttachInFlight || trimmedDraft.isEmpty
    }

    private func submit() {
        guard !submitDisabled else { return }
        panel.setRemoteClaudeSessionID(trimmedDraft)
    }

    // MARK: - Strings

    private var headerText: String {
        String(
            localized: "agentXray.remote.prompt.header",
            defaultValue: "Set Claude session id",
            bundle: .module
        )
    }

    private var detailText: String {
        if let destination, !destination.isEmpty {
            return String(
                localized: "agentXray.remote.prompt.detail.withDestination",
                defaultValue: "Attaching to \(destination). Run `claude --resume <id>` on the remote and paste the id below.",
                bundle: .module
            )
        }
        return String(
            localized: "agentXray.remote.prompt.detail",
            defaultValue: "Run `claude --resume <id>` on the remote and paste the id below.",
            bundle: .module
        )
    }

    private var placeholderText: String {
        String(
            localized: "agentXray.remote.prompt.input.placeholder",
            defaultValue: "Claude session id",
            bundle: .module
        )
    }

    private var submitText: String {
        String(
            localized: "agentXray.remote.prompt.button.submit",
            defaultValue: "Attach",
            bundle: .module
        )
    }

    private var connectingText: String {
        String(
            localized: "agentXray.remote.prompt.button.connecting",
            defaultValue: "Connecting…",
            bundle: .module
        )
    }
}
