//
//  BoardView.swift
//  workflow-manager
//

import SwiftUI
import SwiftData

struct BoardView: View {
    @Environment(\.modelContext) private var context

    @Bindable var project: Project
    @Binding var inspectedItemID: UUID?
    let filter: BoardFilter

    /// Fixed width is required: a `LazyHStack` inside a horizontal
    /// `ScrollView` cannot size its children to content.
    static let columnWidth: CGFloat = 300

    @State private var isAddingColumn = false
    @State private var newColumnName = ""
    @FocusState private var newColumnFocused: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(project.orderedColumns, id: \.uuid) { column in
                    BoardColumnView(
                        column: column,
                        inspectedItemID: $inspectedItemID,
                        filter: filter,
                        accent: project.accent.color
                    )
                    .frame(width: Self.columnWidth)
                }

                addColumnControl
                    .frame(width: Self.columnWidth)
            }
            .padding(20)
            // Columns fill the height themselves, so this is currently a no-op —
            // but the default `.center` would silently start centering them the
            // moment one stops filling. See `GitHubIssuesView.columns`.
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background(.background.secondary)
        .overlay {
            if project.columns.isEmpty {
                ContentUnavailableView {
                    Label("No Columns", systemImage: "rectangle.split.3x1")
                } description: {
                    Text("Add a column to start building this project's workflow.")
                } actions: {
                    Button("Add Column") { beginAddingColumn() }
                }
            }
        }
    }

    private var addColumnControl: some View {
        Group {
            if isAddingColumn {
                TextField("Column name", text: $newColumnName)
                    .textFieldStyle(.plain)
                    .focused($newColumnFocused)
                    .padding(10)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                    .onSubmit(commitNewColumn)
                    .onExitCommand { cancelAddingColumn() }
                    .onChange(of: newColumnFocused) { _, focused in
                        if !focused { cancelAddingColumn() }
                    }
            } else {
                Button(action: beginAddingColumn) {
                    Label("Add Column", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func beginAddingColumn() {
        newColumnName = ""
        isAddingColumn = true
        newColumnFocused = true
    }

    private func commitNewColumn() {
        let trimmed = newColumnName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return cancelAddingColumn() }
        withAnimation(.snappy) {
            _ = BoardMutations.addColumn(named: trimmed, to: project, in: context)
        }
        newColumnName = ""
        newColumnFocused = true
    }

    private func cancelAddingColumn() {
        newColumnName = ""
        isAddingColumn = false
        newColumnFocused = false
    }
}

#if DEBUG
#Preview {
    @Previewable @State var inspected: UUID?
    if let project = SampleData.firstProject {
        BoardView(project: project, inspectedItemID: $inspected, filter: BoardFilter())
            .modelContainer(SampleData.container)
            .frame(width: 1100, height: 620)
    }
}
#endif
