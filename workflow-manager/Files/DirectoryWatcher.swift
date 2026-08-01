//
//  DirectoryWatcher.swift
//  workflow-manager
//
//  Watches a *changing set* of directories and says which one changed.
//
//  `WorkflowFileWatcher` watches one known directory forever. This watches
//  whichever folders the user currently has open in the Files view, which come
//  and go as they expand and collapse — so the interesting part is reconciling
//  the set, not the watch itself.
//
//  The same rule applies as there, for the same reason: **watch the directory,
//  never a file descriptor for the file.** Editors, formatters and `git
//  checkout` all write a temporary file and `rename()` it into place, which
//  unlinks the inode a per-file watch is holding. That watch reports `.delete`
//  once and is deaf from then on. A rename *into* a directory is a write to the
//  directory, and a directory's inode survives being written to.
//
//  All mutable state lives on one serial queue, which is what makes the
//  `@unchecked Sendable` honest.
//

import Foundation

nonisolated final class DirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.binarycastle.workflow-manager.files-watcher")
    private let debounce: TimeInterval

    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var pending: [URL: DispatchWorkItem] = [:]
    private var order: [URL] = []

    /// One file descriptor per watched directory. A user cannot open hundreds of
    /// folders on purpose, but a deep tree plus an itchy trigger finger can get
    /// closer than you would think, and running a GUI app out of descriptors
    /// breaks things far away from here. Oldest watch is dropped past the cap;
    /// that folder simply stops live-updating, which is what it did before this
    /// file existed.
    private static let maxWatched = 96

    /// Directories that changed, debounced per directory. Finishes on `stop()`.
    let changes: AsyncStream<URL>
    private let continuation: AsyncStream<URL>.Continuation

    init(debounce: TimeInterval = 0.25) {
        self.debounce = debounce
        (changes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    deinit { stop() }

    /// Makes the watched set exactly `directories`. Safe to call on every
    /// expansion — existing watches are kept, not torn down and rebuilt.
    func setWatched(_ directories: Set<URL>) {
        queue.async { [self] in
            for (url, source) in sources where !directories.contains(url) {
                source.cancel()
                sources[url] = nil
                pending[url]?.cancel()
                pending[url] = nil
                order.removeAll { $0 == url }
            }
            for url in directories where sources[url] == nil {
                arm(url)
            }
        }
    }

    func stop() {
        queue.sync {
            for source in sources.values { source.cancel() }
            sources.removeAll()
            for item in pending.values { item.cancel() }
            pending.removeAll()
            order.removeAll()
        }
        continuation.finish()
    }

    // MARK: - Private, all on `queue`

    private func arm(_ url: URL) {
        let descriptor = open(url.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            // The directory itself was replaced — a branch checkout does this.
            // The descriptor now points at something unreachable, so re-arm by
            // path rather than trusting it.
            if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                self.disarm(url)
                self.queue.asyncAfter(deadline: .now() + self.debounce) { [weak self] in
                    guard let self, self.order.contains(url) == false else { return }
                    self.arm(url)
                }
            }
            self.schedule(url)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()

        sources[url] = source
        order.append(url)

        while order.count > Self.maxWatched, let oldest = order.first {
            sources[oldest]?.cancel()
            sources[oldest] = nil
            order.removeFirst()
        }
    }

    private func disarm(_ url: URL) {
        sources[url]?.cancel()
        sources[url] = nil
        order.removeAll { $0 == url }
    }

    /// Coalesced per directory. Saving a file in an editor is several writes in
    /// quick succession, and re-listing a folder once per write is wasted work
    /// the user sees as a flicker.
    private func schedule(_ url: URL) {
        pending[url]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending[url] = nil
            self.continuation.yield(url)
        }
        pending[url] = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
