//
//  WireProtocol.swift
//  ClaudeWMWire
//
//  The compatibility boundary between Claude WM and its iOS client. The message
//  types themselves land here next; this file owns the one thing they all carry.
//

import Foundation

public enum WireProtocol {
    /// Bumped when the shape of a message changes in a way an older peer cannot
    /// read. Both sides send it and both sides check it.
    ///
    /// The rule, borrowed from `WorkflowTasksFile.Envelope.isFromNewerVersion`
    /// because it was right there: a peer speaking a *newer* version is neither
    /// applied nor answered. Guessing at a format you do not know corrupts the
    /// board, and replying in the old format tells the newer peer its write
    /// succeeded. Say so and disconnect instead.
    ///
    /// A peer speaking an *older* version is a different question and is left
    /// open deliberately — there is exactly one version today, so any policy
    /// written now would be a guess.
    public static let version = 1
}
