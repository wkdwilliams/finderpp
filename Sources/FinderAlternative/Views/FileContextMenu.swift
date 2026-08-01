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
    onCompress: @escaping ([FileItem]) -> Void,
    onError: @escaping (String) -> Void
) -> some View {
    let items = viewModel.items.filter { ids.contains($0.id) }
    let urls = items.map(\.url)
    let destination = viewModel.currentDirectory
    // Read once per menu build: what's on the pasteboard decides whether
    // the paste actions can do anything at all.
    let pasteboardURLs = urlsFromPasteboard()
    let pasteboardName = pasteboardFileName()

    Button("New File") {
        createItem(
            { try FileSystemService.createFile(in: destination) },
            failure: "Couldn’t create a new file here.",
            viewModel: viewModel, onRename: onRename, onError: onError
        )
    }

    Button("New Folder") {
        createItem(
            { try FileSystemService.createDirectory(in: destination) },
            failure: "Couldn’t create a new folder here.",
            viewModel: viewModel, onRename: onRename, onError: onError
        )
    }

    Divider()

    Button("Open") {
        items.forEach { viewModel.open($0, coordinator: coordinator) }
    }
    .disabled(items.isEmpty)

    if items.count == 1 {
        Button("Rename") {
            onRename(items[0])
        }

        // "Copy Filename" on one file, then this on another, is the whole
        // point of having Copy Filename at all — and it's what people reach
        // for "Paste" expecting. Paste itself can't do it: it moves/copies
        // *files*, and a filename on the pasteboard is plain text, so it
        // read as a silent no-op. The pasteboard text is shown in the title
        // so it's obvious what will be applied.
        if let pasteboardName, pasteboardName != items[0].name {
            Button("Paste Name (“\(abbreviated(pasteboardName))”)") {
                do {
                    let renamed = try FileSystemService.rename(items[0].url, to: pasteboardName)
                    viewModel.reload()
                    viewModel.selection = [renamed.path]
                } catch {
                    onError(RenameState.failureMessage(from: items[0].name, to: pasteboardName, error: error))
                }
            }
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

    // Disabled rather than silently doing nothing when the pasteboard holds
    // no files (e.g. it holds a copied *filename*) — an enabled menu item
    // that no-ops is indistinguishable from a broken one.
    Button("Paste") {
        coordinator.copy(pasteboardURLs, to: destination) { viewModel.reload() }
    }
    .keyboardShortcut("v", modifiers: .command)
    .disabled(pasteboardURLs.isEmpty)

    Button("Paste and Move") {
        coordinator.move(pasteboardURLs, to: destination) { viewModel.reload() }
    }
    .keyboardShortcut("v", modifiers: [.command, .option])
    .disabled(pasteboardURLs.isEmpty)

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

/// Creating an item drops straight into inline rename with the name
/// selected, the way Finder does for a new folder — the default name is a
/// placeholder nobody wants to keep.
@MainActor
private func createItem(
    _ create: () throws -> URL,
    failure: String,
    viewModel: FileBrowserViewModel,
    onRename: (FileItem) -> Void,
    onError: (String) -> Void
) {
    do {
        let url = try create()
        viewModel.reload()
        viewModel.selection = [url.path]
        if let item = viewModel.items.first(where: { $0.id == url.path }) {
            onRename(item)
        }
    } catch {
        onError("\(failure) \(error.localizedDescription)")
    }
}

private func writeURLsToPasteboard(_ urls: [URL]) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(urls.map { $0 as NSURL })
}

/// The pasteboard's text, but only when it's usable as a filename: one
/// non-empty path component. Anything with a separator would silently mean
/// "move this somewhere else", which is not what pasting a name implies.
private func pasteboardFileName() -> String? {
    guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != ".", name != "..",
          !name.contains("/"), !name.contains(":")
    else { return nil }
    return name
}

private func abbreviated(_ name: String, limit: Int = 28) -> String {
    guard name.count > limit else { return name }
    return name.prefix(limit - 1) + "…"
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
