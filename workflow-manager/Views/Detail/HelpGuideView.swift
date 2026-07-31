//
//  HelpGuideView.swift
//  workflow-manager
//
//  The in-app user guide. Static content, rendered with the same
//  `IssueMarkdownView` a GitHub issue body uses, so there is one Markdown look
//  across the app. Opened from Help ▸ Claude WM Help (⌘?).
//

import SwiftUI

struct HelpGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.tint)
                Text("Claude WM Help")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            ScrollView {
                IssueMarkdownView(markdown: Self.guide)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(
            minWidth: 560, idealWidth: 720, maxWidth: .infinity,
            minHeight: 480, idealHeight: 680, maxHeight: .infinity
        )
        .onExitCommand { dismiss() }
    }

    /// The guide itself. Kept here as one string so it renders through the same
    /// Markdown pipeline as everything else.
    private static let guide = """
    # Claude WM

    A kanban board for your projects that can mirror a linked repository's
    GitHub issues and hand work to Claude Code — without leaving the window.

    ## Projects

    Each project is a board. Create one with **⌘N**, or link an existing
    repository from the **Issues** view. A project can point at a local Git
    clone; once it does, the repository-backed views (Issues, Terminal, Files)
    light up.

    Switch what a project shows from the toolbar in the middle of the window, or
    with **⌥⌘1–6**:

    - **Board** — the kanban columns.
    - **List** — the same items as a table.
    - **Timeline** — items across their dates.
    - **Issues** — the linked repository's open GitHub issues, fetched with `gh`.
    - **Terminal** — saved commands and live shells for the repository.
    - **Files** — a read-only browser of the working copy.

    ## Cards

    Click a card for a quick popover — retitle, change priority, open its issue.
    Press **Edit Details** for the full editor.

    ### The editor

    - **Notes** support Markdown, with a **Write / Preview** toggle. The preview
      is the same renderer used for issue bodies and card popovers.
    - Set priority, owner, dates, tags, and a checklist of subtasks.
    - Link the card to a GitHub issue.

    ## Dependencies

    A card can be **blocked by** other cards in the same project. In the editor,
    open **Blocked By ▸ Add Blocker…** and pick the cards that must finish first.

    - The picker only offers cards that are safe to add — it will not let you
      create a cycle.
    - A blocked card shows a **Blocked** badge until every blocker is done.
    - While a card is blocked, **Send to Claude** is disabled: don't hand work to
      an agent that can't start yet.

    Dependencies are local to your board. They are **not** written to
    `\(WorkflowDirectory.tasksPath)`, so a Claude session does not see them — they
    are an ordering aid for you, not a rule for the agent.

    ## Starting Claude on a card

    From a card's editor, **Claude Session ▸ Start Claude Session…** opens
    `claude` in the **Terminal** tab, in this project's repository, with the
    card's title and notes as the first message. It is a normal interactive
    session — Ctrl-C, scrollback and follow-up prompts all work.

    This is separate from **Send to Claude** (below): *Start Claude Session* is
    you driving a session directly; *Send to Claude* flags the card for a
    session that is already watching the board.

    ## Terminals

    The **Terminal** view runs the commands a project needs — a dev server, a
    watcher, a worker. Save them once and start them together with **Run All**,
    or open ad-hoc shells with **+**.

    Sessions keep running when you switch tabs or projects. Coming back shows
    them exactly as you left them. Only **Stop** (or quitting the app) ends a
    session.

    ## Board sync with Claude

    If a project has a linked repository, you can turn on **Sync Board with
    Claude** (project menu). The board is then mirrored into
    `\(WorkflowDirectory.tasksPath)`, and a Claude session can move cards and
    report the branch and pull request it opened.

    - **Send to Claude** on a card flags it as *requested*. A running session
      picks requested cards up from the file.
    - Columns map to a fixed vocabulary (`todo`, `in_progress`, `review`,
      `done`) through each column's **Claude Status**. Assign at least one for
      syncing to have somewhere to put work.
    - GitHub always wins: if the board and GitHub disagree, GitHub's state is
      what sticks.

    ## Files

    A read-only look at the working copy. Expand folders to load them lazily,
    toggle hidden files from the **⋯** menu, and select a file to read it with
    syntax highlighting. What you had open is restored when you return to the
    tab.
    """
}

#if DEBUG
#Preview {
    HelpGuideView()
        .frame(width: 720, height: 680)
}
#endif
