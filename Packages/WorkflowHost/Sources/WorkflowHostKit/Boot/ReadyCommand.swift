import Foundation
import WorkflowCore

/// Prints each repo's Ready column.
///
/// **Reads only from the cache.** It never calls GitHub — if the cache is cold it
/// says so and tells you to run the poller. That distinction is the phase 1
/// checkpoint: the board on screen has to be the one the poller wrote.
public enum ReadyCommand {
    public static func render(config: HostConfig, cache: CacheStore, now: Date = Date()) throws -> String {
        var lines: [String] = []

        for repo in config.repos {
            guard let entry = try cache.read(CacheStore.Key.project(repo), as: ProjectSnapshot.self) else {
                lines.append("\(repo.id)")
                lines.append("  no cached board — run `WorkflowHost poll --once` first")
                lines.append("")
                continue
            }

            let board = entry.value
            let ready = board.items(inColumn: repo.readyColumn)
            let age = now.timeIntervalSince(entry.fetchedAt)

            lines.append("\(repo.id)  —  \(board.title) #\(board.number), cached \(Self.describe(age)) ago")

            if let field = board.statusField, field.option(named: repo.readyColumn) == nil {
                // A config typo would otherwise look exactly like an empty column.
                lines.append("  no column named \"\(repo.readyColumn)\" — board has: "
                    + field.options.map(\.name).joined(separator: ", "))
            } else if ready.isEmpty {
                lines.append("  \(repo.readyColumn) is empty")
            } else {
                lines.append("  \(repo.readyColumn) (\(ready.count))")
                for item in ready {
                    guard let content = item.content else {
                        lines.append("    (draft card)")
                        continue
                    }
                    let claim = content.assignees.isEmpty
                        ? ""
                        : "  [claimed by \(content.assignees.joined(separator: ", "))]"
                    lines.append("    #\(content.number)  \(content.title)\(claim)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    static func describe(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}
