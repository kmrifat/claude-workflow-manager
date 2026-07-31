//
//  FilesView.swift
//  workflow-manager
//
//  A read-only look at the working copy: a tree on the left, the selected file
//  on the right.
//
//  Deliberately small. It does not edit, create, rename or delete — the app has
//  no business writing into a repository through a file browser, and an editor
//  that silently disagrees with the one you actually use is worse than no
//  editor. What it is for is answering "what is in here" without leaving the
//  window.
//

import SwiftUI

struct FilesView: View {
    let root: URL
    var accent: Color = .accentColor

    /// Tree expansion and the open file live in a per-repository session held by
    /// an app-level store, so they survive both a tab switch (which tears this
    /// view down) and a project switch (which recreates the whole detail view).
    @Environment(FilesStateStore.self) private var store

    @State private var content: FileTree.Content?
    @State private var isLoading = false
    /// Bumped to force the preview to re-read the selected file from disk.
    @State private var reloadToken = 0

    /// The persistent state for this repository. Cheap to fetch — the store
    /// hands back the same instance every time for a given root.
    private var session: FilesSession { store.session(for: root) }

    private var selection: Binding<URL?> {
        Binding(get: { session.selection }, set: { session.selection = $0 })
    }

    var body: some View {
        // Same reason as `TerminalView`: the empty states size to their content,
        // so without an explicit fill the split view collapses and is centred.
        HSplitView {
            tree
                .frame(minWidth: 200, idealWidth: 260, maxWidth: 420, maxHeight: .infinity)
            preview
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
        .task(id: root) {
            // The root always appears, so this reliably seeds the top level.
            session.tree.loadIfNeeded(root)
        }
        .task(id: TaskKey(url: session.selection, token: reloadToken)) {
            await loadSelection()
        }
    }

    /// `.task(id:)` needs one comparable value, and the preview has to reload
    /// both when the selection changes and when the tree is refreshed.
    private struct TaskKey: Equatable {
        let url: URL?
        let token: Int
    }

    // MARK: - Tree

    private var tree: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(accent)
                Text(root.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                Menu {
                    Toggle(
                        "Show Hidden Files",
                        isOn: Binding(
                            get: { session.tree.showHidden },
                            set: { session.tree.showHidden = $0 }
                        )
                    )
                    Button("Refresh") {
                        session.tree.refresh()
                        reloadToken += 1
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            List(selection: selection) {
                DirectoryContents(directory: root, accent: accent, model: session.tree)
            }
            .listStyle(.sidebar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        if let selection = session.selection {
            VStack(spacing: 0) {
                previewHeader(for: selection)
                Divider()

                Group {
                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        switch content {
                        case .text(let text):
                            FilePreviewText(text: text, url: selection)
                        case .image(let data):
                            imagePreview(data)
                        case .binary(let size):
                            unavailable(
                                "Binary File",
                                systemImage: "doc.badge.gearshape",
                                detail: "\(FileTree.formattedSize(size)) of binary data.",
                                url: selection
                            )
                        case .tooLarge(let size):
                            unavailable(
                                "Too Large to Preview",
                                systemImage: "doc.badge.ellipsis",
                                detail: "\(FileTree.formattedSize(size)). The preview stops at \(FileTree.formattedSize(FileTree.previewSizeLimit)).",
                                url: selection
                            )
                        case .unreadable(let message):
                            unavailable(
                                "Couldn’t Read File",
                                systemImage: "exclamationmark.triangle",
                                detail: message,
                                url: selection
                            )
                        case nil:
                            Color.clear
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            }
        } else {
            ContentUnavailableView {
                Label("No File Selected", systemImage: "doc.text")
            } description: {
                Text("Pick a file on the left to read it.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewHeader(for url: URL) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                Text(relativePath(of: url))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            if case .text(let text) = content {
                Text("\(text.reduce(into: 1) { count, c in if c == "\n" { count += 1 } }) lines")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open in the default app")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func imagePreview(_ data: Data) -> some View {
        Group {
            if let image = NSImage(data: data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 900)
                        .padding(20)
                }
            } else {
                unavailable(
                    "Couldn’t Decode Image",
                    systemImage: "photo",
                    detail: "\(FileTree.formattedSize(data.count)) that macOS could not read as an image.",
                    url: nil
                )
            }
        }
    }

    private func unavailable(
        _ title: String,
        systemImage: String,
        detail: String,
        url: URL?
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            if let url {
                Button("Open in Default App") { NSWorkspace.shared.open(url) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func relativePath(of url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let rootPath = root.path(percentEncoded: false)
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func loadSelection() async {
        guard let url = session.selection else {
            content = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        // Reading and sniffing happen off the main actor — a 2MB file on a slow
        // disk should not stall a frame.
        content = await Task.detached(priority: .userInitiated) {
            FileTree.read(url)
        }.value
    }
}

/// Everything about one repository's Files view that must outlive the view:
/// which folders are open (in `tree`) and which file is being read.
@MainActor
@Observable
final class FilesSession {
    let root: URL
    let tree = FileTreeModel()
    var selection: URL?

    init(root: URL) { self.root = root }
}

/// One session per repository root, kept alive above the detail view so that
/// leaving the Files view — by switching tabs or projects — and returning shows
/// exactly what was left open. In memory only: it restores within a run, not
/// across relaunches.
@MainActor
@Observable
final class FilesStateStore {
    // Not observed: sessions are looked up during `body`, and each session is
    // observed on its own. Publishing dictionary inserts would mean mutating
    // observed state mid-render.
    @ObservationIgnored private var sessions: [URL: FilesSession] = [:]

    func session(for root: URL) -> FilesSession {
        if let existing = sessions[root] { return existing }
        let created = FilesSession(root: root)
        sessions[root] = created
        return created
    }
}

/// Loads and caches the tree one directory at a time, keyed by URL.
///
/// The mutable state lives here rather than in each row's `@State` on purpose. A
/// row's `.task` fires when the row *appears*, but a freshly expanded folder
/// starts with no rows, so the loader had nothing on screen to fire from — the
/// contents only showed up once some unrelated change (toggling hidden files)
/// forced a re-read. Here, loading is driven by expansion, which is a user
/// action, and by the root view's own `.task`, both of which always run.
///
/// Recursive by demand rather than by pre-walking the tree: a repository with
/// `node_modules` has hundreds of thousands of files, and only the folders
/// actually opened should ever be read.
@MainActor
@Observable
final class FileTreeModel {
    var showHidden = false {
        didSet { if showHidden != oldValue { reloadLoaded() } }
    }

    private(set) var childrenByURL: [URL: [FileTree.Node]] = [:]
    private var expanded: Set<URL> = []
    private var loading: Set<URL> = []

    func children(of directory: URL) -> [FileTree.Node] {
        childrenByURL[directory] ?? []
    }

    func isExpanded(_ directory: URL) -> Bool { expanded.contains(directory) }

    func setExpanded(_ directory: URL, _ value: Bool) {
        if value {
            expanded.insert(directory)
            loadIfNeeded(directory)
        } else {
            expanded.remove(directory)
        }
    }

    /// Reads `directory` unless it is already loaded. The initial root read and
    /// every folder expansion come through here.
    func loadIfNeeded(_ directory: URL) {
        guard childrenByURL[directory] == nil else { return }
        load(directory)
    }

    /// Re-reads every directory read so far, keeping expansion intact. Used when
    /// hidden files are toggled or the tree is refreshed.
    func refresh() { reloadLoaded() }

    private func reloadLoaded() {
        for directory in childrenByURL.keys { load(directory) }
    }

    private func load(_ directory: URL) {
        guard !loading.contains(directory) else { return }
        loading.insert(directory)
        let hidden = showHidden
        Task {
            let nodes = await Task.detached(priority: .userInitiated) {
                FileTree.children(of: directory, showHidden: hidden)
            }.value
            childrenByURL[directory] = nodes
            loading.remove(directory)
        }
    }
}

/// One directory's rows. Reads its children from the shared model, so an
/// expanded folder shows its contents as soon as the model finishes reading it.
private struct DirectoryContents: View {
    let directory: URL
    let accent: Color
    let model: FileTreeModel

    var body: some View {
        ForEach(model.children(of: directory)) { node in
            if node.isDirectory {
                DisclosureGroup(isExpanded: expansion(for: node.url)) {
                    DirectoryContents(directory: node.url, accent: accent, model: model)
                } label: {
                    Label(node.name, systemImage: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(accent)
                }
            } else {
                Label {
                    Text(node.name).font(.system(size: 12))
                } icon: {
                    Image(systemName: icon(for: node))
                        .foregroundStyle(.secondary)
                }
                .tag(node.url)
            }
        }
    }

    private func expansion(for url: URL) -> Binding<Bool> {
        Binding(
            get: { model.isExpanded(url) },
            set: { model.setExpanded(url, $0) }
        )
    }

    private func icon(for node: FileTree.Node) -> String {
        if FileTree.imageExtensions.contains(node.fileExtension) { return "photo" }
        switch node.fileExtension {
        case "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs",
             "java", "kt", "c", "h", "cpp", "m", "mm":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "plist", "xml":
            return "curlybraces"
        case "md", "markdown", "txt":
            return "doc.text"
        case "sh", "bash", "zsh":
            return "terminal"
        default:
            return "doc"
        }
    }
}
