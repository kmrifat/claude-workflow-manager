//
//  AttachmentReferences.swift
//  workflow-manager
//
//  How a card's notes point at its images — see `CardAttachment`. Pure
//  Foundation, apart from the model, so it can be checked on its own.
//

import Foundation

/// Reading and rewriting `![alt](attachment:<uuid>)` in a card's notes. Pure,
/// so it can be checked on its own.
enum AttachmentReferences {
    static let scheme = "attachment"

    private static let pattern = try! NSRegularExpression(
        pattern: "!\\[([^\\]\\n]*)\\]\\(attachment:([0-9A-Fa-f-]{36})\\)"
    )

    static func markdown(alt: String, id: UUID) -> String {
        let clean = alt.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "\n", with: " ")
        return "![\(clean.isEmpty ? "image" : clean)](\(scheme):\(id.uuidString))"
    }

    /// Every attachment the notes refer to, in order, each once.
    static func ids(in markdown: String) -> [UUID] {
        var seen = Set<UUID>()
        return matches(in: markdown).compactMap { match in
            guard let id = UUID(uuidString: match.id), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// The notes with each reference replaced — for somewhere the attachment
    /// cannot follow, such as a GitHub issue body.
    static func replacing(in markdown: String, with replacement: (_ alt: String) -> String) -> String {
        let ns = markdown as NSString
        var result = markdown
        for match in matches(in: markdown).reversed() {
            let range = Range(match.range, in: result)!
            result.replaceSubrange(range, with: replacement(ns.substring(with: match.altRange)))
        }
        return result
    }

    /// The notes with references to `mapping`'s keys repointed to its values —
    /// for a duplicated card, whose copies of the images are new attachments.
    static func repointing(_ markdown: String, _ mapping: [UUID: UUID]) -> String {
        var result = markdown
        for (old, new) in mapping {
            result = result.replacingOccurrences(of: "\(scheme):\(old.uuidString)", with: "\(scheme):\(new.uuidString)")
        }
        return result
    }

    private struct Match {
        var range: NSRange
        var altRange: NSRange
        var id: String
    }

    private static func matches(in markdown: String) -> [Match] {
        let ns = markdown as NSString
        return pattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).map {
            Match(range: $0.range, altRange: $0.range(at: 1), id: ns.substring(with: $0.range(at: 2)).uppercased())
        }
    }
}
