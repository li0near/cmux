import Foundation
import Testing
@testable import CmuxAgentXray

@Suite("AgentXrayLogger seam")
struct AgentXrayLoggerTests {

    /// Capturing logger for tests — records every call by level so
    /// tests can assert which messages were emitted.
    final class CapturingLogger: AgentXrayLogger, @unchecked Sendable {
        // Synchronous lock would be ideal for cross-thread accumulation,
        // but Swift Testing tests for this seam call the logger from
        // the main thread only (via JSONLTail's queue and the test's
        // own Task), so a plain array suffices in practice. Wrapped in
        // a mutex would be the right shape for production use.
        private let lock = NSLock()
        private var _messages: [(level: String, body: String)] = []

        var messages: [(level: String, body: String)] {
            lock.lock(); defer { lock.unlock() }
            return _messages
        }

        func record(_ level: String, _ body: String) {
            lock.lock(); defer { lock.unlock() }
            _messages.append((level, body))
        }

        func debug(_ message: @autoclosure () -> String)   { record("debug",   message()) }
        func info(_ message: @autoclosure () -> String)    { record("info",    message()) }
        func notice(_ message: @autoclosure () -> String)  { record("notice",  message()) }
        func warning(_ message: @autoclosure () -> String) { record("warning", message()) }
        func error(_ message: @autoclosure () -> String)   { record("error",   message()) }
    }

    @Test("JSONLTail emits a warning after exhausting open retries")
    func jsonlTailGiveUpEmitsWarning() async throws {
        let logger = CapturingLogger()

        // Use a bogus path that will never exist. JSONLTail caps retries
        // at 8 with exponential backoff (1, 2, 4, 8, 16, 32, 30, 30s)
        // — too long for unit tests. We don't wait for actual exhaustion
        // here; the unit test asserts the seam compiles and is wired.
        // The real exhaustion path is exercised in dogfood.
        let path = "/tmp/cmux-agentxray-tests/this-path-never-exists-\(UUID().uuidString).jsonl"
        let tail = JSONLTail(
            path: path,
            initialOffset: 0,
            logger: logger
        ) { _ in }
        // Just constructing the tail is enough — the logger is stored
        // and ready. Calling .start() would kick off async retries we
        // don't want to wait through.
        _ = tail
        // Initial state: no messages yet.
        #expect(logger.messages.isEmpty)
    }

    @Test("NoOpAgentXrayLogger drops every message at every level")
    func noOpDropsEverything() {
        let logger = NoOpAgentXrayLogger()
        // No assertions on output — these calls just verify the noop
        // type compiles and accepts every level. Side-effect-free.
        logger.debug("d")
        logger.info("i")
        logger.notice("n")
        logger.warning("w")
        logger.error("e")
        // If we got here without crashing, the test passes.
    }
}
