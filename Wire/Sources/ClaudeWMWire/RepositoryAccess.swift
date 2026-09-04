//
//  RepositoryAccess.swift
//  ClaudeWMWire
//
//  The types behind Terminal and Files on the phone.
//
//  These are a different kind of thing from `BoardMutation`, and the difference
//  is worth stating once here rather than rediscovering it later. A board
//  mutation is a *vocabulary*: the phone may set a title or move a card, and
//  anything outside that list has no spelling on the wire at all. A terminal has
//  no such vocabulary — the whole point is arbitrary input to a shell — so the
//  protections have to sit somewhere else:
//
//  - **The feature is off unless the Mac's owner turns it on**, separately from
//    sharing the board. See `RemoteAccessSettings`.
//  - **Paths are relative to the repository, always.** An absolute path never
//    crosses this wire in either direction. The phone cannot name
//    `~/.ssh/id_rsa` because it cannot name anything outside the repository
//    root, and the Mac re-checks containment on every request rather than
//    trusting that the string it received came from our own client.
//  - **Files are read-only.** There is no write, rename, create or delete
//    message, matching the Mac's own Files view. Editing happens in a real
//    editor; a phone that quietly disagreed with it would be worse than nothing.
//
//  What is deliberately *not* claimed: this does not make a stolen pairing key
//  safe. A phone that holds the key and finds the feature enabled has a shell.
//  That is inherent to "terminal on the phone", and the honest mitigation is
//  that the key is one QR code away from being rotated.
//

import Foundation

// MARK: - Terminal

/// One terminal session on the Mac, as much as the phone needs to list it.
///
/// `cols`/`rows` are the Mac's grid. The phone renders at that size rather than
/// resizing the pty to fit a handset: the session is shared, and a phone
/// attaching must not reflow the window someone is looking at on the desktop.
public struct WireTerminalRef: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var isRunning: Bool
    /// True when the session came from a saved command rather than being opened
    /// by hand — the phone groups them the way the Mac's sidebar does.
    public var isSavedCommand: Bool
    /// Short human-readable state ("Running", "Exited 1"), written on the Mac so
    /// both screens say the same words.
    public var status: String
    public var cols: Int
    public var rows: Int

    public init(
        id: String,
        title: String,
        isRunning: Bool,
        isSavedCommand: Bool,
        status: String,
        cols: Int,
        rows: Int
    ) {
        self.id = id
        self.title = title
        self.isRunning = isRunning
        self.isSavedCommand = isSavedCommand
        self.status = status
        self.cols = cols
        self.rows = rows
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = (try? container.decode(String.self, forKey: .title)) ?? "Terminal"
        isRunning = (try? container.decode(Bool.self, forKey: .isRunning)) ?? false
        isSavedCommand = (try? container.decode(Bool.self, forKey: .isSavedCommand)) ?? false
        status = (try? container.decode(String.self, forKey: .status)) ?? ""
        // A zero grid would divide by zero in the phone's layout. The default is
        // the classic 80×24 rather than 0.
        cols = (try? container.decode(Int.self, forKey: .cols)).flatMap { $0 > 0 ? $0 : nil } ?? 80
        rows = (try? container.decode(Int.self, forKey: .rows)).flatMap { $0 > 0 ? $0 : nil } ?? 24
    }
}

/// Lifecycle, which is all the phone may ask for. There is no "run this command"
/// — starting a session runs the command the Mac already has saved for it, and
/// anything else is typed into a shell like it would be on the desktop.
public enum WireTerminalAction: String, Codable, Sendable, Equatable {
    case start
    case stop
    case restart

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WireTerminalAction(rawValue: raw) ?? .stop
    }
}

// MARK: - Paths

