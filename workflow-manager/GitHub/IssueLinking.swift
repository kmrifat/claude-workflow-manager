//
//  IssueLinking.swift
//  workflow-manager
//
//  The join between a GitHub issue and a card on the board.
//
//  Linking is always explicit and always local: nothing here calls GitHub. A
//  card can point at an issue, and the boards show that on both sides, but the
//  app never assigns, closes or comments on anything.
//

import Foundation
import SwiftData

@MainActor
enum IssueLinking {

    /// Creates a card from an issue, at the end of `column`.
    ///
    /// Body becomes `details` and labels become tags, so the card is useful
    /// offline. `sortOrder` and completion state stay with `BoardMutations`,
    /// which owns every ordering invariant.
    @discardableResult
    static func createWorkItem(
        from issue: GitHubIssue,
        in column: BoardColumn,
        context: ModelContext
    ) -> WorkItem {
        let item = WorkItem(
            title: issue.title,
            details: issue.body,
            owner: issue.assignees.first?.login ?? "",
            tags: issue.labels.map(\.name),
            githubIssueNumber: issue.number,
            githubRepoSlug: column.project?.repoSlug
        )
        context.insert(item)
        BoardMutations.append(item, to: column)
        return item
    }

    static func link(_ item: WorkItem, to issue: GitHubIssue) {
        link(item, toIssueNumber: issue.number, slug: item.project?.repoSlug)
    }

    static func link(_ item: WorkItem, toIssueNumber number: Int, slug: String?) {
        item.githubIssueNumber = number
        item.githubRepoSlug = slug
    }

    static func unlink(_ item: WorkItem) {
        item.githubIssueNumber = nil
        item.githubRepoSlug = nil
    }

    /// The card tracking `number`, if any. Two cards claiming one issue is
    /// allowed by the schema but discouraged by the UI, so this returns the
    /// first and callers offer "reveal" rather than creating a second.
    static func linkedItem(forIssue number: Int, in project: Project) -> WorkItem? {
        project.allItems.first {
            $0.githubIssueNumber == number && $0.githubRepoSlug == project.repoSlug
        }
    }

    /// Every issue number the board already tracks.
    ///
    /// One scan per board render — never call this per card.
    static func linkedNumbers(in project: Project) -> Set<Int> {
        var numbers: Set<Int> = []
        for item in project.allItems where item.githubRepoSlug == project.repoSlug {
            if let number = item.githubIssueNumber { numbers.insert(number) }
        }
        return numbers
    }
}
