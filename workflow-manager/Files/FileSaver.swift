//
//  FileSaver.swift
//  workflow-manager
//
//  Writing a file the Files view edited, without the three ways an editor
//  quietly destroys work:
//
//  - **Saving over someone else's change.** Before writing, the file on disk is
//    compared with what was loaded. If an editor, `git checkout` or Claude has
//    changed it since, the save stops and says so; overwriting is a second,
//    explicit choice.
//  - **Saving a file that was only partly read.** Only `.text` content is ever
//    editable, and that is the whole file — `FileTree.read` refuses anything
//    over the preview cap rather than truncating it.
//  - **Losing what the file was.** The write is atomic (a crash leaves the old
//    file, never half a new one), keeps the file's permissions — an atomic
//    write replaces the inode, which would otherwise drop a script's execute
//    bit — and goes to a symlink's target rather than replacing the link.
//

import Foundation

enum FileSaver {
    enum Failure: Error, Equatable {
        /// The file is no longer what was loaded.
        case changedOnDisk
        /// The file is gone.
        case missing
        /// The text has characters the file's encoding cannot hold.
        case cannotEncode(String.Encoding)
        case writeFailed(String)

        var message: String {
            switch self {
            case .changedOnDisk:
                "The file changed on disk since you opened it."
            case .missing:
                "The file is no longer there."
            case .cannotEncode(let encoding):
                "It is saved as \(encoding == .isoLatin1 ? "Latin-1" : "\(encoding)"), which cannot hold some of what you typed."
            case .writeFailed(let reason):
                reason
            }
        }
    }

    /// Writes `text` to `url` in `encoding`, provided the file still holds
    /// `expected`. Pass `force` to write regardless — after the user chose to
    /// overwrite a change made elsewhere.
    static func save(_ text: String, to url: URL, encoding: String.Encoding,
                     expected: String, force: Bool = false) throws {
        let target = url.resolvingSymlinksInPath()
        let manager = FileManager.default
        guard manager.fileExists(atPath: target.path(percentEncoded: false)) || force else {
            throw Failure.missing
        }
        if !force {
            guard let onDisk = try? Data(contentsOf: target) else { throw Failure.missing }
            // Compared as bytes, in the file's own encoding: UTF-8 and Latin-1
            // both round-trip exactly, so this is the file as it was read.
            guard onDisk == expected.data(using: encoding) else { throw Failure.changedOnDisk }
        }
        guard let data = text.data(using: encoding, allowLossyConversion: false) else {
            throw Failure.cannotEncode(encoding)
        }

        let permissions = (try? manager.attributesOfItem(atPath: target.path(percentEncoded: false)))?[.posixPermissions]
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
        if let permissions {
            try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path(percentEncoded: false))
        }
    }
}
