//
//  CardFields.swift
//  workflow-manager
//
//  A card's fields as a row of chips under its title — design C02 — rather
//  than a form. Notes has no fields at all; a card has a few, and a chip is
//  the lightest thing that can hold one and still be clicked to change it.
//
//  A field that is set gets a filled chip. One that is not appears in the
//  trailing "+" menu — or, on a card with nothing set yet (C03), as a row of
//  outlined "+ Due date" chips, so a new card shows what it can carry.
//

import SwiftUI
import SwiftData

struct CardFields: View {
    @Bindable var item: WorkItem
    /// The window presents sheets: a sheet cannot belong to a chip's popover.
    var onCreateIssue: () -> Void
    var onLinkIssue: () -> Void
    var onAddBlocker: () -> Void

    @State private var editing: Field?

    enum Field: Hashable {
        case due, owner, tags, blockers
    }

    private var hasRepository: Bool { item.project?.repoSlug != nil }

    private var isBare: Bool {
        item.priority == .normal && item.dueDate == nil && item.owner.isEmpty
            && item.tags.isEmpty && item.githubIssueNumber == nil && item.blockedBy.isEmpty
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            if isBare {
                ghostChips
            } else {
                filledChips
                addMenu
            }
        }
    }

    // MARK: - Filled

    @ViewBuilder
    private var filledChips: some View {
        if item.priority != .normal {
            priorityMenu {
                chip(item.priority.title, tint: item.priority.chipColor, filled: true, weight: .semibold)
            }
        }
        if let due = item.dueDate {
            Button { editing = .due } label: {
                chip("Due \(due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))",
                     tint: dueTint, filled: false)
            }
            .buttonStyle(.plain)
            .popover(isPresented: binding(.due), arrowEdge: .bottom) { duePopover }
        }
        if !item.owner.isEmpty {
            Button { editing = .owner } label: {
                HStack(spacing: 5) {
                    Text(initials(item.owner))
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Color.teal.gradient, in: .circle)
                    Text(item.owner).font(.system(size: 11.5))
                }
                .padding(.leading, 4)
                .padding(.trailing, 9)
                .frame(height: 24)
                .background(Color.primary.opacity(0.08), in: .capsule)
            }
            .buttonStyle(.plain)
            .popover(isPresented: binding(.owner), arrowEdge: .bottom) { ownerPopover }
        }
        if let number = item.githubIssueNumber {
            Menu {
                if let url = item.githubIssueURL {
                    Link("Open #\(number) on GitHub", destination: url)
                }
                Button("Unlink Issue") { IssueLinking.unlink(item) }
            } label: {
                chip("#\(number)", tint: item.hasResolvableIssueLink ? .primary : .secondary,
                     filled: true, monospaced: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        ForEach(item.tags, id: \.self) { tag in
            Button { editing = .tags } label: {
                chip(tag, tint: item.project?.accent.color ?? .accentColor, filled: true, weight: .medium)
            }
            .buttonStyle(.plain)
            .contextMenu { Button("Remove Tag") { item.tags.removeAll { $0 == tag } } }
            .popover(isPresented: tag == item.tags.first ? binding(.tags) : .constant(false), arrowEdge: .bottom) {
                tagsPopover
            }
        }
        if !item.blockedBy.isEmpty {
            Button { editing = .blockers } label: {
                chip(item.isBlocked ? "Blocked by \(item.openBlockers.count)" : "Blockers done",
                     tint: item.isBlocked ? Theme.warning : .secondary, filled: true, weight: .medium)
            }
            .buttonStyle(.plain)
            .popover(isPresented: binding(.blockers), arrowEdge: .bottom) { blockersPopover }
        }
    }

    /// What is not set yet, in one place.
    private var addMenu: some View {
        Menu {
            if item.priority == .normal {
                Menu("Priority") { priorityChoices }
            }
            if item.dueDate == nil { Button("Due Date…") { setDefaultDue(); editing = .due } }
            if item.owner.isEmpty { Button("Owner…") { editing = .owner } }
            if item.tags.isEmpty { Button("Tags…") { editing = .tags } }
            if item.githubIssueNumber == nil, hasRepository {
                Menu("GitHub Issue") {
                    Button("Link to Existing Issue…", action: onLinkIssue)
                    Button("Create GitHub Issue…", action: onCreateIssue)
                }
            }
            Button("Blocked By…", action: onAddBlocker)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.18)) }
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a field")
        // The chips a field gets once set do not exist yet, so the popovers
        // for a field picked from here hang off this button.
        .popover(isPresented: emptyFieldBinding, arrowEdge: .bottom) { emptyFieldPopover }
    }

    // MARK: - Ghost

    @ViewBuilder
    private var ghostChips: some View {
        priorityMenu { ghost("Priority") }
        Button { setDefaultDue(); editing = .due } label: { ghost("Due date") }
            .buttonStyle(.plain)
            .popover(isPresented: binding(.due), arrowEdge: .bottom) { duePopover }
        Button { editing = .owner } label: { ghost("Owner") }
            .buttonStyle(.plain)
            .popover(isPresented: binding(.owner), arrowEdge: .bottom) { ownerPopover }
        Button { editing = .tags } label: { ghost("Tags") }
            .buttonStyle(.plain)
            .popover(isPresented: binding(.tags), arrowEdge: .bottom) { tagsPopover }
        if hasRepository {
            Menu {
                Button("Link to Existing Issue…", action: onLinkIssue)
                Button("Create GitHub Issue…", action: onCreateIssue)
            } label: { ghost("GitHub issue") }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - Popovers

    private var duePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Due", selection: Binding(
                get: { item.dueDate ?? .now },
                set: { item.dueDate = $0 }
            ), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            Toggle("Starts on a date", isOn: Binding(
                get: { item.startDate != nil },
                set: { item.startDate = $0 ? Calendar.current.startOfDay(for: .now) : nil }
            ))
            .font(.system(size: 12))
            if item.startDate != nil {
                DatePicker("Starts", selection: Binding(
                    get: { item.startDate ?? .now },
                    set: { item.startDate = $0 }
                ), displayedComponents: .date)
                .font(.system(size: 12))
            }
            HStack {
                Button("Remove Due Date", role: .destructive) {
                    item.dueDate = nil
                    editing = nil
                }
                Spacer()
                Button("Done") { editing = nil }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 260)
    }

    private var ownerPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Owner").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextField("Name or initials", text: $item.owner)
                .textFieldStyle(.roundedBorder)
                .onSubmit { editing = nil }
        }
        .padding(14)
        .frame(width: 220)
    }

    private var tagsPopover: some View {
        TagsEditor(tags: $item.tags, suggestions: tagSuggestions) { editing = nil }
    }

    private var blockersPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Blocked by").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(item.blockedBy, id: \.uuid) { blocker in
                HStack(spacing: 8) {
                    RoundCheckbox(isOn: blocker.isDone, size: 14)
                    Text(blocker.displayTitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(blocker.isDone ? .secondary : .primary)
                    Spacer(minLength: 4)
                    Button {
                        item.blockedBy.removeAll { $0.uuid == blocker.uuid }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
            }
            Divider()
            Button("Add Blocker…") {
                editing = nil
                onAddBlocker()
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
    }

    @ViewBuilder
    private var emptyFieldPopover: some View {
        switch editing {
        case .due: duePopover
        case .owner: ownerPopover
        case .tags: tagsPopover
        default: EmptyView()
        }
    }

    // MARK: - Pieces

    private func priorityMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu { priorityChoices } label: { label() }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Priority")
    }

    @ViewBuilder
    private var priorityChoices: some View {
        ForEach(Priority.allCases.reversed()) { priority in
            Button {
                item.priority = priority
            } label: {
                if priority == item.priority {
                    Label(priority.title, systemImage: "checkmark")
                } else {
                    Text(priority.title)
                }
            }
        }
    }

    private func chip(
        _ text: String,
        tint: Color,
        filled: Bool,
        weight: Font.Weight = .regular,
        monospaced: Bool = false
    ) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: weight, design: monospaced ? .monospaced : .default))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(filled ? tint.opacity(0.14) : .clear, in: .capsule)
            .overlay { if !filled { Capsule().strokeBorder(tint.opacity(0.45)) } }
            .contentShape(.capsule)
    }

    private func ghost(_ text: String) -> some View {
        Text("+ \(text)")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.18)) }
            .contentShape(.capsule)
    }

    private var dueTint: Color {
        item.isOverdue ? Theme.danger : (item.isDueSoon ? Theme.warning : .secondary)
    }

    private func binding(_ field: Field) -> Binding<Bool> {
        Binding(get: { editing == field }, set: { if !$0, editing == field { editing = nil } })
    }

    /// A field picked from "+" before it has a chip of its own.
    private var emptyFieldBinding: Binding<Bool> {
        Binding(
            get: {
                switch editing {
                case .due: !isBare && item.dueDate == nil
                case .owner: !isBare && item.owner.isEmpty
                case .tags: !isBare && item.tags.isEmpty
                default: false
                }
            },
            set: { if !$0 { editing = nil } }
        )
    }

    private func setDefaultDue() {
        if item.dueDate == nil {
            item.dueDate = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: .now))
        }
    }

    private func initials(_ name: String) -> String {
        let words = name.split(separator: " ")
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(2))
        return String(letters).uppercased()
    }

    /// Tags already used elsewhere in the project, so the same tag is not
    /// spelled two ways.
    private var tagSuggestions: [String] {
        let used = Set(item.project?.allItems.flatMap(\.tags) ?? [])
        return used.subtracting(item.tags).sorted()
    }
}

/// Add and remove tags; suggests ones the project already uses.
private struct TagsEditor: View {
    @Binding var tags: [String]
    var suggestions: [String]
    var onDone: () -> Void

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if !tags.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag).font(.system(size: 11.5, weight: .medium))
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Color.primary.opacity(0.08), in: .capsule)
                    }
                }
            }
            TextField("Add a tag", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            let matching = suggestions.filter { draft.isEmpty || $0.localizedCaseInsensitiveContains(draft) }
            if !matching.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(matching.prefix(12), id: \.self) { tag in
                        Button(tag) { tags.append(tag) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.18)) }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func add() {
        let tag = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !tag.isEmpty else { return onDone() }
        if !tags.contains(tag) { tags.append(tag) }
    }
}
