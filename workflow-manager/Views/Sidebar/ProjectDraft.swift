//
//  ProjectDraft.swift
//  workflow-manager
//
//  The editor sheet works on this plain struct rather than an inserted
//  model: SwiftData autosaves, so building the `Project` up front would
//  leave an empty one behind whenever the sheet is cancelled.
//

import Foundation

struct ProjectDraft {
    var name: String = ""
    var summary: String = ""
    var goal: String = ""
    var plan: String = ""
    var status: ProjectStatus = .planning
    var accent: ProjectAccent = .blue
    var symbolName: String = "square.stack.3d.up"
    var startDate: Date = .now
    var hasTargetEnd: Bool = true
    var targetEndDate: Date = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now

    init() {}

    /// Seeds the draft from an existing project for edit mode.
    init(project: Project) {
        name = project.name
        summary = project.summary
        goal = project.goal
        plan = project.plan
        status = project.status
        accent = project.accent
        symbolName = project.symbolName
        startDate = project.startDate
        hasTargetEnd = project.targetEndDate != nil
        targetEndDate = project.targetEndDate
            ?? Calendar.current.date(byAdding: .day, value: 30, to: project.startDate)
            ?? project.startDate
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !trimmedName.isEmpty && (!hasTargetEnd || targetEndDate >= startDate)
    }

    var durationDescription: String? {
        guard hasTargetEnd else { return nil }
        guard targetEndDate >= startDate else { return "Target end date is before the start date" }
        let days = DateHelpers.durationInDays(from: startDate, to: targetEndDate)
        return days == 1 ? "1 day" : "\(days) days"
    }
}
