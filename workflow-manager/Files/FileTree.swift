//
//  FileTree.swift
//  workflow-manager
//
//  Reading a working copy for display. Pure Foundation, read-only, no SwiftData
//  — nothing here creates, renames or deletes anything.
//
//  Children are listed on demand rather than walked up front. A repository with
//  `node_modules` in it holds hundreds of thousands of files, and eagerly
//  building that tree would hang the app on the first render for no benefit.
//

import Foundation

nonisolated enum FileTree {

    /// Directories that are never worth showing, and are usually enormous.
    ///
    /// Hidden entries are filtered separately, so `.git` is here only for the
    /// case where hidden files are being shown.
    static let ignoredDirectories: Set<String> = [
        ".git", "node_modules", ".build", ".xcbuild", "DerivedData",
        ".next", ".nuxt", "dist", "build", ".venv", "venv", "__pycache__",
        ".gradle", "Pods", ".swiftpm", ".turbo", ".parcel-cache",
    ]

    struct Node: Identifiable, Hashable, Sendable {
        let url: URL
        let name: String
        let isDirectory: Bool
        /// Bytes, for files only.
        let size: Int?

        var id: URL { url }

        /// The extension, lowercased and without the dot.
        var fileExtension: String {
            url.pathExtension.lowercased()
        }
    }

    /// One level of `directory`, directories first then files, each
    /// alphabetically — the order every file browser uses, because it makes a
    /// long list scannable.
    static func children(of directory: URL, showHidden: Bool = false) -> [Node] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isRegularFileKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else { return [] }

        var nodes: [Node] = []
        nodes.reserveCapacity(contents.count)

        for url in contents {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let name = url.lastPathComponent
            if isDirectory, ignoredDirectories.contains(name) { continue }

            nodes.append(
                Node(
                    url: url,
                    name: name,
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : values?.fileSize
                )
            )
        }

        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Reading a file

    /// Above this, a file is offered rather than shown. The preview builds an
    /// `AttributedString` over the whole text, which is linear in file size —
    /// a 40MB log would freeze the window.
    static let previewSizeLimit = 2 * 1024 * 1024

    enum Content: Sendable {
        case text(String)
        case image(Data)
        case binary(size: Int)
        case tooLarge(size: Int)
        case unreadable(String)
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "bmp", "tiff", "webp", "icns",
    ]

    static func read(_ url: URL) -> Content {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        if imageExtensions.contains(url.pathExtension.lowercased()) {
            guard size <= 20 * 1024 * 1024, let data = try? Data(contentsOf: url) else {
                return .tooLarge(size: size)
            }
            return .image(data)
        }

        guard size <= previewSizeLimit else { return .tooLarge(size: size) }

        guard let data = try? Data(contentsOf: url) else {
            return .unreadable("Could not read \(url.lastPathComponent).")
        }
        guard !looksBinary(data) else { return .binary(size: size) }

        if let text = String(data: data, encoding: .utf8) {
            return .text(text)
        }
        // Older files in a repository are often Latin-1 rather than broken.
        if let text = String(data: data, encoding: .isoLatin1) {
            return .text(text)
        }
        return .binary(size: size)
    }

    /// A NUL byte in the first few KB is the same heuristic `git` and `grep`
    /// use, and it is right far more often than sniffing extensions.
    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    static func formattedSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
