import Foundation

/// Shared by `FileListView` and `IconGridView` — incoming-drop handling for
/// both views, so it exists in one place instead of two drifting copies.
/// Outgoing drag no longer exists in this app (`.draggable` was removed
/// entirely after repeated confirmed cases of it eating plain clicks meant
/// for selection — see `IconGridView.cell`'s doc comment and `CLAUDE.md`);
/// this only ever receives drops now, from Finder or any other source.

/// Same-volume drag = move, cross-volume = copy — matches Finder. A mixed
/// selection (rare) splits into one call of each.
@MainActor
func performDrop(
    urls: [URL],
    destination: URL,
    viewModel: FileBrowserViewModel,
    coordinator: FileOperationCoordinator
) {
    guard !urls.isEmpty else { return }
    let sameVolumeURLs = urls.filter { FileSystemService.isSameVolume($0, destination) }
    let crossVolumeURLs = urls.filter { !FileSystemService.isSameVolume($0, destination) }
    if !sameVolumeURLs.isEmpty {
        coordinator.move(sameVolumeURLs, to: destination) { viewModel.reload() }
    }
    if !crossVolumeURLs.isEmpty {
        coordinator.copy(crossVolumeURLs, to: destination) { viewModel.reload() }
    }
}
