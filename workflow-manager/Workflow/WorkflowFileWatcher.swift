//
//  WorkflowFileWatcher.swift
//  workflow-manager
//
//  Watches `.taskboard/tasks.json` and publishes its contents when it changes.
//
//  ## Why the directory, not the file
//
//  Claude, `Data.write(options: .atomic)` and every text editor write a
//  temporary file and `rename()` it into place. That unlinks the inode a
//  per-file descriptor points at, so a file watch reports `.delete` once and is
//  then deaf forever — it is holding a descriptor for a file nobody can reach.
//
//  A rename *into* a directory is a write to the directory, and the directory's
//  inode survives arbitrarily many replacements. So the watch is on `.workflow`,
//  and the read is by path.
//
//  `FSEventStreamCreate` also solves this, but it needs a run loop to schedule
//  on, coalesces on its own latency parameter that then has to be reasoned about
//  on top of ours, and reports path flags that have to be interpreted. A
//  dispatch source needs none of that.
//
//  All mutable state lives on one serial queue, which is what makes the
//  `@unchecked Sendable` here honest rather than a promise.
//

import Foundation
import CryptoKit

nonisolated final class WorkflowFileWatcher: @unchecked Sendable {
    private let directory: URL
    private let fileURL: URL
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "com.binarycastle.workflow-manager.file-watcher")

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pending: DispatchWorkItem?
    private var pollTimer: DispatchSourceTimer?
    private var lastSignature: FileSignature?

    /// Hashes of bytes this app wrote. A change whose contents match one is our
    /// own echo and is dropped.
    private var suppressedHashes: Set<String> = []

    /// Debounced file contents. Finishes when the watcher is cancelled.
    ///
    /// Built in `init` rather than lazily: a `lazy var` here would be a mutable
    /// stored property published across queues, which is both a data race and
    /// an error under the Swift 6 language mode.
    let changes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    /// The whole directory can vanish and reappear — a branch checkout does
    /// exactly that — taking the descriptor with it. Re-arming from a cheap poll
    /// costs nothing and makes the watch survive it.
    private static let pollInterval: DispatchTimeInterval = .seconds(10)

    private struct FileSignature: Equatable {
        let modified: Date
        let size: Int
    }

    init(
        directory: URL,
        filename: String = WorkflowTasksFile.filename,
        debounce: TimeInterval = 0.25
    ) {
        self.directory = directory
        self.fileURL = directory.appending(path: filename)
        self.debounce = debounce

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.changes = stream
        self.continuation = continuation
    }

    deinit {
        pollTimer?.cancel()
        source?.cancel()
        continuation.finish()
    }

    func start() {
        queue.async { [weak self] in
            self?.arm()
            self?.startPolling()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            self.pending = nil
            self.pollTimer?.cancel()
            self.pollTimer = nil
            self.source?.cancel()
            self.source = nil
            self.continuation.finish()
        }
    }

    /// Records bytes the app just wrote so the resulting change is ignored.
    ///
    /// Keyed by content hash rather than a time window: a hash cannot be fooled
    /// by clock skew, or by a slow write that lands after a window would have
    /// closed. This is why the encoder uses `.sortedKeys` — a stable byte order
    /// is what makes the hash stable.
    func suppressEcho(of data: Data) {
        let digest = Self.hash(data)
        queue.async { [weak self] in
            guard let self else { return }
            self.suppressedHashes.insert(digest)
            // Bounded: only the last few writes can still be in flight.
            if self.suppressedHashes.count > 8 {
                self.suppressedHashes.removeFirst()
            }
            self.lastSignature = self.signature()
        }
    }

    // MARK: - Watching

    private func arm() {
        guard source == nil else { return }
        let path = directory.path(percentEncoded: false)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                // The directory itself moved out from under us.
                self.rearm()
            }
            self.scheduleRead()
        }
        source.setCancelHandler { close(fd) }

        self.descriptor = fd
        self.source = source
        source.resume()
    }

    private func rearm() {
        source?.cancel()
        source = nil
        descriptor = -1
        // Give the replacement a moment to land before reopening.
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.arm()
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.source == nil { self.arm() }
            let current = self.signature()
            if current != self.lastSignature { self.scheduleRead() }
        }
        pollTimer = timer
        timer.resume()
    }

    /// An atomic rename is one event, but write-then-chmod-then-rename is
    /// three, and an agent may write several times in a burst.
    private func scheduleRead() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.emit() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func emit() {
        lastSignature = signature()
        guard let data = try? Data(contentsOf: fileURL) else { return }

        let digest = Self.hash(data)
        if suppressedHashes.contains(digest) {
            suppressedHashes.remove(digest)
            return
        }
        continuation.yield(data)
    }

    private func signature() -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: fileURL.path(percentEncoded: false)
        ) else { return nil }
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let size = attributes[.size] as? Int ?? 0
        return FileSignature(modified: modified, size: size)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
