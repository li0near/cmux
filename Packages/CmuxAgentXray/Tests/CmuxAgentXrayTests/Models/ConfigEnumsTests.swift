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
