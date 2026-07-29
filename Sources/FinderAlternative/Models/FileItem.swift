import Foundation
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modificationDate: Date?
    let contentType: UTType?

    /// Derived from the path rather than a fresh UUID so identity survives
    /// `reload()` — file operations that refresh a directory listing must
    /// not scramble selection/rename state for untouched items.
    var id: String { url.path }

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey
        ])
        self.isDirectory = values?.isDirectory ?? false
        self.size = values?.fileSize.map { Int64($0) }
        self.modificationDate = values?.contentModificationDate
        self.contentType = values?.contentType
    }

    /// True for `.app` bundles specifically — real directories on disk, but
    /// meant to be launched (double-click to run), not navigated into like
    /// a regular folder. Checked via UTType conformance to `.application`
    /// (matches Finder's own recognition) with a `.app`-extension fallback
    /// in case resource-value lookup failed and `contentType` came back nil.
    var isApplicationBundle: Bool {
        if let contentType {
            return contentType.conforms(to: .application)
        }
        return url.pathExtension.lowercased() == "app"
    }

    /// Non-optional proxies for `size`/`modificationDate`, for use with
    /// `KeyPathComparator` (`FileListView`'s sortable columns) — it
    /// requires `Value: Comparable`, which `Int64?`/`Date?` aren't.
    /// Directories (nil size) sort as smallest; items with no modification
    /// date sort as oldest.
    var sortableSize: Int64 { size ?? -1 }
    var sortableModificationDate: Date { modificationDate ?? .distantPast }
}
