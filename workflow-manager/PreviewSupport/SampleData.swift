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

        seedSidebar(into: context, launch: launch, redesign: redesign, research: research)
    }

    /// Workspaces, nested folders and a couple of cards with Claude, so the
    /// sidebar, Overview and smart lists have something to show. Every name is
    /// invented: this is what `-UseSampleData` screenshots are taken from.
    private static func seedSidebar(
        into context: ModelContext,
        launch: Project,
        redesign: Project,
        research: Project
    ) {
        let acme = SidebarMutations.createFolder(named: "Acme Corp", in: nil, context: context)
        let products = SidebarMutations.createFolder(named: "Products", in: acme, context: context)
        let clients = SidebarMutations.createFolder(named: "Client Work", in: acme, context: context)
        let personal = SidebarMutations.createFolder(named: "Personal", in: nil, context: context)

        launch.folder = products
        launch.isPinned = true
        redesign.folder = products
        research.folder = clients

        let extras: [(String, ProjectAccent, String, ProjectFolder?, ProjectStatus, Int)] = [
            ("Billing Portal", .green, "creditcard", clients, .active, 6),
            ("Partner API", .orange, "server.rack", clients, .active, 3),
            ("Field Notes", .teal, "leaf", personal, .active, 4),
            ("Dotfiles", .gray, "hammer", personal, .completed, 2),
            ("Recipe Box", .pink, "cart", nil, .planning, 0),
        ]
        for (index, extra) in extras.enumerated() {
            let project = Project(
                name: extra.0,
                summary: "",
                status: extra.4,
                accent: extra.1,
                symbolName: extra.2,
                sortOrder: Double(4 + index) * 1024
            )
            context.insert(project)
            BoardMutations.makeDefaultColumns(for: project, in: context)
            project.folder = extra.3
            let columns = project.orderedColumns
            for n in 0..<extra.5 {
                let item = WorkItem(title: "Task \(n + 1)", sortOrder: Double(n + 1) * FractionalOrder.step)
                context.insert(item)
                let column = columns[extra.4 == .completed ? columns.count - 1 : n % columns.count]
                item.column = column
                if column.isCompletionColumn { item.completedAt = .now }
            }
        }

        // Claude: one card being worked on, one opened as a PR. A project only
        // syncs with a folder to sync into, so it gets a scratch one.
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeWM-sample/mobile-app", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        launch.repoPath = Project.canonicalRepoPath(scratch)
        launch.repoOwner = "acme"
        launch.repoName = "mobile-app"
        launch.repoDefaultBranch = "main"
        launch.workflowSyncEnabled = true

        let columns = launch.orderedColumns
        if let working = columns[safe: 2]?.orderedItems.first {
            working.workflowRequested = true
            working.workflowBranch = "issue-57"
            working.githubIssueNumber = 57
            working.githubRepoSlug = "acme/mobile-app"
        }
        if let queued = columns[safe: 1]?.orderedItems.first {
            queued.workflowRequested = true
        }
        if let review = columns[safe: 3]?.orderedItems.first {
            review.workflowRequested = true
            review.workflowBranch = "issue-54"
            review.workflowPRURL = "https://github.com/acme/mobile-app/pull/212"
            review.githubIssueNumber = 54
            review.githubRepoSlug = "acme/mobile-app"
        }
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
