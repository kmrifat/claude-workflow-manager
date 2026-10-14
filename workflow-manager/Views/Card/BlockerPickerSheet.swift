//
//  BlockerPickerSheet.swift
//  workflow-manager
//

import SwiftUI
import SwiftData

/// Picks another card to add as a blocker. The candidate list is already
/// filtered to what is safe to add (no self, no duplicates, no cycles).
struct BlockerPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [WorkItem]
    var onPick: (WorkItem) -> Void

    @State private var query = ""

    private var filtered: [WorkItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return candidates }
        return candidates.filter { $0.matches(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Blocker")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            if candidates.isEmpty {
                ContentUnavailableView(
                    "No Eligible Cards",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Other cards in this project can be added here, as long as they don't create a cycle.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, id: \.uuid) { candidate in
                    Button {
                        onPick(candidate)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: candidate.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(candidate.isDone ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.title.isEmpty ? "Untitled" : candidate.title)
                                    .lineLimit(1)
                                if let column = candidate.column {
                                    Text(column.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .searchable(text: $query, prompt: "Search cards")
            }
        }
        .frame(width: 420, height: 480)
    }
}
