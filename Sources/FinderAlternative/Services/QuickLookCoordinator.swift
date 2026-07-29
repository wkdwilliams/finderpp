import AppKit
import QuickLookUI

/// Wraps a `URL` for `QLPreviewPanel` — `URL`/`NSURL` don't reliably
/// conform to `QLPreviewItem` on their own, so this is an explicit, safe
/// wrapper rather than relying on an assumed built-in conformance.
private final class QuickLookItem: NSObject, QLPreviewItem {
    let url: URL
    init(url: URL) { self.url = url }
    var previewItemURL: URL? { url }
}

/// Drives the shared system `QLPreviewPanel` (the same "Quick Look" panel
/// Finder shows on Space) from `FileListView`/`IconGridView`'s
/// `.onKeyPress(.space)`. A singleton rather than an `@EnvironmentObject`
/// or per-view instance: `QLPreviewPanel.shared()` is itself a
/// process-wide singleton (only one can ever be on screen), so there's
/// nothing gained from per-view state, and a plain singleton avoids
/// needing to plumb this through the environment for a feature that's
/// only ever triggered by a keypress.
///
/// Deliberately skips the `QLPreviewPanelController` responder-chain
/// protocol (`acceptsPreviewPanelControl`/`beginPreviewPanelControl`/
/// `endPreviewPanelControl`) that Finder itself implements — that
/// machinery exists to let multiple windows/documents hand off control of
/// the one shared panel automatically (including AppKit's own built-in
/// space-bar gesture recognition for `NSTableView`). Since Space is
/// already handled explicitly here via SwiftUI's `.onKeyPress`, directly
/// driving the panel's `dataSource`/`delegate` and calling
/// `makeKeyAndOrderFront`/`reloadData` is simpler and sufficient.
@MainActor
final class QuickLookCoordinator: NSObject, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()

    private var items: [QuickLookItem] = []

    /// Toggles: if the panel is already showing, pressing Space again
    /// closes it (matches Finder) rather than just reloading its content.
    func toggle(for urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !urls.isEmpty else { return }
        items = urls.map(QuickLookItem.init)
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }
}
