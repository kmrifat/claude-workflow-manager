//
//  TerminalCommandSheet.swift
//  workflow-manager
//
//  Adds or edits one saved command.
//

import SwiftUI
import SwiftData

struct TerminalCommandSheet: View {
    enum Target: Identifiable {
        case new
        case edit(TerminalCommand)

        var id: String {
            switch self {
            case .new: "new"
            case .edit(let command): command.uuid.uuidString
            }
        }
    }

    let target: Target
    let project: Project

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var command = ""
    @State private var directory = ""
    @State private var includeInRunAll = true
    @State private var didLoad = false

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    /// Empty means the repository root, and a path that climbs out of the
    /// repository is refused — a saved `../..` should not become a way to run
    /// commands anywhere on the disk.
    private var directoryProblem: String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let probe = TerminalCommand(directory: trimmed)
        guard let resolved = probe.resolvedDirectory(in: project) else {
            return "That path is outside the repository."
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: resolved.path(percentEncoded: false),
            isDirectory: &isDirectory
        )
        if !exists { return "No such folder in the repository (yet)." }
        if !isDirectory.boolValue { return "That is a file, not a folder." }
        return nil
    }

    private var canSave: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Command" : "New Command")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Dev server"))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $command)
                            .scrollContentBackground(.hidden)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 60)
                            .padding(6)
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                        Text("Run by your login shell, so aliases, `nvm` and `&&` all work.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Folder", text: $directory, prompt: Text("Repository root"))
                        .font(.system(size: 12, design: .monospaced))
                    if let directoryProblem {
                        Label(directoryProblem, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(resolvedDescription)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Working Folder")
                } footer: {
                    Text("Relative to the repository, so the command survives a re-clone.")
                        .font(.system(size: 10))
                }

                Section {
                    Toggle("Include in Run All", isOn: $includeInRunAll)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 500)
        .onAppear(perform: load)
    }

    private var resolvedDescription: String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = project.repoDirectory?.lastPathComponent ?? "repository"
        return trimmed.isEmpty ? "\(root)/" : "\(root)/\(trimmed)"
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if case .edit(let existing) = target {
            name = existing.name
            command = existing.command
            directory = existing.directory
            includeInRunAll = existing.isIncludedInRunAll
        }
    }

    private func save() {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)

        switch target {
        case .edit(let existing):
            existing.name = name
            existing.command = trimmedCommand
            existing.directory = trimmedDirectory
            existing.isIncludedInRunAll = includeInRunAll

        case .new:
            let created = TerminalCommand(
                name: name,
                command: trimmedCommand,
                directory: trimmedDirectory,
                sortOrder: FractionalOrder.afterLast(
                    of: project.terminalCommands.map(\.sortOrder)
                ),
                isIncludedInRunAll: includeInRunAll
            )
            context.insert(created)
            created.project = project
        }
        dismiss()
    }
}
