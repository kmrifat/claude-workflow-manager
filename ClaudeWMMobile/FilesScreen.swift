//
//  FilesScreen.swift
//  ClaudeWMMobile
//
//  The linked repository, read-only, one directory at a time.
//
//  Lazy for the same reason the Mac's browser is: a repository with
//  `node_modules` holds hundreds of thousands of files, and the wire is Wi-Fi. A
//  directory is asked for when it is opened and not before.
//
//  It cannot edit, create, rename or delete, and there is no message on the wire
//  for any of those — the restriction is in the protocol, not in this screen.
//

import SwiftUI
import ClaudeWMWire

struct FilesScreen: View {
    let connection: BoardConnection

    var body: some View {
        NavigationStack {
            Group {
                if let refusal = connection.repositoryAccessRefused {
                    ContentUnavailableView {
                        Label("Files are off", systemImage: "lock")
                    } description: {
                        Text(refusal)
                    }
                } else if !connection.state.isConnected {
                    ContentUnavailableView(
                        "Not connected",
                        systemImage: "wifi.exclamationmark",
                        description: Text("Your Mac isn’t reachable right now.")
                    )
                } else {
                    DirectoryView(path: "", name: "Repository", connection: connection)
                }
            }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - One directory

/// Recursive by construction: opening a folder pushes another of these.
///
/// Each instance owns the listing for its own path, so going back does not
/// re-fetch and two levels cannot overwrite each other's entries — which is what
/// a single shared list in the connection would do while a slow directory was
/// still loading.
private struct DirectoryView: View {
    let path: String
    let name: String
    let connection: BoardConnection

    @State private var entries: [WireFileNode] = []
    @State private var isLoading = true

    var body: some View {
        List {
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink {
                        DirectoryView(path: entry.path, name: entry.name, connection: connection)
                    } label: {
                        row(entry)
                    }
                } else {
                    NavigationLink {
                        FileView(path: entry.path, name: entry.name, connection: connection)
                    } label: {
                        row(entry)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if isLoading {
                ProgressView()
            } else if entries.isEmpty {
                ContentUnavailableView("Empty", systemImage: "folder")
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { load() }
        .onAppear(perform: load)
    }

    private func row(_ entry: WireFileNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : icon(for: entry.name))
                .foregroundStyle(entry.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 20)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let size = entry.size, !entry.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func load() {
        isLoading = true
        // The reply is matched on its path: two directories can be in flight
        // when someone taps quickly, and answering the wrong one puts a
        // folder's contents under another folder's name.
        connection.onDirectory = { replyPath, replyEntries in
            guard replyPath == path else { return }
            entries = replyEntries
            isLoading = false
        }
        connection.listDirectory(path)
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift":                            "swift"
        case "md", "markdown", "txt":            "doc.text"
        case "json", "yml", "yaml", "toml":      "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": "photo"
        case "sh", "zsh", "bash":                "terminal"
        default:                                 "doc"
        }
    }
}

// MARK: - One file

private struct FileView: View {
    let path: String
    let name: String
    let connection: BoardConnection

    @State private var content: WireFileContent?

    var body: some View {
        Group {
            switch content {
            case .text(let text):
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            case .image(let data):
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                } else {
                    ContentUnavailableView("Can’t show this image", systemImage: "photo")
                }
            case .binary(let size):
                unavailable("Binary file", size: size, symbol: "doc.badge.gearshape")
            case .tooLarge(let size):
                unavailable("Too large to preview", size: size, symbol: "doc.badge.ellipsis")
            case .unreadable(let reason):
                ContentUnavailableView("Can’t read this file", systemImage: "exclamationmark.triangle", description: Text(reason))
            case nil:
                ProgressView()
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            connection.onFileContent = { replyPath, replyContent in
                guard replyPath == path else { return }
                content = replyContent
            }
            connection.readFile(path)
        }
    }

    private func unavailable(_ title: String, size: Int, symbol: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: symbol,
            description: Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        )
    }
}
