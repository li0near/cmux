import XCTest
import CmuxAgentXray

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class RemoteHomeResolverTests: XCTestCase {

    private let testTransport = SSHTransport(
        destination: "ubuntu@example.com",
        port: 22,
        identityFile: nil,
        controlPath: "/tmp/cmux-ssh-501-%C"
    )

    private func makeIsolatedDefaults(name: String = #function) -> UserDefaults {
        let suite = "test.RemoteHomeResolver.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testCacheHitReturnsImmediately() async throws {
        let defaults = makeIsolatedDefaults()
        var spawnCount = 0
        let resolver = RemoteHomeResolver(
            defaults: defaults,
            timeout: .seconds(1),
            runner: { _ in
                spawnCount += 1
                return "/home/ubuntu\n"
            }
        )

        // First call spawns once.
        let first = try await resolver.resolve(for: testTransport)
        XCTAssertEqual(first, "/home/ubuntu")
        XCTAssertEqual(spawnCount, 1)

        // Second call hits the cache; spawn count unchanged.
        let second = try await resolver.resolve(for: testTransport)
        XCTAssertEqual(second, "/home/ubuntu")
        XCTAssertEqual(spawnCount, 1)
    }

    func testCachedReturnsNilBeforeResolve() {
        let defaults = makeIsolatedDefaults()
        let resolver = RemoteHomeResolver(
            defaults: defaults,
            timeout: .seconds(1),
            runner: { _ in "/home/ubuntu" }
        )
        XCTAssertNil(resolver.cached(for: testTransport))
    }

    func testCachePersistsAcrossInstances() async throws {
        let defaults = makeIsolatedDefaults()
        let first = RemoteHomeResolver(
            defaults: defaults,
            timeout: .seconds(1),
            runner: { _ in "/home/ubuntu\n" }
        )
        _ = try await first.resolve(for: testTransport)

        // New resolver instance backed by the same defaults — the
        // cached value survives.
        let second = RemoteHomeResolver(
            defaults: defaults,
            timeout: .seconds(1),
            runner: { _ in
                XCTFail("Should not spawn — cache should hit")
                return ""
            }
        )
        XCTAssertEqual(second.cached(for: testTransport), "/home/ubuntu")
        let resolved = try await second.resolve(for: testTransport)
        XCTAssertEqual(resolved, "/home/ubuntu")
    }

    func testTrailingSlashStripped() async throws {
        let defaults = makeIsolatedDefaults()
        let resolver = RemoteHomeResolver(
            defaults: defaults,
            timeout: .seconds(1),
            runner: { _ in "/home/ubuntu/\n" }
        )
        let resolved = try await resolver.resolve(for: testTransport)
        XCTAssertEqual(resolved, "/home/ubuntu")
    }

    func testEmptyStdoutThrowsEmptyHome() async {
        let defaults = makeIsolatedDefaults()
        let resolver = RemoteHomeResolver(
            defaults: defaults,
            timeout: .seconds(1),
            runner: { _ in "   \n" }
        )
        do {
            _ = try await resolver.resolve(for: testTransport)
            XCTFail("Expected emptyHome error")
        } catch RemoteHomeResolver.ResolveError.emptyHome {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunnerErrorPropagates() async {
        let defaults = makeIsolatedDefaults()
        struct TestError: Error {}
        let resolver = RemoteHomeResolver(
            defaults: defaults,
            timeout: .seconds(1),
            runner: { _ in throw TestError() }
        )
        do {
            _ = try await resolver.resolve(for: testTransport)
            XCTFail("Expected error")
        } catch is TestError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidateClearsCache() async throws {
        let defaults = makeIsolatedDefaults()
        let resolver = RemoteHomeResolver(
            defaults: defaults,
            timeout: .seconds(1),
            runner: { _ in "/home/ubuntu" }
        )
        _ = try await resolver.resolve(for: testTransport)
        XCTAssertEqual(resolver.cached(for: testTransport), "/home/ubuntu")
        resolver.invalidate(for: testTransport)
        XCTAssertNil(resolver.cached(for: testTransport))
    }

    // MARK: - Cache key shape

    func testCacheKeyDistinguishesEndpoints() {
        let a = RemoteHomeResolver.cacheKey(for: SSHTransport(
            destination: "user@a", port: nil, identityFile: nil, controlPath: nil
        ))
        let b = RemoteHomeResolver.cacheKey(for: SSHTransport(
            destination: "user@b", port: nil, identityFile: nil, controlPath: nil
        ))
        XCTAssertNotEqual(a, b)
    }

    func testSSHArgsIncludeControlMasterNoWhenControlPathPresent() {
        let args = RemoteHomeResolver.sshArgs(for: SSHTransport(
            destination: "user@host",
            port: 2222,
            identityFile: "/id",
            controlPath: "/tmp/cp-%C"
        ))
        // Verify ControlPath + ControlMaster=no both pass to ssh so
        // the resolver rides cmux's existing master connection.
        XCTAssertTrue(args.contains("ControlPath=/tmp/cp-%C"))
        XCTAssertTrue(args.contains("ControlMaster=no"))
        // Verify final positional args: destination then `echo $HOME`.
        XCTAssertEqual(args.last, "echo $HOME")
        XCTAssertTrue(args.contains("user@host"))
    }
}
