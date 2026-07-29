import AppKit

/// Shared outgoing-drag machinery for both file views. The two views start
/// drags through different mechanisms (`TableDragBridge` interposes the
/// Table's backing `NSTableView` dataSource; `GridDragMonitor` watches a
/// passive event monitor) — see those types for why — but the payload rule,
/// dragging-source behavior, and session construction live here once.
///
/// The pasteboard payload is plain `NSURL`s — the same `public.file-url`
/// format the Copy/Paste path writes (`FileContextMenu`) and the same
/// format Finder drags carry, which both panes' existing
/// `.dropDestination(for: URL.self)` handlers already accept. This also
/// makes drags out to Finder/other apps work with no extra code.
@MainActor
final class FileDragSource: NSObject, @MainActor NSDraggingSource {
    static let shared = FileDragSource()

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        [.copy, .move, .generic]
    }
}

/// The drag payload rule, matching `IconGridView.contextMenuSelection` (and
/// `NSTableView`'s own native behavior): dragging an item that's part of
/// the current selection drags the whole selection; dragging an unselected
/// item drags just it. Resolved against `filteredItems` so the payload
/// order matches what's on screen.
@MainActor
func dragPayloadURLs(hitID: FileItem.ID, viewModel: FileBrowserViewModel) -> [URL] {
    let ids: Set<FileItem.ID> =
        viewModel.selection.contains(hitID) ? viewModel.selection : [hitID]
    return viewModel.filteredItems.filter { ids.contains($0.id) }.map(\.url)
}

/// Starts an AppKit dragging session carrying `urls` from `view`, anchored
/// at the location of `event` (the mouseDown that began the gesture). Each
/// item gets the real file icon as its drag image, slightly fanned so a
/// multi-item drag reads as a stack.
@MainActor
func beginFileDrag(urls: [URL], event: NSEvent, in view: NSView, source: FileDragSource = .shared) {
    guard !urls.isEmpty else { return }
    let location = view.convert(event.locationInWindow, from: nil)
    let iconSize = NSSize(width: 32, height: 32)

    let items = urls.enumerated().map { index, url -> NSDraggingItem in
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let offset = CGFloat(min(index, 3)) * 2
        item.setDraggingFrame(
            NSRect(
                x: location.x - iconSize.width / 2 + offset,
                y: location.y - iconSize.height / 2 - offset,
                width: iconSize.width,
                height: iconSize.height
            ),
            contents: icon
        )
        return item
    }
    view.beginDraggingSession(with: items, event: event, source: source)
}
