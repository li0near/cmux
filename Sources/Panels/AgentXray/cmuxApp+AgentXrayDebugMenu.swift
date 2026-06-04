import Foundation

#if DEBUG
/// Empty placeholder file. Phase 9 originally introduced an
/// `AgentXrayDebugMenu` enum here but moved the click handler inline
/// into `cmuxApp.swift`'s Debug menu Button closure (where the
/// SwiftUI-injected `appDelegate` and `activeTabManager` are
/// directly accessible). Kept as a compilation hook in case future
/// debug surfaces want a parking spot.
@MainActor
enum AgentXrayDebugMenu {
    static let placeholder: Void = ()
}
#endif
