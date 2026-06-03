import Foundation

/// Stream-by-line reader for JSONL files with vnode-watched
/// tail-follow.
///
/// All work happens on the dedicated `queue` — never the main actor —
/// because Claude Code transcripts can grow into the megabytes during
/// a long session.
///
/// `@unchecked Sendable` — mutable state (offset, carry, watchSource,
/// watchedFD, debouncing flag, openRetryAttempts) is queue-isolated.
public final class JSONLTail: @unchecked Sendable {

    public typealias LinesHandler = @Sendable ([String]) -> Void

    private let path: String
    private let queue = DispatchQueue(
        label: "com.cmux.agentXray.jsonlTail",
        qos: .utility
    )

    private nonisolated(unsafe) var watchSource: (any DispatchSourceFileSystemObject)?
    private nonisolated(unsafe) var watchedFD: Int32 = -1
    private nonisolated(unsafe) var offset: UInt64 = 0
    /// Holds a partial last line if the file ended without a newline.
    private nonisolated(unsafe) var carry: String = ""
    private nonisolated(unsafe) var debouncing = false
    /// Counts consecutive open() failures. Exponential-backoff retries
    /// cap at `maxOpenRetries` to avoid an infinite asyncAfter chain
    /// when the transcript file never appears (deleted session, wrong
    /// path, etc.).
    private nonisolated(unsafe) var openRetryAttempts: Int = 0
    private static let maxOpenRetries: Int = 8

    private let onLines: LinesHandler

    public init(path: String, initialOffset: UInt64 = 0, onLines: @escaping LinesHandler) {
        self.path = path
        self.offset = initialOffset
        self.onLines = onLines
    }

    deinit {
        // Cancel synchronously here — by definition no other code can
        // hold a strong reference to self once deinit runs.
        watchSource?.cancel()
        watchSource = nil
        watchedFD = -1
    }

    /// Start tailing. Existing content is read first, in chunks, then
    /// the vnode watch picks up appends.
    public func start() {
        queue.async { [weak self] in
            self?.openAndDrainInitial()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.watchSource?.cancel()
            self.watchSource = nil
            self.watchedFD = -1
        }
    }

    // MARK: - Internals

    private func openAndDrainInitial() {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            // Exponential backoff: 1, 2, 4, 8, 16, 32, 30, 30 s ≈ ~2 min total.
            openRetryAttempts += 1
            guard openRetryAttempts <= Self.maxOpenRetries else {
                debugLog("jsonlTail: gave up opening \(path) after \(openRetryAttempts) attempts")
                return
            }
            let delaySeconds = min(30, 1 << min(openRetryAttempts - 1, 5))
            queue.asyncAfter(deadline: .now() + .seconds(delaySeconds)) { [weak self] in
                guard let self, self.watchedFD < 0 else { return }
                self.openAndDrainInitial()
            }
            return
        }
        openRetryAttempts = 0
        watchedFD = fd
        carry = ""
        drainAppendedBytes()
        installVnodeWatch(fd: fd)
    }

    private func installVnodeWatch(fd: Int32) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let data = source.data
            if data.contains(.delete) || data.contains(.rename) {
                self.tearDownAndReopen()
                return
            }
            self.scheduleDebouncedDrain()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        watchSource = source
        source.resume()
    }

    private func tearDownAndReopen() {
        watchSource?.cancel()
        watchSource = nil
        watchedFD = -1
        queue.async { [weak self] in
            self?.openAndDrainInitial()
        }
    }

    private func scheduleDebouncedDrain() {
        if debouncing { return }
        debouncing = true
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }
            self.debouncing = false
            self.drainAppendedBytes()
        }
    }

    private func drainAppendedBytes() {
        let fd = watchedFD
        guard fd >= 0 else { return }

        let seeked = lseek(fd, off_t(offset), SEEK_SET)
        guard seeked >= 0 else {
            tearDownAndReopen()
            return
        }

        var emitted: [String] = []
        var buffer = Data()
        let chunkSize = 64 * 1024
        var temp = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = temp.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return read(fd, base, ptr.count)
            }
            if n == 0 { break }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                tearDownAndReopen()
                return
            }
            buffer.append(temp, count: n)
            offset = offset &+ UInt64(n)
        }

        guard !buffer.isEmpty else {
            if !emitted.isEmpty { onLines(emitted) }
            return
        }

        guard let chunkText = String(data: buffer, encoding: .utf8) else {
            return
        }

        var working = carry + chunkText
        carry = ""
        while let nlIdx = working.firstIndex(of: "\n") {
            let line = String(working[..<nlIdx])
            working = String(working[working.index(after: nlIdx)...])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                emitted.append(trimmed)
            }
        }
        carry = working

        if !emitted.isEmpty {
            onLines(emitted)
        }
    }
}
