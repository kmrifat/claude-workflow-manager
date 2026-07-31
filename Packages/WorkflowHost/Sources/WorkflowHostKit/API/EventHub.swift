import Foundation

/// Fan-out for "something changed".
///
/// An actor because it owns real mutable state — the set of live subscribers —
/// that nothing else serializes. It only ever broadcasts; it never calls back
/// into the poller or the dispatcher, which keeps the actor graph acyclic
/// (see the concurrency rule in CLAUDE.md).
public actor EventHub {
    public enum Signal: String, Sendable {
        /// State changed; re-fetch `/api/state`. The payload is deliberately not
        /// pushed — the page asks for what it needs.
        case stateChanged
    }

    private var continuations: [UUID: AsyncStream<Signal>.Continuation] = [:]

    public init() {}

    public var subscriberCount: Int { continuations.count }

    /// A stream that ends when the caller stops iterating.
    public func subscribe() -> AsyncStream<Signal> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(id) }
            }
        }
    }

    private func unsubscribe(_ id: UUID) {
        continuations[id] = nil
    }

    public func broadcast(_ signal: Signal = .stateChanged) {
        for continuation in continuations.values {
            continuation.yield(signal)
        }
    }

    /// Ends every stream — used when the host shuts down, so sockets close
    /// rather than hanging.
    public func closeAll() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }
}
