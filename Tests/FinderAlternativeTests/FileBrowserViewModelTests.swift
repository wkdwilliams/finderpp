import Foundation
import Testing
@testable import FinderAlternative

@MainActor
struct FileBrowserViewModelTests {
    /// `/var` is a symlink to `/private/var` on macOS (also `/tmp`, `/etc`).
    /// `URL.resolvingSymlinksInPath()` deliberately does NOT resolve these
    /// specific ones (Apple special-cases them), but
    /// `FileManager.contentsOfDirectory` DOES return fully realpath()-
    /// resolved paths — so fixture URLs built by hand must go through raw
    /// `realpath()` too, or they won't `==`/`.path`-match what
    /// `FileSystemService.contents(of:)` reports for the same directory.
    private func realPath(_ url: URL) -> URL {
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buf) != nil else { return url }
        let path = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func makeDirectoryTree() throws -> (root: URL, a: URL, b: URL) {
        let unresolvedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderAlternativeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unresolvedRoot, withIntermediateDirectories: true)
        let root = realPath(unresolvedRoot)
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        return (root, a, b)
    }

    @Test func startsWithEmptyHistory() throws {
        let (root, _, _) = try makeDirectoryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = FileBrowserViewModel(startingAt: root)

        #expect(!viewModel.canGoBack)
        #expect(!viewModel.canGoForward)
    }

    @Test func navigatePushesHistoryAndClearsForwardStack() throws {
        let (root, a, b) = try makeDirectoryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = FileBrowserViewModel(startingAt: root)

        viewModel.navigate(to: a)
        #expect(viewModel.currentDirectory == a)
        #expect(viewModel.canGoBack)
        #expect(!viewModel.canGoForward)

        viewModel.goBack()
        #expect(viewModel.currentDirectory == root)
        #expect(viewModel.canGoForward)

        // A fresh navigation while a forward entry exists must discard it —
        // browser-style history, not a fixed timeline.
        viewModel.navigate(to: b)
        #expect(viewModel.currentDirectory == b)
        #expect(!viewModel.canGoForward)
    }

    @Test func goBackAndGoForwardRoundTrip() throws {
        let (root, a, _) = try makeDirectoryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = FileBrowserViewModel(startingAt: root)

        viewModel.navigate(to: a)
        viewModel.goBack()
        #expect(viewModel.currentDirectory == root)

        viewModel.goForward()
        #expect(viewModel.currentDirectory == a)
        #expect(!viewModel.canGoForward)
    }

    @Test func navigateResetsSelectionAndFilter() throws {
        let (root, a, _) = try makeDirectoryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = FileBrowserViewModel(startingAt: root)
        viewModel.selection = ["something"]
        viewModel.filterText = "abc"

        viewModel.navigate(to: a)

        #expect(viewModel.selection.isEmpty)
        #expect(viewModel.filterText.isEmpty)
    }

    @Test func navigatingToCurrentDirectoryIsANoOp() throws {
        let (root, _, _) = try makeDirectoryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = FileBrowserViewModel(startingAt: root)
        viewModel.selection = ["keep-me"]

        viewModel.navigate(to: root)

        #expect(!viewModel.canGoBack, "navigating to the already-current directory must not push history")
        #expect(viewModel.selection == ["keep-me"], "and must not reset selection either")
    }

    @Test func selectedItemsReflectsSelectionSet() throws {
        let (root, a, b) = try makeDirectoryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = FileBrowserViewModel(startingAt: root)

        let aItem = viewModel.items.first { $0.url == a }
        let bItem = viewModel.items.first { $0.url == b }
        #expect(aItem != nil)
        #expect(bItem != nil)

        viewModel.selection = [aItem!.id]
        #expect(viewModel.selectedItems.map(\.url) == [a])
    }
}
