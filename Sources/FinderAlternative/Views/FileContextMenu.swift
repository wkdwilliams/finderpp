import AppKit
import SwiftUI

/// Shared by `FileListView` and `IconGridView` so file-operation menu
/// actions exist in exactly one place instead of being duplicated (and
/// drifting) across both.
@MainActor
@ViewBuilder
func fileContextMenu(
    for ids: Set<FileItem.ID>,
    viewModel: FileBrowserViewModel,
    coordinator: FileOperationCoordinator,
    onRename: @escaping (FileItem) -> Void,
    onCompress: @escaping ([FileItem]) -> Void
) -> some View {
    let items = viewModel.items.filter { ids.contains($0.id) }
    let urls = items.map(\.url)
    let destination = viewModel.currentDirectory

    Button("Open") {
        items.forEach { viewModel.open($0, coordinator: coordinator) }
    }
    .disabled(items.isEmpty)

    if items.count == 1 {
        Button("Rename") {
            onRename(items[0])
        }

        // .app bundles execute on Open (see FileBrowserViewModel.open) —
        // this is the escape hatch for actually browsing inside one,
        // matching Finder's own "Show Package Contents" wording exactly.
        if items[0].isApplicationBundle {
            Button("Show Package Contents") {
                viewModel.navigate(to: items[0].url)
            }
        }
    }

    Divider()

    Button("Move to Trash") {
        coordinator.moveToTrash(urls) { viewModel.reload() }
    }
    .keyboardShortcut(.delete, modifiers: .command)
    .disabled(items.isEmpty)

    Divider()

    Button("Compress…") {
        onCompress(items)
    }
    .disabled(items.isEmpty)

    Divider()

    Button("Copy") {
        writeURLsToPasteboard(urls)
    }
    .keyboardShortcut("c", modifiers: .command)
    .disabled(items.isEmpty)

    Button("Paste") {
        coordinator.copy(urlsFromPasteboard(), to: destination) { viewModel.reload() }
    }
    .keyboardShortcut("v", modifiers: .command)

    Button("Paste and Move") {
        coordinator.move(urlsFromPasteboard(), to: destination) { viewModel.reload() }
    }
    .keyboardShortcut("v", modifiers: [.command, .option])

    Divider()

    Button("Copy File Path") {
        setPasteboardString(urls.map(\.path).joined(separator: "\n"))
    }
    .disabled(items.isEmpty)

    Button("Copy Filename") {
        setPasteboardString(items.map(\.name).joined(separator: "\n"))
    }
    .disabled(items.isEmpty)

    Divider()

    Button("New Symbolic Link") {
        for url in urls { _ = try? FileSystemService.createSymbolicLink(for: url, in: destination) }
        viewModel.reload()
    }
    .disabled(items.isEmpty)
}

private func writeURLsToPasteboard(_ urls: [URL]) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(urls.map { $0 as NSURL })
}

private func urlsFromPasteboard() -> [URL] {
    let objects = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil)
    return objects?.compactMap { $0 as? URL } ?? []
}

private func setPasteboardString(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
}