/// The repository-relative path rules, kept here because both ends need them and
/// neither should have its own version.
///
/// This is the *pure* half of the check and not the whole of it: it rejects
/// paths that are obviously outside the repository, while the Mac still resolves
/// the result against the real root and re-tests containment. A symlink inside
/// the repository pointing at `~/.ssh` cannot be caught by string rules at all,
/// so that check has to touch the filesystem and lives on the Mac.
public enum RepositoryPath {
    /// Normalises a path from the wire, or returns nil if it has no business
    /// being honoured. "" and "." both mean the root.
    ///
    /// Rejected: anything absolute, and any `..` component. `..` is refused
    /// outright rather than resolved, because "resolve then check" is the
    /// version of this that people get wrong — `a/../../b` collapses to `../b`,
    /// and a check written against the un-collapsed string sees only `a` at the
    /// front and passes it.
    public static func sanitize(_ path: String) -> String? {
        if path.hasPrefix("/") || path.hasPrefix("~") { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var kept: [Substring] = []
        for component in components {
            if component == ".." { return nil }
            if component == "." { continue }
            kept.append(component)
        }
        return kept.joined(separator: "/")
    }

    /// The path of `child` relative to `root`, for building a listing. Returns
    /// nil when `child` is not inside `root`.
    ///
    /// **The trailing slash is the trap here.** `standardizedFileURL.path` keeps
    /// one for a directory, so a root of `…/repo/` compared with `hasPrefix`
    /// tests for `…/repo//` and is false for every subfolder — a containment
    /// check that silently rejects everything and looks exactly like the escape
    /// it is meant to catch. `TerminalCommand.path(_:isInside:)` on the Mac hit
    /// this first; it is the same bug twice if this forgets it.
    public static func relative(_ child: String, to root: String) -> String? {
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        if child == root { return "" }
        guard child.hasPrefix(root + "/") else { return nil }
        return String(child.dropFirst(root.count + 1))
    }
}

// MARK: - Files

/// One entry in a directory listing. `path` is repository-relative and is what
/// the phone sends back to descend or read — it never learns where the
/// repository lives on the Mac.
public struct WireFileNode: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    /// Bytes, for files only.
    public var size: Int?

    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, size: Int?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        name = (try? container.decode(String.self, forKey: .name))
            ?? (path as NSString).lastPathComponent
        isDirectory = (try? container.decode(Bool.self, forKey: .isDirectory)) ?? false
        size = try? container.decodeIfPresent(Int.self, forKey: .size)
    }
}

/// What came back for a file. Mirrors the Mac's `FileTree.Content` case for
/// case, including the refusals — a phone showing "2.4 MB, too large to preview"
/// is telling the truth, where a phone showing an empty document is not.
public enum WireFileContent: Sendable, Equatable {
    case text(String)
    case image(Data)
    case binary(size: Int)
    case tooLarge(size: Int)
    case unreadable(String)

    public var kind: String {
        switch self {
        case .text:       "text"
        case .image:      "image"
        case .binary:     "binary"
        case .tooLarge:   "tooLarge"
        case .unreadable: "unreadable"
        }
    }
}

extension WireFileContent: Codable {
    private enum Keys: String, CodingKey { case kind, text, data, size, message }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .text(let text):        try container.encode(text, forKey: .text)
        case .image(let data):       try container.encode(data, forKey: .data)
        case .binary(let size):      try container.encode(size, forKey: .size)
        case .tooLarge(let size):    try container.encode(size, forKey: .size)
        case .unreadable(let reason): try container.encode(reason, forKey: .message)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "text":
            self = .text((try? container.decode(String.self, forKey: .text)) ?? "")
        case "image":
            guard let data = try? container.decode(Data.self, forKey: .data) else {
                self = .unreadable("That image could not be read.")
                return
            }
            self = .image(data)
        case "binary":
            self = .binary(size: (try? container.decode(Int.self, forKey: .size)) ?? 0)
        case "tooLarge":
            self = .tooLarge(size: (try? container.decode(Int.self, forKey: .size)) ?? 0)
        default:
            // Including an unrecognised kind: a future Mac describing a file in a
            // way this build has no screen for is still telling us it could not
            // be shown, which is what `unreadable` means.
            self = .unreadable(
                (try? container.decode(String.self, forKey: .message)) ?? "That file could not be shown."
            )
        }
    }
}
