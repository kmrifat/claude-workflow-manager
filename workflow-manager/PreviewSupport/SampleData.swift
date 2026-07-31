//
//  SampleData.swift
//  workflow-manager
//
//  The whole file is DEBUG-only: this folder is part of the target's
//  file-system-synchronized group, so it would otherwise be compiled into
//  Release builds too.
//

#if DEBUG
import Foundation
import SwiftData

@MainActor
enum SampleData {
    /// Held strongly — a container created inline inside `#Preview` can be
    /// deallocated mid-preview, taking the seeded objects with it.
    static let container: ModelContainer = {
        let container = AppModelContainer.make(inMemory: true)
        seed(into: container.mainContext)
        return container
    }()

    static func project(named name: String) -> Project? {
        let descriptor = FetchDescriptor<Project>()
        return try? container.mainContext.fetch(descriptor).first { $0.name == name }
    }

    static var firstProject: Project? {
        var descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.sortOrder)])
        descriptor.fetchLimit = 1
        return try? container.mainContext.fetch(descriptor).first
    }

    static func seed(into context: ModelContext) {
        let calendar = Calendar.current
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: .now) ?? .now
        }

        // 1 — on track
        let launch = Project(
            name: "Mobile App Launch",
            summary: "Ship v1 of the companion iOS app",
            goal: "10k installs in the first month with a 4.5★ average rating",
            plan: """
            Phase 1 — finish onboarding and sync.
            Phase 2 — closed beta with 50 testers, fix the top crashers.
            Phase 3 — App Store submission, marketing site, launch post.
            """,
            startDate: day(-40),
            targetEndDate: day(24),
            status: .active,
            accent: .blue,
            symbolName: "iphone",
            sortOrder: 1024
        )
        context.insert(launch)
        BoardMutations.makeDefaultColumns(for: launch, in: context)
        seedItems(
            into: launch,
            context: context,
            perColumn: [
                ["Localise onboarding copy", "Dark mode audit"],
                ["Push notification permissions", "Offline queue for sync", "App Store screenshots"],
                ["Fix token refresh race", "Crash on empty profile"],
                ["Settings redesign"],
                ["Project scaffolding", "Design system tokens", "Auth flow", "Sync engine v1"],
            ],
            dueOffsets: [nil, 12, -2, 5, nil],
            priorities: [.low, .normal, .urgent, .high, .normal]
        )

        // 2 — behind schedule, with overdue work
        let redesign = Project(
            name: "Website Redesign",
            summary: "Rebuild marketing site on the new design system",
            goal: "Cut bounce rate below 40% and halve time-to-first-byte",
            plan: """
            Audit the current pages, agree the new IA, then rebuild
            page-by-page behind a flag. Content migration last.
            """,
            startDate: day(-70),
            targetEndDate: day(8),
            status: .active,
            accent: .purple,
            symbolName: "globe",
            sortOrder: 2048
        )
        context.insert(redesign)
        BoardMutations.makeDefaultColumns(for: redesign, in: context)
        seedItems(
            into: redesign,
            context: context,
            perColumn: [
                ["Retire legacy blog theme", "Pricing page copy", "SEO redirects map"],
                ["Case study template", "Careers page"],
                ["Homepage hero rebuild", "Nav + mobile menu", "Docs shell"],
                ["Accessibility pass"],
                ["IA workshop", "Content audit"],
            ],
            dueOffsets: [nil, -6, -3, 2, nil],
            priorities: [.normal, .high, .urgent, .normal, .low]
        )

        // 3 — archived
        let research = Project(
            name: "Q3 Research",
            summary: "Discovery interviews with enterprise customers",
            goal: "Decide whether to invest in an on-prem deployment story",
            plan: "12 interviews, synthesis workshop, written recommendation.",
            startDate: day(-160),
            targetEndDate: day(-90),
            status: .archived,
            accent: .teal,
            symbolName: "books.vertical",
            sortOrder: 3072
        )
        context.insert(research)
        BoardMutations.makeDefaultColumns(for: research, in: context)
        seedItems(
            into: research,
            context: context,
            perColumn: [[], [], [], [], ["Recruit participants", "Run interviews", "Synthesis", "Write-up"]],
            dueOffsets: [nil, nil, nil, nil, nil],
            priorities: [.low, .low, .normal, .normal, .normal]
        )
    }

    private static func seedItems(
        into project: Project,
        context: ModelContext,
        perColumn: [[String]],
        dueOffsets: [Int?],
        priorities: [Priority]
    ) {
        let calendar = Calendar.current
        let columns = project.orderedColumns
        let owners = ["RK", "AM", "JD", ""]

        for (columnIndex, titles) in perColumn.enumerated() where columnIndex < columns.count {
            let column = columns[columnIndex]
            for (itemIndex, title) in titles.enumerated() {
                let due = dueOffsets[safe: columnIndex].flatMap { $0 }.map {
                    calendar.date(byAdding: .day, value: $0 + itemIndex, to: .now) ?? .now
                }
                let item = WorkItem(
                    title: title,
                    details: "",
                    priority: priorities[safe: columnIndex] ?? .normal,
                    startDate: due.flatMap { calendar.date(byAdding: .day, value: -6, to: $0) },
                    dueDate: due,
                    owner: owners[(columnIndex + itemIndex) % owners.count],
                    tags: itemIndex.isMultiple(of: 2) ? ["v1"] : [],
                    sortOrder: Double(itemIndex + 1) * FractionalOrder.step
                )
                context.insert(item)
                item.column = column
                if column.isCompletionColumn { item.completedAt = .now }

                if itemIndex == 0 {
                    for (subIndex, subtitle) in ["Draft", "Review", "Ship"].enumerated() {
                        let subtask = Subtask(
                            title: subtitle,
                            isDone: subIndex == 0,
                            sortOrder: Double(subIndex + 1) * FractionalOrder.step
                        )
                        context.insert(subtask)
                        subtask.item = item
                    }
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
