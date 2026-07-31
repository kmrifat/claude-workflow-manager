//
//  QuickAddField.swift
//  workflow-manager
//
//  "+ Add item" that swaps into a focused text field. Return commits and
//  keeps focus so a whole column can be typed out in one go; Escape dismisses.
//

import SwiftUI

struct QuickAddField: View {
    let placeholder: String
    let onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(8)
                    .background(.background, in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                    .onSubmit(commit)
                    .onExitCommand { dismiss() }
                    .onChange(of: focused) { _, nowFocused in
                        if !nowFocused { dismiss() }
                    }
            } else {
                Button {
                    isEditing = true
                    focused = true
                } label: {
                    Label("Add item", systemImage: "plus")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Starts editing from outside (⇧⌘N).
    func beginEditing() {
        isEditing = true
        focused = true
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            dismiss()
            return
        }
        onCommit(trimmed)
        text = ""
        focused = true
    }

    private func dismiss() {
        text = ""
        isEditing = false
        focused = false
    }
}
