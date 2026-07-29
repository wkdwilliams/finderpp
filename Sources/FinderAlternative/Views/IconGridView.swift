import AppKit
import SwiftUI

struct IconGridView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @EnvironmentObject private var coordinator: FileOperationCoordinator
    @EnvironmentObject private var settings: AppSettings
    @State private var anchorID: FileItem.ID?
    @State private var renamingID: FileItem.ID?
    @State private var draftName: String = ""
    @State private var pendingCompressItems: [FileItem]?
    /// Manual double-click detection state — see `selectOnly`'s doc comment
    /// for why this replaces a competing `TapGesture(count: 2)`.
    @State private var lastClickedID: FileItem.ID?
    @State private var lastClickTime: Date = .distantPast
    /// Cell hit-rects for `GridDragMonitor`, recorded via
    /// `.onGeometryChange` below — a plain class (not `ObservableObject`)
    /// so per-scroll-frame writes never invalidate the view tree.
    @State private var frameRegistry = CellFrameRegistry()
    /// See `AppSettings`'s doc comment for why this is `.environmentObject`
    /// rather than `@AppStorage` directly.
    private var viewerScale: Double { settings.fileViewerScale }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 72 * viewerScale, maximum: 90 * viewerScale), spacing: 10 * viewerScale)]
    }

    /// `.sheet` is attached on this wrapper, not directly on `gridView`
    /// below — same reasoning as `FileListView`'s identical restructuring,
    /// see its doc comment (including the "not independently confirmed"
    /// caveat).
    var body: some View {
        gridView
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

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12 * viewerScale) {
                ForEach(viewModel.filteredItems) { item in
                    cell(for: item)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named("gridSpace"))
                        } action: { frame in
                            frameRegistry.frames[item.id] = frame
                        }
                        .onDisappear {
                            // LazyVGrid recycles offscreen cells — drop
                            // their rects so a stale one can't be hit.
                            frameRegistry.frames.removeValue(forKey: item.id)
                        }
                        .gesture(singleClickGesture(for: item))
                        .contextMenu {
                            fileContextMenu(
                                for: contextMenuSelection(for: item),
                                viewModel: viewModel,
                                coordinator: coordinator
                            ) { renamedItem in
                                beginRenaming(renamedItem)
                            } onCompress: { items in
                                pendingCompressItems = items
                            }
                        }
                }
            }
            .padding(12)
        }
        .coordinateSpace(name: "gridSpace")
        // Outgoing drag — see `GridDragMonitor` for the mechanism and why
        // it can never interfere with the tap-gesture selection above.
        .background(GridDragMonitor(
            registry: frameRegistry,
            payloadURLs: { hitID in dragPayloadURLs(hitID: hitID, viewModel: viewModel) },
            selectOnPress: { hitID in
                // Finder parity: pressing an unselected cell selects just
                // it immediately (at mouse-down, not release — the
                // TapGesture's on-release selection alone reads as lag).
                if !viewModel.selection.contains(hitID) {
                    viewModel.selection = [hitID]
                    anchorID = hitID
                }
            },
            canDrag: { renamingID == nil && !coordinator.isBlocking }
        ))
        .onChange(of: viewModel.currentDirectory) {
            frameRegistry.clear()
        }
        // Grid-level drop target — drops into currentDirectory regardless of
        // which cell they land on. Incoming drops (from Finder or the other
        // pane's outgoing drag) work via this.
        .dropDestination(for: URL.self) { urls, _ in
            performDrop(urls: urls, destination: viewModel.currentDirectory, viewModel: viewModel, coordinator: coordinator)
            return true
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

    /// Right-clicking a cell that's part of the current multi-selection
    /// acts on the whole selection (matching `Table`'s native behavior);
    /// right-clicking outside it acts on just that cell.
    private func contextMenuSelection(for item: FileItem) -> Set<FileItem.ID> {
        viewModel.selection.contains(item.id) ? viewModel.selection : [item.id]
    }

    /// Composes command/shift/plain single-click behavior via required
    /// gesture modifiers, tried in that order via `.exclusively(before:)` —
    /// `Table` gets ⌘/Shift multi-select natively, `LazyVGrid` doesn't, so
    /// this reimplements it. Deliberately only ever uses `TapGesture(count:
    /// 1)` — mixing a `count: 1` and a `count: 2` gesture on the same view
    /// forces SwiftUI to wait out the double-click window before it can
    /// commit to firing the single-tap action (it can't know yet whether a
    /// second tap is coming), which showed up as a visible selection delay
    /// specific to this view. `Table`'s selection doesn't have this problem
    /// because AppKit selects immediately on click and treats double-click
    /// as a separate, non-blocking `primaryAction` callback — `selectOnly`
    /// below replicates that by detecting the "second click" itself instead
    /// of relying on a competing gesture recognizer.
    private func singleClickGesture(for item: FileItem) -> some Gesture {
        let commandClick = TapGesture(count: 1)
            .modifiers(.command)
            .onEnded { toggleSelection(item) }
        let shiftClick = TapGesture(count: 1)
            .modifiers(.shift)
            .onEnded { extendSelection(to: item) }
        let plainClick = TapGesture(count: 1)
            .onEnded { selectOnly(item) }
        return commandClick.exclusively(before: shiftClick.exclusively(before: plainClick))
    }

    private func selectOnly(_ item: FileItem) {
        let now = Date()
        let isDoubleClick = lastClickedID == item.id
            && now.timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval
        lastClickedID = item.id
        lastClickTime = now

        if isDoubleClick {
            viewModel.open(item, coordinator: coordinator)
            return
        }
        viewModel.selection = [item.id]
        anchorID = item.id
    }

    private func toggleSelection(_ item: FileItem) {
        if viewModel.selection.contains(item.id) {
            viewModel.selection.remove(item.id)
        } else {
            viewModel.selection.insert(item.id)
        }
        anchorID = item.id
    }

    private func extendSelection(to item: FileItem) {
        let all = viewModel.filteredItems
        guard let anchorID,
              let anchorIndex = all.firstIndex(where: { $0.id == anchorID }),
              let targetIndex = all.firstIndex(where: { $0.id == item.id }) else {
            selectOnly(item)
            return
        }
        let range = anchorIndex < targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        viewModel.selection = Set(all[range].map(\.id))
    }

    /// Outgoing drag deliberately does NOT live here on the cell. SwiftUI
    /// `.draggable` was attached here (gated on a delayed "armed" set) and
    /// removed three times over — it intercepts `mouseDown` to watch for a
    /// drag threshold and ate plain selection taps (repro: select A,
    /// select B, tap back on A shortly after), and no delay/debounce
    /// tuning ever fully fixed it. Outgoing drag now works via
    /// `GridDragMonitor` (attached at the ScrollView level above), a
    /// passive event monitor that never consumes events and so can't
    /// interfere with the tap gestures — see that type's doc comment. Do
    /// not reintroduce `.draggable`/`.onDrag` here.
    private func cell(for item: FileItem) -> some View {
        VStack(spacing: 3 * viewerScale) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 38 * viewerScale, height: 38 * viewerScale)
            if renamingID == item.id {
                TextField("Name", text: $draftName)
                    .font(.system(size: 10 * viewerScale))
                    .multilineTextAlignment(.center)
                    .onSubmit { commitRename(item) }
                    .onKeyPress(.escape) { renamingID = nil; return .handled }
            } else {
                Text(item.name)
                    .font(.system(size: 10 * viewerScale))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(5 * viewerScale)
        .frame(width: 78 * viewerScale)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(viewModel.selection.contains(item.id) ? Color.accentColor.opacity(0.25) : Color.clear)
        )
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
}
