import Foundation

/// Shared by `FileListView` and `IconGridView` — incoming-drop handling for
/// both views, so it exists in one place instead of two drifting copies.
/// Receives drops from Finder, from the other pane's outgoing drag
/// (`FileDragSource`/`TableDragBridge`/`GridDragMonitor`), or any other
/// source that puts file URLs on the drag pasteboard.

/// Filters out drops that must be no-ops rather than file operations:
/// a URL dropped into the directory it's already in (which would otherwise
/// silently *rename* it — `move` always routes through
/// `uniqueDestinationURL`, so "drop file back where it came from" would
/// produce "name copy.ext"), and a folder dropped onto itself or into its
/// own descendant (which would recurse into itself). Lives here on the
/// drop path only — deliberately NOT inside `coordinator.copy/move`, so
/// explicit ⌘C/⌘V duplicate-in-place keeps working.
func urlsEligibleForDrop(_ urls: [URL], into destination: URL) -> [URL] {
    let dest = destination.standardizedFileURL.path
    return urls.filter { url in
        let std = url.standardizedFileURL
        if std.deletingLastPathComponent().path == dest { return false }
        if std.path == dest || dest.hasPrefix(std.path + "/") { return false }
        return true
    }
}

/// Posted when a drop-initiated operation finishes. Every
/// `FileBrowserViewModel` reloads on it — a pane-to-pane drag changes BOTH
/// panes (file leaves one directory and lands in the other), so reloading
/// only the drop target's view model (what this used to do) left a ghost
/// row in the source pane.
extension Notification.Name {
    static let fileDropOperationDidComplete = Notification.Name("FAFileDropOperationDidComplete")
}

/// Same-volume drag = move, cross-volume = copy — matches Finder. A mixed
/// selection (rare) splits into one call of each.
@MainActor
func performDrop(
    urls: [URL],
    destination: URL,
    viewModel: FileBrowserViewModel,
    coordinator: FileOperationCoordinator
) {
    let eligible = urlsEligibleForDrop(urls, into: destination)
    guard !eligible.isEmpty else { return }
    let notifyCompletion = {
        NotificationCenter.default.post(name: .fileDropOperationDidComplete, object: nil)
    }
    let sameVolumeURLs = eligible.filter { FileSystemService.isSameVolume($0, destination) }
    let crossVolumeURLs = eligible.filter { !FileSystemService.isSameVolume($0, destination) }
    if !sameVolumeURLs.isEmpty {
        coordinator.move(sameVolumeURLs, to: destination, then: notifyCompletion)
    }
    if !crossVolumeURLs.isEmpty {
        coordinator.copy(crossVolumeURLs, to: destination, then: notifyCompletion)
    }
}
