import AppKit
import Foundation

@MainActor
final class FileBrowserViewModel: ObservableObject {
    @Published var currentDirectory: URL
    @Published var items: [FileItem] = []
    @Published var selection: Set<FileItem.ID> = []
    @Published var filterText: String = ""
    @Published private(set) var sortField: SortField = .name
    @Published private(set) var sortAscending = true

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Directories are always grouped before files, matching Finder;
    /// `sortField`/`sortAscending` only changes the order *within* each
    /// group. Applies to both `FileListView` (whose column headers drive
    /// `toggleSort`) and `IconGridView` (which has no headers of its own
    /// but shares the same underlying order).
    var filteredItems: [FileItem] {
        let base = filterText.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        let directories = base.filter(\.isDirectory)
        let files = base.filter { !$0.isDirectory }
        return sorted(directories) + sorted(files)
    }

    /// Falls back to a by-name tie-break when the primary field is equal
    /// (e.g. every directory shares the same `sortableSize` of `-1`) —
    /// `Array.sorted(by:)` isn't a stable sort, so without this, tied
    /// items could reshuffle arbitrarily between sorts instead of holding
    /// a consistent, predictable order.
    private func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            let ascendingOrder: Bool
            switch sortField {
            case .name:
                ascendingOrder = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                ascendingOrder = lhs.sortableSize != rhs.sortableSize
                    ? lhs.sortableSize < rhs.sortableSize
                    : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .modified:
                ascendingOrder = lhs.sortableModificationDate != rhs.sortableModificationDate
                    ? lhs.sortableModificationDate < rhs.sortableModificationDate
                    : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return sortAscending ? ascendingOrder : !ascendingOrder
        }
    }

    /// First click on a column sorts descending, second click ascending —
    /// deliberately the reverse of the usual ascending-first spreadsheet
    /// convention, per explicit request. Clicking a *different* column
    /// always starts that column back at descending.
    func toggleSort(_ field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = false
        }
    }

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.id) }
    }

    /// Drives a `.confirmationDialog` in the hosting view — permanent
    /// deletion is irreversible, unlike Trash, so it needs explicit
    /// confirmation before `FileOperationCoordinator.deletePermanently` runs.
    @Published var pendingPermanentDelete: [URL] = []

    // `nonisolated(unsafe)` solely so the nonisolated `deinit` can remove
    // it — it's only ever written once, in `init`.
    private nonisolated(unsafe) var dropCompletionObserver: (any NSObjectProtocol)?

    init(startingAt url: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentDirectory = url
        reload()
        // A pane-to-pane drag changes both panes' directories, but the drop
        // completion handler only knows the destination pane — so every
        // pane reloads on this notification instead (see `performDrop`).
        dropCompletionObserver = NotificationCenter.default.addObserver(
            forName: .fileDropOperationDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    deinit {
        if let dropCompletionObserver {
            NotificationCenter.default.removeObserver(dropCompletionObserver)
        }
    }

    func reload() {
        items = FileSystemService.contents(of: currentDirectory)
    }

    /// Pushes `currentDirectory` onto the back stack and clears the forward
    /// stack, matching browser-style history: forward is only valid until
    /// the next fresh navigation.
    func navigate(to url: URL) {
        guard url.path != currentDirectory.path else { return }
        backStack.append(currentDirectory)
        forwardStack.removeAll()
        currentDirectory = url
        selection = []
        filterText = ""
        reload()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentDirectory)
        currentDirectory = previous
        selection = []
        filterText = ""
        reload()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentDirectory)
        currentDirectory = next
        selection = []
        filterText = ""
        reload()
    }

    /// A `.app` bundle is a directory on disk but opening one should launch
    /// it, not navigate into it like a regular folder — matches Finder's
    /// own double-click behavior. `FileContextMenu`'s "Show Package
    /// Contents" is the explicit escape hatch for actually browsing inside
    /// one. A recognized archive (see `CompressionFormat.detect`) is
    /// extracted into a uniquely-named folder under `/tmp` and that folder
    /// is opened in this pane instead of the archive being handed to
    /// Finder/Archive Utility — matches how opening a regular folder
    /// navigates in place, just with an extraction step first.
    func open(_ item: FileItem, coordinator: FileOperationCoordinator) {
        if item.isDirectory && !item.isApplicationBundle {
            navigate(to: item.url)
        } else if item.isApplicationBundle {
            NSWorkspace.shared.open(item.url)
        } else if let format = CompressionFormat.detect(from: item.url) {
            let tmp = URL(fileURLWithPath: "/tmp")
            let destination = FileSystemService.uniqueDestinationURL(
                forFilename: format.baseName(for: item.url),
                in: tmp
            )
            coordinator.extract(item.url, to: destination, format: format) { [weak self] in
                self?.navigate(to: destination)
            }
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func goUp() {
        let parent = currentDirectory.deletingLastPathComponent()
        guard parent.path != currentDirectory.path else { return }
        navigate(to: parent)
    }
}
