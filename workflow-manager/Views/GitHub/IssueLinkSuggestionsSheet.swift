//
//  IssueLinkSuggestionsSheet.swift
//  workflow-manager
//
//  The confirmation step for `IssueLinkSuggester`. Title matching proposes;
//  only this sheet, and only what the user ticks, actually links anything.
//
//  Exact matches are pre-selected. Fuzzy ones are not — a wrong link is
//  invisible afterwards, so the burden of proof sits with the match.
//

import SwiftUI
import SwiftData

struct IssueLinkSuggestionsSheet: View {
    let project: Project
    let suggestions: [IssueLinkSuggester.Suggestion]

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggested Links")
                        .font(.headline)
                    Text("Matched by title. Nothing is linked until you apply.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if suggestions.isEmpty {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "link.badge.plus")
                } description: {
                    Text("No unlinked card's title resembles an open issue.")
                }
            } else {
                List(suggestions) { suggestion in
                    row(for: suggestion)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                if !suggestions.isEmpty {
                    Text("\(selected.count) of \(suggestions.count) selected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Link Selected") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 620, height: 460)
        .onAppear {
            selected = Set(suggestions.filter(\.isExact).map(\.itemUUID))
        }
    }

    private func row(for suggestion: IssueLinkSuggester.Suggestion) -> some View {
        Toggle(isOn: binding(for: suggestion.itemUUID)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(suggestion.itemTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(suggestion.isExact
                         ? "exact"
                         : "\(Int((suggestion.confidence * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(suggestion.isExact ? project.accent.color : .secondary)
                }
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("#\(suggestion.issueNumber)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(suggestion.issueTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    private func apply() {
        let byUUID = Dictionary(
            project.allItems.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for suggestion in suggestions where selected.contains(suggestion.itemUUID) {
            guard let item = byUUID[suggestion.itemUUID] else { continue }
            IssueLinking.link(
                item,
                toIssueNumber: suggestion.issueNumber,
                slug: project.repoSlug
            )
        }
        dismiss()
    }
}
