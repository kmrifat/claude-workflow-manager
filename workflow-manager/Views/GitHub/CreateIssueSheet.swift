//
//  CreateIssueSheet.swift
//  workflow-manager
//
//  Files a board card as a GitHub issue.
//
//  This is the only screen in the app that changes anything on GitHub, so it
//  shows exactly what will be created and does nothing until the button is
//  pressed. An issue cannot be un-filed — closing one still leaves it, and its
//  number, visible to everyone on the repository.
//

import SwiftUI
import SwiftData

struct CreateIssueSheet: View {
    let item: WorkItem
    let project: Project
    /// Labels that already exist on the repository, taken from the cached
    /// issues. `gh issue create` fails outright on a label the repo doesn't
    /// have, so a card's tags can only be offered when they match one.
    let availableLabels: [String]
    var onCreated: (GitHubCLI.CreatedIssue) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var issueBody: String = ""
    @State private var selectedLabels: Set<String> = []
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var didPrepare = false

    /// The card's tags that the repository actually knows about.
    private var usableTags: [String] {
        let known = Set(availableLabels.map { $0.lowercased() })
        return item.tags.filter { known.contains($0.lowercased()) }
    }

    private var unusableTags: [String] {
        let known = Set(availableLabels.map { $0.lowercased() })
        return item.tags.filter { !known.contains($0.lowercased()) }
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create GitHub Issue")
                    .font(.headline)
                Text("Files this card as a new issue on \(project.repoSlug ?? "the linked repository") and links the card to it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                        .lineLimit(1...3)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Body").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $issueBody)
                            .scrollContentBackground(.hidden)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 150)
                            .padding(6)
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                    }
                }

                if !usableTags.isEmpty {
                    Section("Labels") {
                        ForEach(usableTags, id: \.self) { tag in
                            Toggle(tag, isOn: labelBinding(for: tag))
                        }
                    }
                }

                if !unusableTags.isEmpty {
                    Section {
                        Label(
                            "\(unusableTags.joined(separator: ", ")) — not a label on this repository, so it can’t be applied here.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text("This creates a real issue and can’t be undone.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCreating ? "Creating…" : "Create Issue") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 560)
        .onAppear {
            // Only once: reopening after a failed attempt must not discard the
            // user's edits to the title or body.
            guard !didPrepare else { return }
            didPrepare = true
            title = item.title
            issueBody = item.details
            selectedLabels = Set(usableTags)
        }
    }

    private func labelBinding(for tag: String) -> Binding<Bool> {
        Binding(
            get: { selectedLabels.contains(tag) },
            set: { isOn in
                if isOn { selectedLabels.insert(tag) } else { selectedLabels.remove(tag) }
            }
        )
    }

    private func create() {
        guard let directory = project.repoDirectory else { return }
        isCreating = true
        errorMessage = nil

        Task {
            defer { isCreating = false }
            do {
                let created = try await GitHubCLI.createIssue(
                    at: directory,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    body: issueBody,
                    labels: usableTags.filter { selectedLabels.contains($0) }
                )
                onCreated(created)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
