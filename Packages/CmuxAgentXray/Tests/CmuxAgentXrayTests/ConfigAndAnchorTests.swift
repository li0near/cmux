import Foundation
import Testing
@testable import CmuxAgentXray

@Suite("Behavioral config enums")
struct ConfigEnumsTests {

    @Test("ScrollMode label readable")
    func scrollMode() {
        #expect(ScrollMode.free.label == "free")
        #expect(ScrollMode.snap.label == "snap")
    }

    @Test("ExpansionMode cycles allCollapsed → autoExpand → allCollapsed")
    func expansionCycle() {
        #expect(ExpansionMode.allCollapsed.cycled() == .autoExpand)
        #expect(ExpansionMode.autoExpand.cycled() == .allCollapsed)
    }

    @Test("RewindVisibility cycles link → hide → link")
    func rewindCycle() {
        #expect(RewindVisibility.link.cycled() == .hide)
        #expect(RewindVisibility.hide.cycled() == .link)
    }
}

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

@Suite("TurnAnchor")
struct TurnAnchorTests {

    @Test("Identifiable id matches userEntryID")
    func identifiable() {
        let anchor = TurnAnchor(
            userEntryID: "u-1",
            terminalRowAtSubmit: 10,
            totalAtCapture: 100,
            capturedAt: Date()
        )
        #expect(anchor.id == "u-1")
    }

    @Test("agentEntryID is mutable")
    func mutableAgentEntryID() {
        var anchor = TurnAnchor(
            userEntryID: "u-1",
            terminalRowAtSubmit: 10,
            totalAtCapture: 100,
            capturedAt: Date()
        )
        #expect(anchor.agentEntryID == nil)
        anchor.agentEntryID = "a-1"
        #expect(anchor.agentEntryID == "a-1")
    }
}
