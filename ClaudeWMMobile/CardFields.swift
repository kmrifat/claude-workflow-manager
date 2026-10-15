//
//  CardFields.swift
//  ClaudeWMMobile
//
//  A card's fields as a row of chips — priority, due date, owner, issue, tags —
//  the way the Mac's card window shows them. A field with nothing in it is an
//  outlined "+ Due", so what can be set is visible without a form.
//
//  Bindings, not mutations: the card screen binds them to the Mac, the
//  new-card screen to its own state until Add.
//

import SwiftUI
import ClaudeWMWire

struct CardFieldChips: View {
    @Binding var priority: WirePriority
    @Binding var dueDate: Date?
    @Binding var owner: String
    @Binding var tags: [String]
    var issue: Int? = nil
    var issueURL: URL? = nil

    @State private var editingDue = false
    @State private var editingOwner = false
    @State private var addingTag = false
    @State private var ownerDraft = ""
    @State private var tagDraft = ""

    var body: some View {
        FlowLayout(spacing: 6) {
            Menu {
                Picker("Priority", selection: $priority) {
                    ForEach(WirePriority.allCases.reversed(), id: \.self) { Text($0.title).tag($0) }
                }
            } label: {
                if priority == .normal {
                    EmptyChip(text: "Priority")
                } else {
                    Chip(text: priority.title, tint: Palette.priority(priority), filled: true)
                }
            }

            Button { editingDue = true } label: {
                if let dueDate {
                    Chip(text: "Due \(dueDate.shortDay)",
                         tint: dueDate < Calendar.current.startOfDay(for: .now) ? .red : .orange, filled: true)
                } else {
                    EmptyChip(text: "Due")
                }
            }

            Button {
                ownerDraft = owner
                editingOwner = true
            } label: {
                if owner.isEmpty {
                    EmptyChip(text: "Owner")
                } else {
                    HStack(spacing: 5) {
                        Initials(name: owner, size: 18)
                        Text(Initials.initials(of: owner)).font(.footnote.weight(.medium))
                    }
                    .padding(.leading, 3).padding(.trailing, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
                }
            }

            if let issue {
                if let issueURL {
                    Link(destination: issueURL) { Chip(text: "#\(issue)") }
                } else {
                    Chip(text: "#\(issue)")
                }
            }

            ForEach(tags, id: \.self) { tag in
                Menu {
                    Button("Remove “\(tag)”", role: .destructive) { tags.removeAll { $0 == tag } }
                } label: {
                    Chip(text: tag, tint: .blue, filled: true)
                }
            }

            Button {
                tagDraft = ""
                addingTag = true
            } label: {
                if tags.isEmpty {
                    EmptyChip(text: "Tags")
                } else {
                    Image(systemName: "plus")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 1))
                }
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $editingDue) {
            DueDateSheet(dueDate: $dueDate)
                .presentationDetents([.medium, .large])
        }
        .alert("Owner", isPresented: $editingOwner) {
            TextField("Name", text: $ownerDraft)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            if !owner.isEmpty {
                Button("Clear", role: .destructive) { owner = "" }
            }
            Button("Set") { owner = ownerDraft.trimmingCharacters(in: .whitespaces) }
        }
        .alert("Add a Tag", isPresented: $addingTag) {
            TextField("Tag", text: $tagDraft)
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let tag = tagDraft.trimmingCharacters(in: .whitespaces)
                if !tag.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                    tags.append(tag)
                }
            }
        }
    }
}

private struct DueDateSheet: View {
    @Binding var dueDate: Date?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Date.now

    var body: some View {
        NavigationStack {
            DatePicker("Due", selection: $draft, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
                .navigationTitle("Due Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if dueDate != nil {
                            Button("Clear", role: .destructive) { dueDate = nil; dismiss() }
                        } else {
                            Button("Cancel") { dismiss() }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Set") { dueDate = Calendar.current.startOfDay(for: draft); dismiss() }
                    }
                }
        }
        .onAppear { draft = dueDate ?? .now }
    }
}

/// Lays chips out in lines, wrapping as text does.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
