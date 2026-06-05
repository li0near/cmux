import Foundation
import Testing
@testable import CmuxAgentXray

@Suite("RemoteSessionStore — UserDefaults-backed remote session id store")
@MainActor
struct RemoteSessionStoreTests {

    /// Use a unique suite name per test invocation so concurrent runs
    /// don't collide.
    private func makeStore() -> (RemoteSessionStore, UserDefaults) {
        let suite = "test.RemoteSessionStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (RemoteSessionStore(defaults: defaults), defaults)
    }

    // MARK: - Read/write

    @Test("Write then read returns the stored id")
    func writeRead() {
        let (store, _) = makeStore()
        store.write(
            destination: "ubuntu@host",
            cwd: "/home/ubuntu/proj",
            agentKind: .claude,
            sessionID: "SESSION-A"
        )
        #expect(store.read(
            destination: "ubuntu@host",
            cwd: "/home/ubuntu/proj",
            agentKind: .claude
        ) == "SESSION-A")
    }

    @Test("Whitespace is trimmed on write and read")
    func whitespaceTrimmed() {
        let (store, _) = makeStore()
        store.write(
            destination: "ubuntu@host",
            cwd: "/proj",
            agentKind: .claude,
            sessionID: "  SESSION-B  "
        )
        #expect(store.read(
            destination: "ubuntu@host",
            cwd: "/proj",
            agentKind: .claude
        ) == "SESSION-B")
    }

    @Test("Empty string clears the entry")
    func emptyStringClears() {
        let (store, _) = makeStore()
        store.write(
            destination: "ubuntu@host",
            cwd: "/proj",
            agentKind: .claude,
            sessionID: "SESSION-X"
        )
        store.write(
            destination: "ubuntu@host",
            cwd: "/proj",
            agentKind: .claude,
            sessionID: ""
        )
        #expect(store.read(
            destination: "ubuntu@host",
            cwd: "/proj",
            agentKind: .claude
        ) == nil)
    }

    @Test("Nil clears the entry")
    func nilClears() {
        let (store, _) = makeStore()
        store.write(
            destination: "ubuntu@host",
            cwd: "/proj",
            agentKind: .claude,
            sessionID: "SESSION-X"
        )
        store.write(
            destination: "ubuntu@host",
            cwd: "/proj",
            agentKind: .claude,
            sessionID: nil
        )
        #expect(store.read(
            destination: "ubuntu@host",
            cwd: "/proj",
            agentKind: .claude
        ) == nil)
    }

    @Test("Reading an unset entry returns nil")
    func readUnset() {
        let (store, _) = makeStore()
        #expect(store.read(
            destination: "missing@host",
            cwd: "/nope",
            agentKind: .claude
        ) == nil)
    }

    // MARK: - Key shape

    @Test("Same triple → same key")
    func keyStability() {
        let key1 = RemoteSessionStore.key(destination: "u@h", cwd: "/p", agentKind: .claude)
        let key2 = RemoteSessionStore.key(destination: "u@h", cwd: "/p", agentKind: .claude)
        #expect(key1 == key2)
        #expect(key1.hasPrefix("agentXray.remote.session."))
    }

    @Test("Changing destination changes the key")
    func keyChangesWithDestination() {
        let a = RemoteSessionStore.key(destination: "user@a", cwd: "/p", agentKind: .claude)
        let b = RemoteSessionStore.key(destination: "user@b", cwd: "/p", agentKind: .claude)
        #expect(a != b)
    }

    @Test("Changing cwd changes the key")
    func keyChangesWithCwd() {
        let a = RemoteSessionStore.key(destination: "u@h", cwd: "/proj-a", agentKind: .claude)
        let b = RemoteSessionStore.key(destination: "u@h", cwd: "/proj-b", agentKind: .claude)
        #expect(a != b)
    }

    @Test("Changing agentKind changes the key")
    func keyChangesWithAgentKind() {
        let a = RemoteSessionStore.key(destination: "u@h", cwd: "/p", agentKind: .claude)
        let b = RemoteSessionStore.key(destination: "u@h", cwd: "/p", agentKind: .codex)
        #expect(a != b)
    }

    // MARK: - Isolation

    @Test("Different triples don't collide")
    func independentEntries() {
        let (store, _) = makeStore()
        store.write(destination: "u@a", cwd: "/p", agentKind: .claude, sessionID: "A")
        store.write(destination: "u@b", cwd: "/p", agentKind: .claude, sessionID: "B")
        #expect(store.read(destination: "u@a", cwd: "/p", agentKind: .claude) == "A")
        #expect(store.read(destination: "u@b", cwd: "/p", agentKind: .claude) == "B")
    }
}
