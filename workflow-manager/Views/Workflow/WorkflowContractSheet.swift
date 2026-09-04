//
//  WorkflowContractSheet.swift
//  workflow-manager
//
//  Offers to write the two documents that tell a Claude session how to use
//  `.taskboard/tasks.json`.
//
//  Both are shown in full before anything is written. `claude remote-control`
//  takes no prompt, so this is the only way the contract reaches the agent — but
//  one of the files goes into a repository the user has committed, and an app
//  that edits those silently is an app you stop trusting.
//

import SwiftUI

struct WorkflowContractSheet: View {
    let project: Project

    @Environment(\.dismiss) private var dismiss

    @State private var writeReadme = true
    @State private var writeMemory = true
    @State private var selection: Document = .readme
    @State private var errorMessage: String?

    private enum Document: String, CaseIterable, Identifiable {
        case readme
        case example
        case memory

        var id: String { rawValue }

        var title: String {
            switch self {
            case .readme: WorkflowDirectory.readmePath
            case .example: WorkflowDirectory.examplePath
            case .memory: "CLAUDE.md"
            }
        }
    }

    private var readmeText: String {
        WorkflowDirectory.readme(
            projectName: project.name,
            repositorySlug: project.repoSlug
        )
    }

    private var exampleText: String {
        WorkflowTasksFile.exampleJSON
    }

    private var memoryText: String {
        WorkflowDirectory.claudeMemorySnippet()
    }

    private func text(for document: Document) -> String {
        switch document {
        case .readme: readmeText
        case .example: exampleText
        case .memory: memoryText
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up the Claude Contract")
                    .font(.headline)
                Text("A Claude session can’t be handed a prompt, so these files are how it learns the rules. Nothing is written until you apply.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Picker("", selection: $selection) {
                ForEach(Document.allCases) { document in
                    Text(document.title).tag(document)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 10)

            ScrollView {
                Text(text(for: selection))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.quaternary.opacity(0.4))
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "Write \(WorkflowDirectory.readmePath) and \(WorkflowDirectory.examplePath)",
                    isOn: $writeReadme
                )
                Toggle("Append the block to the repository’s CLAUDE.md", isOn: $writeMemory)
                Text("The block is delimited by markers, so applying this again replaces it rather than adding a second copy.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Write Files") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!writeReadme && !writeMemory)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(width: 660, height: 620)
    }

    private func apply() {
        guard let repository = project.repoDirectory else { return }
        do {
            try WorkflowDirectory.ensure(in: repository)

            if writeReadme {
                try Data(readmeText.utf8).write(
                    to: WorkflowDirectory.readmeURL(in: repository),
                    options: .atomic
                )
                // Prose about a shape gets reinterpreted; a file to copy does
                // not. It goes next to `tasks.json` so a session that has found
                // one has found the other.
                try Data(exampleText.utf8).write(
                    to: WorkflowDirectory.exampleURL(in: repository),
                    options: .atomic
                )
            }

            if writeMemory {
                let url = repository.appending(path: "CLAUDE.md")
                let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let updated = WorkflowDirectory.applyingMemorySnippet(to: existing)
                try Data(updated.utf8).write(to: url, options: .atomic)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
