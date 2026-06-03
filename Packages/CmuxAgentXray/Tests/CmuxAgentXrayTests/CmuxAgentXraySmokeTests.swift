import Testing
@testable import CmuxAgentXray

@Suite("CmuxAgentXray module smoke")
struct CmuxAgentXraySmokeTests {

    @available(macOS 15, *)
    @Test("module marker is exposed")
    func moduleMarker() {
        #expect(CmuxAgentXray.moduleName == "CmuxAgentXray")
    }
}
