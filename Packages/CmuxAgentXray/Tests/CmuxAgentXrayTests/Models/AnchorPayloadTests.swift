import Foundation
import Testing
@testable import CmuxAgentXray

@Suite("Anchor payloads + notification helper")
struct AnchorPayloadTests {

    @Test("Notification helper round-trips ClaudeAnchorPayload")
    func notificationRoundTrip() {
        let payload = ClaudeAnchorPayload(
            sessionID: "sess-1",
            surfaceID: UUID(),
            transcriptPath: "/tmp/t.jsonl",
            transcriptBytes: 1024,
            terminalRowAtSubmit: 5,
            totalAtCapture: 100,
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let n = Notification(
            name: .cmuxClaudePromptSubmitted,
            object: nil,
            userInfo: [Notification.claudeAnchorPayloadKey: payload]
        )
        #expect(n.claudeAnchorPayload == payload)
    }

    @Test("Notification with no userInfo returns nil payload")
    func emptyUserInfo() {
        let n = Notification(name: .cmuxClaudePromptSubmitted)
        #expect(n.claudeAnchorPayload == nil)
    }

    @Test("Socket payload Codable round-trip")
    func socketPayloadCodable() throws {
        let payload = ClaudeAnchorSocketPayload(
            sessionID: "sess-1",
            surfaceID: UUID(),
            turnID: "t-1",
            transcriptPath: "/tmp/t.jsonl",
            transcriptBytes: 1024,
            submittedPromptText: "hello"
        )
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ClaudeAnchorSocketPayload.self, from: encoded)
        #expect(decoded == payload)

        let asJSON = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        // Confirm wire format uses snake_case keys, not Swift property names.
        #expect(asJSON?["session_id"] as? String == "sess-1")
        #expect(asJSON?["transcript_path"] as? String == "/tmp/t.jsonl")
        #expect(asJSON?["prompt"] as? String == "hello")
    }
}
