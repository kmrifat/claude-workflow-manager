//
//  IssueBranchMatcher.swift
//  workflow-manager
//
//  Which local branch, if any, is the work for issue #N.
//

import Foundation

nonisolated enum IssueBranchMatcher {
    /// Branch naming this recognises, most specific first.
    ///
    /// `issue-<n>` is the convention the dispatcher will create in phase 6, so
    /// it wins. The rest are common enough by hand to be worth matching, but
    /// only when the number is a whole segment — otherwise issue #4 would claim
    /// `issue-42`.
    static func branch(forIssue number: Int, among branches: [String]) -> String? {
        let exact = ["issue-\(number)", "issue/\(number)", "\(number)"]
        if let hit = branches.first(where: { exact.contains($0) }) { return hit }

        return branches.first { branch in
            for prefix in ["issue-\(number)-", "issue/\(number)-", "\(number)-"]
            where branch.hasPrefix(prefix) {
                return true
            }
            // `feature/123-thing` and friends.
            return branch.contains("/\(number)-")
        }
    }
}
