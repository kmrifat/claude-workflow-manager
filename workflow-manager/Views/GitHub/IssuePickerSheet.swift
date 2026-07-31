//
//  IssuePickerSheet.swift
//  workflow-manager
//
//  Picks the GitHub issue a card should track.
//
//  Reads the cache rather than shelling out to `gh` — opening a picker should
//  not cost a subprocess. If the cache is empty the sheet says so and offers to
//  fetch, which is the only path here that touches the network.
//

import SwiftUI
import SwiftData

struct IssuePickerSheet: View {
    let project: Project
    /// Already-tracked numbers, so the sheet can mark them rather than silently
    /// letting two cards claim one issue.
    let claimed: Set<Int>
    let currentSelection: Int?
    let onPick: (GitHubIssue) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var issues: [GitHubIssue] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var visible: [GitHubIssue] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return issues }
        return issues.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Link to Issue")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn’t Load Issues", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load(forceFetch: true) } }
                }
            } else if issues.isEmpty {
                ContentUnavailableView {
                    Label("No Issues Cached", systemImage: "tray")
                } description: {
                    Text("Open the Issues view to fetch this repository’s open issues.")
                } actions: {
                    Button("Fetch Now") { Task { await load(forceFetch: true) } }
                }
            } else {
                List(visible) { issue in
                    row(for: issue)
                }
                .listStyle(.inset)
                .searchable(text: $searchText, prompt: "Search issues")
            }
        }
        .frame(width: 520, height: 440)
        .task { await load(forceFetch: false) }
    }

    private func row(for issue: GitHubIssue) -> some View {
        Button {
            onPick(issue)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Text("#\(issue.number)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(issue.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if issue.number == currentSelection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(project.accent.color)
                } else if claimed.contains(issue.number) {
                    Text("tracked")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func load(forceFetch: Bool) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        if !forceFetch, let hit = await IssueCache.load(for: project, in: context) {
            issues = hit.issues
            return
        }
        guard let directory = project.repoDirectory else { return }
        do {
            let fetched = try await GitHubCLI.openIssues(at: directory)
            issues = fetched
            await IssueCache.store(fetched, for: project, in: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
