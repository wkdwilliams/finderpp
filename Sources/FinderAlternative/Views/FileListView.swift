import AppKit
import SwiftUI

struct FileListView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @EnvironmentObject private var coordinator: FileOperationCoordinator
    @EnvironmentObject private var settings: AppSettings
    @State private var renamingID: FileItem.ID?
    @State private var draftName: String = ""
    @State private var pendingCompressItems: [FileItem]?
    /// See `AppSettings`'s doc comment for why this is `.environmentObject`
    /// rather than `@AppStorage` directly.
    private var viewerScale: Double { settings.fileViewerScale }

    /// `.sheet` is attached on this wrapper, not directly on `tableView`
    /// below. Compress is the only file operation that presents a `.sheet`
    /// (copy/move/trash/rename don't) and the only one reported to leave
    /// clicking broken afterward (arrow-key navigation still works) — a
    /// `.sheet` chained directly onto the same view that hosts a
    /// `Table`/`List` is a known SwiftUI-macOS interaction where the
    /// table's responder/click-handling doesn't get properly restored
    /// post-dismissal, and moving the sheet one level up in the view
    /// hierarchy is the standard fix. Not independently confirmed against a
    /// live click in this repo — if selection still breaks after
    /// compressing, this wasn't the whole story.
    var body: some View {
        tableView
            .sheet(isPresented: Binding(
                get: { pendingCompressItems != nil },
                set: { isPresented in if !isPresented { pendingCompressItems = nil } }
            )) {
                if let pendingCompressItems {
                    CompressSheet(items: pendingCompressItems, destinationDirectory: viewModel.currentDirectory) {
                        viewModel.reload()
                    }
                }
            }
    }

    private var tableView: some View {
        Table(viewModel.filteredItems, selection: $viewModel.selection, sortOrder: sortOrderBinding) {
            TableColumn("Name", value: \.name) { item in
                nameCell(for: item)
            }
            TableColumn("Size", value: \.sortableSize) { item in
                Text(sizeString(for: item)).font(.system(size: 11 * viewerScale, weight: .bold))
            }
            TableColumn("Modified", value: \.sortableModificationDate) { item in
                Text(dateString(for: item)).font(.system(size: 11 * viewerScale, weight: .bold))
            }
        }
        .controlSize(.small)
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            fileContextMenu(for: ids, viewModel: viewModel, coordinator: coordinator) { item in
                beginRenaming(item)
            } onCompress: { items in
                pendingCompressItems = items
            }
        } primaryAction: { ids in
            openItems(ids)
        }
        .onKeyPress(.return) {
            guard renamingID == nil, viewModel.selection.count == 1,
                  let item = viewModel.selectedItems.first else { return .ignored }
            beginRenaming(item)
            return .handled
        }
        .onKeyPress(.space) {
            guard renamingID == nil, !viewModel.selectedItems.isEmpty else { return .ignored }
            QuickLookCoordinator.shared.toggle(for: viewModel.selectedItems.map(\.url))
            return .handled
        }
        // Table-level drop target for the whole pane — drops into
        // currentDirectory regardless of which row they land on. Incoming
        // drops (from Finder, or a pane's own outgoing drag when that
        // existed) still work; only outgoing drag was removed — see
        // `nameCell`'s doc comment.
        .dropDestination(for: URL.self) { urls, _ in
            performDrop(urls: urls, destination: viewModel.currentDirectory, viewModel: viewModel, coordinator: coordinator)
            return true
        }
        .confirmationDialog(
            "Delete \(viewModel.pendingPermanentDelete.count) item\(viewModel.pendingPermanentDelete.count == 1 ? "" : "s") permanently?",
            isPresented: Binding(
                get: { !viewModel.pendingPermanentDelete.isEmpty },
                set: { isPresented in if !isPresented { viewModel.pendingPermanentDelete = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                let urls = viewModel.pendingPermanentDelete
                viewModel.pendingPermanentDelete = []
                coordinator.deletePermanently(urls) { viewModel.reload() }
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingPermanentDelete = []
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    /// `Table`'s own header-click cycling defaults to ascending-first,
    /// which is the opposite of what was asked for (descending-first —
    /// see `FileBrowserViewModel.toggleSort`). Rather than fight that,
    /// this binding's getter always returns the order *we* computed from
    /// `viewModel.sortField`/`sortAscending` (so the header arrow always
    /// matches our actual state), while the setter only uses whatever
    /// `Table` reports to figure out *which column* was clicked — the
    /// direction Table decided is discarded, `toggleSort` applies our own.
    private var sortOrderBinding: Binding<[KeyPathComparator<FileItem>]> {
        Binding(
            get: {
                switch viewModel.sortField {
                case .name:
                    return [KeyPathComparator(\FileItem.name, order: viewModel.sortAscending ? .forward : .reverse)]
                case .size:
                    return [KeyPathComparator(\FileItem.sortableSize, order: viewModel.sortAscending ? .forward : .reverse)]
                case .modified:
                    return [KeyPathComparator(\FileItem.sortableModificationDate, order: viewModel.sortAscending ? .forward : .reverse)]
                }
            },
            set: { newOrder in
                guard let clickedKeyPath = newOrder.first?.keyPath else { return }
                switch clickedKeyPath {
                case \FileItem.name:
                    viewModel.toggleSort(.name)
                case \FileItem.sortableSize:
                    viewModel.toggleSort(.size)
                case \FileItem.sortableModificationDate:
                    viewModel.toggleSort(.modified)
                default:
                    break
                }
            }
        )
    }

    /// Outgoing drag (`.draggable`) used to be attached here, gated on a
    /// delayed "armed" set to avoid intercepting plain clicks. Removed
    /// entirely: `.draggable` intercepts `mouseDown` to watch for a drag
    /// threshold, and no amount of delay/debounce tuning around *when* it
    /// attaches eliminated cases where a still- or newly-armed row's click
    /// got eaten instead of registering as a selection (confirmed via
    /// repeated live repro — e.g. select A, select B, click back on A
    /// shortly after). Pane-to-pane transfer now only works via Copy/Paste
    /// (⌘C/⌘V/⌥⌘V from `FileContextMenu`) — incoming drops (from Finder, or
    /// any future outgoing-drag source) still work via `.dropDestination`
    /// below. See `CLAUDE.md` for the full history; an AppKit-interop
    /// `NSViewRepresentable` table would be the real fix if outgoing drag
    /// is needed again.
    @ViewBuilder
    private func nameCell(for item: FileItem) -> some View {
        if renamingID == item.id {
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 11 * viewerScale))
                .onSubmit { commitRename(item) }
                .onKeyPress(.escape) { renamingID = nil; return .handled }
        } else {
            HStack(spacing: 4) {
                icon(for: item)
                Text(item.name)
            }
            .font(.system(size: 11 * viewerScale, weight: .bold))
        }
    }

    /// Folders keep the plain SF Symbol — files get the real icon macOS
    /// resolves for that file (`NSWorkspace.icon(forFile:)`, same as
    /// `IconGridView`): the icon of whatever app is registered to open it,
    /// e.g. an `.mp4` shows VLC's icon if VLC is the default player,
    /// instead of one generic document placeholder for every file type.
    @ViewBuilder
    private func icon(for item: FileItem) -> some View {
        Group {
            if item.isDirectory {
                Image(systemName: "folder")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 14 * viewerScale, height: 14 * viewerScale)
    }

    private func beginRenaming(_ item: FileItem) {
        draftName = item.name
        renamingID = item.id
    }

    private func commitRename(_ item: FileItem) {
        defer { renamingID = nil }
        guard !draftName.isEmpty, draftName != item.name else { return }
        do {
            let renamed = try FileSystemService.rename(item.url, to: draftName)
            viewModel.reload()
            viewModel.selection = [renamed.path]
        } catch {
            viewModel.reload()
        }
    }

    private func openItems(_ ids: Set<FileItem.ID>) {
        for id in ids {
            if let item = viewModel.items.first(where: { $0.id == id }) {
                viewModel.open(item, coordinator: coordinator)
            }
        }
    }

    private func sizeString(for item: FileItem) -> String {
        guard !item.isDirectory, let size = item.size else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func dateString(for item: FileItem) -> String {
        guard let date = item.modificationDate else { return "--" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
