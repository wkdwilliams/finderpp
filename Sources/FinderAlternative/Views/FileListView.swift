import AppKit
import SwiftUI

struct FileListView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @EnvironmentObject private var coordinator: FileOperationCoordinator
    @EnvironmentObject private var settings: AppSettings
    /// See `RenameState` for why this isn't plain `@State`.
    @StateObject private var rename = RenameState()
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
        // Outgoing drag — see `TableDragBridge` for the mechanism and the
        // history of why it must never touch the click path.
        .background(TableDragBridge(
            urlForRow: { row in
                viewModel.filteredItems.indices.contains(row) ? viewModel.filteredItems[row].url : nil
            },
            canDrag: { !rename.isRenaming && !coordinator.isBlocking },
            selectRow: { row in
                guard viewModel.filteredItems.indices.contains(row) else { return }
                let id = viewModel.filteredItems[row].id
                // Only plain presses on rows OUTSIDE the current selection —
                // pressing inside a multi-selection must not collapse it
                // (that's deferred to mouse-up natively, so it can be
                // dragged whole).
                if !viewModel.selection.contains(id) {
                    viewModel.selection = [id]
                }
            },
            // Finder's click-a-selected-row-again-to-rename trigger. Runs
            // before `selectRow`, so `viewModel.selection` still holds what
            // was selected *before* this click.
            pressedRow: { row, clickCount in
                rename.cancelPending()
                guard clickCount == 1, viewModel.filteredItems.indices.contains(row) else { return }
                let item = viewModel.filteredItems[row]
                guard viewModel.selection == [item.id] else { return }
                rename.scheduleFromClick(on: item)
            }
        ))
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            fileContextMenu(for: ids, viewModel: viewModel, coordinator: coordinator) { item in
                rename.begin(item)
            } onCompress: { items in
                pendingCompressItems = items
            } onError: { message in
                rename.errorMessage = message
            }
        } primaryAction: { ids in
            openItems(ids)
        }
        .onKeyPress(.return) {
            guard !rename.isRenaming, viewModel.selection.count == 1,
                  let item = viewModel.selectedItems.first else { return .ignored }
            rename.begin(item)
            return .handled
        }
        // Safety net for the same stuck-rename problem as the field's
        // focus watcher, for the paths where the field never took focus
        // to begin with (window not key, focus stolen by another pane).
        .onChange(of: viewModel.selection) { _, selection in
            rename.cancelPending()
            if let id = rename.renamingID, !selection.contains(id) { rename.cancel() }
        }
        // Keyboard navigation, a directory change, or anything else that
        // moves the ground under a pending click-to-rename disarms it.
        .onChange(of: viewModel.currentDirectory) { rename.cancel() }
        .onKeyPress(.space) {
            guard !rename.isRenaming, !viewModel.selectedItems.isEmpty else { return .ignored }
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
        .alert("Couldn’t Rename", isPresented: Binding(
            get: { rename.errorMessage != nil },
            set: { if !$0 { rename.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { rename.errorMessage = nil }
        } message: {
            Text(rename.errorMessage ?? "")
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

    /// Outgoing drag deliberately does NOT live here on the cell content.
    /// SwiftUI `.draggable` was attached here (gated on a delayed "armed"
    /// set) and removed three times over — it intercepts `mouseDown` to
    /// watch for a drag threshold and ate plain selection clicks (repro:
    /// select A, select B, click back on A shortly after), and no
    /// delay/debounce tuning ever fully fixed it. Outgoing drag now works
    /// via `TableDragBridge` (attached at the `Table` level above), which
    /// interposes the backing `NSTableView`'s dataSource so AppKit's own
    /// native click-vs-drag machinery runs instead — see that type's doc
    /// comment. Do not reintroduce `.draggable`/`.onDrag` here.
    private func nameCell(for item: FileItem) -> some View {
        NameCell(item: item, rename: rename, scale: viewerScale) { newName in
            commitRename(item, to: newName)
        }
    }

    private func commitRename(_ item: FileItem, to newName: String) {
        defer { rename.cancel() }
        guard !newName.isEmpty, newName != item.name else { return }
        do {
            let renamed = try FileSystemService.rename(item.url, to: newName)
            viewModel.reload()
            viewModel.selection = [renamed.path]
        } catch {
            rename.errorMessage = RenameState.failureMessage(from: item.name, to: newName, error: error)
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

/// A real `View` (not a `@ViewBuilder` method on `FileListView`) so it can
/// hold `@ObservedObject`/`@FocusState` of its own — that observation is
/// what makes the cell swap to the rename field, since `Table` won't re-run
/// the column's cell closure for an unchanged row. See `RenameState`.
private struct NameCell: View {
    let item: FileItem
    @ObservedObject var rename: RenameState
    let scale: Double
    let onCommit: (String) -> Void
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            icon
            if rename.renamingID == item.id {
                TextField("Name", text: $rename.draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11 * scale))
                    .focused($isFieldFocused)
                    .onSubmit { onCommit(rename.draftName) }
                    .onKeyPress(.escape) { rename.cancel(); return .handled }
                    // The field doesn't exist yet when the rename starts, and
                    // the context menu is still tearing down its own
                    // first-responder state in that frame — taking focus one
                    // run-loop turn after the field is real is what actually
                    // makes it editable.
                    .onAppear {
                        DispatchQueue.main.async {
                            isFieldFocused = true
                            RenameState.selectBaseName(of: rename.draftName)
                        }
                    }
                    // Clicking away (another row, another pane, the toolbar)
                    // ends the rename instead of leaving the row stuck in
                    // edit mode — otherwise the field is still armed when the
                    // row is clicked again later and rename re-triggers itself
                    // out of nowhere.
                    .onChange(of: isFieldFocused) { _, focused in
                        if !focused, rename.renamingID == item.id { rename.cancel() }
                    }
            } else {
                Text(item.name)
                    .font(.system(size: 11 * scale, weight: .bold))
            }
        }
    }

    /// Folders keep the plain SF Symbol — files get the real icon macOS
    /// resolves for that file (`NSWorkspace.icon(forFile:)`, same as
    /// `IconGridView`): the icon of whatever app is registered to open it,
    /// e.g. an `.mp4` shows VLC's icon if VLC is the default player,
    /// instead of one generic document placeholder for every file type.
    @ViewBuilder
    private var icon: some View {
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
        .frame(width: 14 * scale, height: 14 * scale)
    }
}
