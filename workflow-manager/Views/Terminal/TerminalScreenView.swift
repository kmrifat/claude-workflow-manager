//
//  TerminalScreenView.swift
//  workflow-manager
//
//  Puts the session's terminal on screen.
//
//  There is almost nothing here on purpose. The screen is SwiftTerm's
//  `TerminalView`, and it belongs to the `TerminalSession` rather than to this
//  view: the session outlives every pane that shows it, so switching tabs or
//  projects must not take the scrollback with it. This file's whole job is to
//  hand SwiftUI the view the session already owns, and to give it the keyboard.
//
//  Two things this replaced, both of which a hand-written grid gets wrong:
//
//  * **Selection is a range over the grid, not over a line.** Drawing each row
//    as its own `Text` made a cross-line selection impossible to express, so
//    copying a command's output could not work however the rows were styled.
//  * **⌘V has to be bracketed.** A terminal that pastes raw text hands zsh a
//    multi-line paste it executes line by line. `TerminalView` implements the
//    standard `paste(_:)` responder action and wraps the text in `ESC[200~` /
//    `ESC[201~` when the program asked for it, so ⌘V needs no code here at all.
//

import SwiftTerm
import SwiftUI

struct TerminalScreenView: View {
    let session: TerminalSession

    var body: some View {
        // Identity has to follow the session. `updateNSView` cannot swap the
        // view it is handed, so without this a change of selection would leave
        // the previous session's terminal on screen.
        Surface(session: session).id(session.id)
    }

    private struct Surface: NSViewRepresentable {
        let session: TerminalSession

        func makeNSView(context: Context) -> SwiftTerm.TerminalView {
            let view = session.terminalView
            // Typing should work without clicking first. Deferred because the
            // view has no window yet at the moment SwiftUI asks for it.
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
            return view
        }

        func updateNSView(_ view: SwiftTerm.TerminalView, context: Context) {}
    }
}
