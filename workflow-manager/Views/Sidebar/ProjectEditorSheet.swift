//
//  ProjectEditorSheet.swift
//  workflow-manager
//

import SwiftUI
import SwiftData

enum ProjectEditorTarget: Identifiable {
    case new
    case edit(Project)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let project): project.uuid.uuidString
        }
    }
}

struct ProjectEditorSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.sortOrder) private var projects: [Project]

    let target: ProjectEditorTarget
    var onSave: (Project) -> Void = { _ in }

    @State private var draft = ProjectDraft()
    @FocusState private var nameFocused: Bool

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                basicsSection
                intentSection
                timelineSection
                statusSection
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.isValid)
            }
            .padding(12)
        }
        // macOS sheets size to their content and look cramped without this.
        .frame(minWidth: 560, idealWidth: 600, minHeight: 540, idealHeight: 600)
        .onAppear {
            if case .edit(let project) = target {
                draft = ProjectDraft(project: project)
            }
            nameFocused = true
        }
    }

    // MARK: - Sections

    private var basicsSection: some View {
        Section("Basics") {
            TextField("Name", text: $draft.name, prompt: Text("Mobile App Launch"))
                .focused($nameFocused)

            TextField(
                "Short description",
                text: $draft.summary,
                prompt: Text("One line on what this project is"),
                axis: .vertical
            )
            .lineLimit(2...4)

            LabeledContent("Icon") {
                symbolPicker
            }

            LabeledContent("Accent") {
                accentPicker
            }
        }
    }

    private var symbolPicker: some View {
        Picker("Icon", selection: $draft.symbolName) {
            ForEach(ProjectSymbols.all, id: \.self) { symbol in
                Image(systemName: symbol).tag(symbol)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 90)
    }

    private var accentPicker: some View {
        HStack(spacing: 6) {
            ForEach(ProjectAccent.allCases) { accent in
                Button {
                    draft.accent = accent
                } label: {
                    Circle()
                        .fill(accent.color)
                        .frame(width: 18, height: 18)
                        .overlay {
                            Circle()
                                .strokeBorder(.primary, lineWidth: draft.accent == accent ? 2 : 0)
                        }
                }
                .buttonStyle(.plain)
                .help(accent.title)
            }
        }
    }

    private var intentSection: some View {
        Section("Intent") {
            TextField(
                "Goal",
                text: $draft.goal,
                prompt: Text("What does success look like?"),
                axis: .vertical
            )
            .lineLimit(2...4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Plan")
                    .font(.callout)
                TextEditor(text: $draft.plan)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 120)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if draft.plan.isEmpty {
                            Text("How you intend to get there — phases, milestones, risks.")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    private var timelineSection: some View {
        Section("Timeline") {
            DatePicker("Start", selection: $draft.startDate, displayedComponents: .date)

            Toggle("Set target end date", isOn: $draft.hasTargetEnd)

            if draft.hasTargetEnd {
                DatePicker("Target end", selection: $draft.targetEndDate, displayedComponents: .date)

                if let duration = draft.durationDescription {
                    LabeledContent("Duration") {
                        Text(duration)
                            .foregroundStyle(draft.isValid ? .secondary : Color.red)
                    }
                }
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            Picker("Status", selection: $draft.status) {
                ForEach(ProjectStatus.allCases) { status in
                    Text(status.title).tag(status)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Actions

    private func save() {
        guard draft.isValid else { return }
        let project: Project
        switch target {
        case .new:
            project = BoardMutations.createProject(from: draft, in: context, existing: projects)
        case .edit(let existing):
            BoardMutations.apply(draft, to: existing)
            project = existing
        }
        onSave(project)
        dismiss()
    }
}

#Preview("New") {
    ProjectEditorSheet(target: .new)
        .modelContainer(AppModelContainer.make(inMemory: true))
}
