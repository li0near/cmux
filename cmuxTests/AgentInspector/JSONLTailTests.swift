import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies streaming + tail-follow semantics of `JSONLTail`. We exercise the
/// real DispatchSource path against a temp file we mutate during the test.
final class JSONLTailTests: XCTestCase {

    private func makeTempPath() -> String {
        NSTemporaryDirectory() + "jsonl-tail-\(UUID().uuidString).jsonl"
    }

    func testReadsExistingLinesOnStart() {
        let path = makeTempPath()
        try? "line1\nline2\nline3\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let exp = expectation(description: "initial lines")
        var collected: [String] = []
        let tail = JSONLTail(path: path) { lines in
            collected.append(contentsOf: lines)
            if collected.count >= 3 {
                exp.fulfill()
            }
        }
        tail.start()
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(collected, ["line1", "line2", "line3"])
        tail.stop()
    }

    func testTailsAppendedLines() throws {
        let path = makeTempPath()
        try "first\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let appended = expectation(description: "appended")
        var collected: [String] = []
        let collectedLock = NSLock()
        let tail = JSONLTail(path: path) { lines in
            collectedLock.lock()
            collected.append(contentsOf: lines)
            let hasSecond = collected.contains("second")
            collectedLock.unlock()
            if hasSecond {
                appended.fulfill()
            }
        }
        tail.start()
        // Give the tail a beat to read the existing line.
        Thread.sleep(forTimeInterval: 0.5)

        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data("second\n".utf8))
        try fh.close()

        wait(for: [appended], timeout: 5.0)

        collectedLock.lock()
        let snapshot = collected
        collectedLock.unlock()
        XCTAssertTrue(snapshot.contains("first"))
        XCTAssertTrue(snapshot.contains("second"))
        tail.stop()
    }

    func testHandlesPartialLineCarry() throws {
        let path = makeTempPath()
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let collectedExp = expectation(description: "completed")
        var collected: [String] = []
        let lock = NSLock()
        let tail = JSONLTail(path: path) { lines in
            lock.lock()
            collected.append(contentsOf: lines)
            let done = collected.contains("complete-line")
            lock.unlock()
            if done { collectedExp.fulfill() }
        }
        tail.start()
        // Wait for tail to install its watch.
        Thread.sleep(forTimeInterval: 0.3)

        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        // Write a partial line — should not be emitted yet.
        try fh.write(contentsOf: Data("complete-".utf8))
        Thread.sleep(forTimeInterval: 0.2)
        lock.lock()
        XCTAssertFalse(collected.contains("complete-line"))
        lock.unlock()
        // Finish the line.
        try fh.write(contentsOf: Data("line\n".utf8))
        try fh.close()

        wait(for: [collectedExp], timeout: 5.0)
        lock.lock()
        XCTAssertTrue(collected.contains("complete-line"))
        lock.unlock()
        tail.stop()
    }
}
