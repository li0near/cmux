import Foundation

/// Stream-by-line reader for JSONL files with vnode-watched tail-follow.
///
/// Pattern mirrors `MarkdownPanel`'s file watch (Sources/Panels/MarkdownPanel.swift:56-70):
/// a `DispatchSource` on the file's vnode reports writes/deletes/renames,
/// debounced. We track byte offset across notifications so each fire only
/// emits the lines that were appended since the last drain.
///
/// All work happens on the dedicated `queue` — never the main actor —
/// because Claude Code transcripts can grow into the megabytes during a
/// long session.
public final class JSONLTail {

    public typealias LinesHandler = @Sendable ([String]) -> Void

    private let path: String
    private let queue = DispatchQueue(label: "com.cmux.agentInspector.jsonlTail", qos: .utility)

    private nonisolated(unsafe) var watchSource: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var watchedFD: Int32 = -1
    private nonisolated(unsafe) var offset: UInt64 = 0
    /// Holds a partial last line if the file ended without a newline.
    private nonisolated(unsafe) var carry: String = ""
    private nonisolated(unsafe) var debouncing = false

    private let onLines: LinesHandler

    public init(path: String, initialOffset: UInt64 = 0, onLines: @escaping LinesHandler) {
        self.path = path
        self.offset = initialOffset
        self.onLines = onLines
    }

    deinit {
        stop()
    }

    /// Start tailing. Existing content is read first, in chunks, then the
    /// vnode watch picks up appends.
    public func start() {
        queue.async { [weak self] in
            self?.openAndDrainInitial()
        }
    }

    public func stop() {
        watchSource?.cancel()
        watchSource = nil
        watchedFD = -1
    }

    // MARK: - Internals

    private func openAndDrainInitial() {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            // File doesn't exist yet — wait briefly and retry. Sessions can
            // be hooked before Claude Code actually creates the JSONL.
            queue.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
                guard let self, self.watchedFD < 0 else { return }
                self.openAndDrainInitial()
            }
            return
        }
        watchedFD = fd
        // `offset` is preserved from init — when the caller has already
        // ingested the file's existing content synchronously, they pass
        // initialOffset = fileSize so we only emit subsequent appends.
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
            // Rotation/replace → re-open the new inode.
            if data.contains(.delete) || data.contains(.rename) {
                self.stop()
                self.openAndDrainInitial()
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

        // Seek to the previously-known offset.
        let seeked = lseek(fd, off_t(offset), SEEK_SET)
        guard seeked >= 0 else {
            // Likely truncated; re-open from scratch.
            stop()
            openAndDrainInitial()
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
                // EAGAIN on non-blocking FDs is normal; bail out and resume on
                // next vnode notification.
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                stop()
                openAndDrainInitial()
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
            // Bad UTF-8 — drop the chunk to avoid stalling. JSON lines are
            // strictly ASCII for keys; embedded user text might have invalid
            // bytes if the file is mid-write.
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
