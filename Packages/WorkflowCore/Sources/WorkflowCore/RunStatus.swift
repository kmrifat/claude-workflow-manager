/// The lifecycle of a single dispatched run — the vocabulary of the
/// `runs.status` column, and later of both clients.
///
/// A run only ever moves forward: `queued` → `running` → `review` → `done`, with
/// `failed` reachable from any of them. Nothing merges a PR, so `done` means the
/// PR was merged by a human, not by us.
public enum RunStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case review
    case done
    case failed
}
