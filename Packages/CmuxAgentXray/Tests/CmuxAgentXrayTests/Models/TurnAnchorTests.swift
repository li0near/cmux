import Foundation
import Testing
@testable import CmuxAgentXray

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
