import AppKit
import Foundation
import Unrar

enum FileSystemService {
    static func contents(of directory: URL) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .map(FileItem.init)
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Directory-only path completions for the location bar, keyed off the
    /// partial path's last component (e.g. `"/Users/sam/Doc"` → entries in
    /// `/Users/sam` starting with "Doc"). Hidden entries are excluded
    /// unless the partial component itself starts with `.`, matching shell
    /// tab-completion convention. Returns full paths, sorted naturally.
    static func directoryCompletions(for partialPath: String, limit: Int = 8) -> [String] {
        // Check the trailing slash on the raw input — expandingTildeInPath
        // silently strips it, so checking the expanded string here would
        // always miss the "list all children" case.
        let hadTrailingSlash = partialPath.hasSuffix("/")
        let expanded = (partialPath as NSString).expandingTildeInPath
        let parent: String
        let prefix: String
        if expanded.isEmpty || hadTrailingSlash {
            parent = expanded.isEmpty ? "/" : expanded
            prefix = ""
        } else {
            parent = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
        }
        let resolvedParent = parent.isEmpty ? "/" : parent

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: resolvedParent) else {
            return []
        }

        let fm = FileManager.default
        let matches = entries
            .filter { prefix.isEmpty || $0.lowercased().hasPrefix(prefix.lowercased()) }
            .filter { prefix.hasPrefix(".") || !$0.hasPrefix(".") }
            .filter { name in
                var isDirectory: ObjCBool = false
                let fullPath = (resolvedParent as NSString).appendingPathComponent(name)
                return fm.fileExists(atPath: fullPath, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(limit)

        return matches.map { (resolvedParent as NSString).appendingPathComponent($0) }
    }

    static var commonLocations: [(name: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ("Home", home),
            ("Desktop", home.appendingPathComponent("Desktop")),
            ("Documents", home.appendingPathComponent("Documents")),
            ("Downloads", home.appendingPathComponent("Downloads"))
        ]
    }

    /// Mounted disks for the favorites bar's dynamic "Locations" section —
    /// the boot volume plus anything under `/Volumes` (external disks,
    /// network shares, mounted disk images). `.skipHiddenVolumes` and the
    /// `volumeIsBrowsable` check both matter: an APFS boot container has
    /// several hidden system volumes (Preboot, VM, Update, ...) that
    /// `.skipHiddenVolumes` alone doesn't reliably filter on every macOS
    /// version — `volumeIsBrowsable` is the same flag Finder's own sidebar
    /// uses to decide what's worth showing a user.
    static func mountedVolumes() -> [MountedVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        return urls.compactMap { url -> MountedVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  let name = values.volumeName else { return nil }
            let isBootVolume = values.volumeIsRootFileSystem ?? (url.path == "/")
            // NOT `volumeIsRemovableKey`/`volumeIsEjectableKey` — those
            // describe whether the *storage media* is removable (a DVD, an
            // SD card), not whether the *drive* can be safely disconnected.
            // A real external USB/NVMe SSD reports "Fixed" media (its flash
            // chips aren't removable from the enclosure) despite being
            // exactly the kind of drive a user expects to eject — confirmed
            // against a real external NVMe enclosure that was wrongly
            // excluded by the old check. Finder's own actual criterion for
            // showing an eject control is just "not the boot volume"; if
            // something genuinely can't be unmounted, `unmountVolume`
            // fails gracefully with an alert instead, same as Finder.
            let isEjectable = !isBootVolume
            return MountedVolume(name: name, url: url, isInternal: values.volumeIsInternal ?? true, isEjectable: isEjectable)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Unmounts and ejects a volume — `NSWorkspace`'s own API, matching
    /// what Finder's sidebar "Eject" button calls. Only ever offered in the
    /// UI for `MountedVolume.isEjectable` volumes (never the boot volume).
    /// Synchronous and throwing (no completion-handler variant exists).
    static func unmountVolume(at url: URL) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: url)
    }

    // MARK: - File operations

    /// Finder-style collision naming: `name.ext` if free, else
    /// `name copy.ext`, `name copy 2.ext`, `name copy 3.ext`, ...
    static func uniqueDestinationURL(for url: URL, in directory: URL) -> URL {
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        func candidateURL(suffix: String?) -> URL {
            let name = suffix.map { "\(baseName) \($0)" } ?? baseName
            let withName = directory.appendingPathComponent(name)
            return ext.isEmpty ? withName : withName.appendingPathExtension(ext)
        }

        var candidate = candidateURL(suffix: nil)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        var attempt = 1
        while true {
            candidate = candidateURL(suffix: attempt == 1 ? "copy" : "copy \(attempt)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            attempt += 1
        }
    }

    /// Finder-style collision naming for an already-fully-named file, e.g.
    /// `"Archive.zip"` → `"Archive 2.zip"` — used instead of
    /// `uniqueDestinationURL` for archive filenames, since that helper's
    /// `deletingPathExtension`/`pathExtension` split only strips the last
    /// dotted component, which would mangle a multi-part extension like
    /// `.tar.gz` into `"name.tar copy.gz"` instead of `"name 2.tar.gz"`.
    /// Numbered (not "copy"-suffixed) to match Finder's own naming for
    /// archives it creates via Compress.
    static func uniqueDestinationURL(forFilename filename: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let dotIndex = filename.firstIndex(of: ".")
        let base = dotIndex.map { String(filename[..<$0]) } ?? filename
        let suffix = dotIndex.map { String(filename[$0...]) } ?? ""

        var attempt = 2
        while true {
            candidate = directory.appendingPathComponent("\(base) \(attempt)\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            attempt += 1
        }
    }

    @discardableResult
    static func copyItem(at source: URL, toDirectory destinationDirectory: URL) throws -> URL {
        let destination = uniqueDestinationURL(for: source, in: destinationDirectory)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    @discardableResult
    static func moveItem(at source: URL, toDirectory destinationDirectory: URL) throws -> URL {
        let destination = uniqueDestinationURL(for: source, in: destinationDirectory)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// `.volumeIdentifier` is an opaque, comparable-for-equality value —
    /// exactly Foundation's documented way to answer "same disk?" without
    /// parsing mount points.
    static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let volA = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let volB = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return false
        }
        return volA.isEqual(volB)
    }

    /// Recursive size of a file or directory, for sizing a `Progress`
    /// before a copy/move starts. Unreadable entries are skipped rather
    /// than failing the whole count.
    static func totalSize(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return Int64(size)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory != true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Same-volume copy uses `FileManager.copyItem` directly — on APFS this
    /// is an instant `clonefile()`, not a byte-for-byte copy, so there's no
    /// meaningful progress/cancellation window anyway (confirmed empirically:
    /// `Progress`-based auto-cancellation does NOT actually interrupt
    /// `FileManager.copyItem` — see the chunked cross-volume path below,
    /// which does real, verified-working manual cancellation). Cross-volume
    /// copies can't clone, so they're chunked in 4MB reads, checking
    /// `progress.isCancelled` between each chunk — genuinely cancellable,
    /// with the partial destination file removed on cancel.
    @discardableResult
    static func copyItemWithProgress(
        at source: URL,
        toDirectory destinationDirectory: URL,
        progress: Progress
    ) throws -> URL {
        let destination = uniqueDestinationURL(for: source, in: destinationDirectory)
        if isSameVolume(source, destinationDirectory) {
            try FileManager.default.copyItem(at: source, to: destination)
            // += this item's own size, not `= totalUnitCount` — `progress`
            // may be shared across a whole batch, and jumping straight to
            // the batch's full total after just the first (fast, cloned)
            // item would make the bar snap to 100% prematurely.
            progress.completedUnitCount += totalSize(of: destination)
            return destination
        }
        try copyRecursivelyWithProgress(at: source, to: destination, progress: progress)
        return destination
    }

    /// Same-volume move is an instant rename regardless of size. Cross-
    /// volume move copies (chunked, cancellable — see above) then removes
    /// the source, but only after the copy fully succeeds; a cancelled or
    /// failed copy leaves the source untouched and cleans up the partial
    /// destination.
    @discardableResult
    static func moveItemWithProgress(
        at source: URL,
        toDirectory destinationDirectory: URL,
        progress: Progress
    ) throws -> URL {
        let destination = uniqueDestinationURL(for: source, in: destinationDirectory)
        if isSameVolume(source, destinationDirectory) {
            let size = totalSize(of: source)
            try FileManager.default.moveItem(at: source, to: destination)
            progress.completedUnitCount += size
            return destination
        }
        try copyRecursivelyWithProgress(at: source, to: destination, progress: progress)
        try FileManager.default.removeItem(at: source)
        return destination
    }

    private static func copyRecursivelyWithProgress(at source: URL, to destination: URL, progress: Progress) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if isDirectory.boolValue {
            let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: attributes)
            let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for child in children {
                try copyRecursivelyWithProgress(
                    at: child,
                    to: destination.appendingPathComponent(child.lastPathComponent),
                    progress: progress
                )
            }
        } else {
            try copyFileWithProgress(at: source, to: destination, progress: progress)
        }
    }

    private static func copyFileWithProgress(at source: URL, to destination: URL, progress: Progress) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { try? sourceHandle.close() }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let destHandle = try FileHandle(forWritingTo: destination)

        let chunkSize = 4 * 1024 * 1024
        // Windowed average, not per-chunk instantaneous rate — a single
        // chunk's duration is noisy (filesystem buffering, scheduling
        // jitter); sampling every ~0.2s smooths that into a readable number.
        var speedWindowStart = Date()
        var bytesSinceWindowStart: Int64 = 0
        while true {
            if progress.isCancelled {
                try? destHandle.close()
                try? FileManager.default.removeItem(at: destination)
                throw CocoaError(.userCancelled)
            }
            guard let chunk = try sourceHandle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try destHandle.write(contentsOf: chunk)
            progress.completedUnitCount += Int64(chunk.count)
            bytesSinceWindowStart += Int64(chunk.count)

            let elapsed = Date().timeIntervalSince(speedWindowStart)
            if elapsed >= 0.2 {
                progress.throughput = Int(Double(bytesSinceWindowStart) / elapsed)
                bytesSinceWindowStart = 0
                speedWindowStart = Date()
            }
        }
        try destHandle.close()
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Finder's own default names for new items, numbered on collision
    /// ("untitled folder", "untitled folder 2", …).
    @discardableResult
    static func createDirectory(named name: String = "untitled folder", in directory: URL) throws -> URL {
        let url = uniqueDestinationURL(forFilename: name, in: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @discardableResult
    static func createFile(named name: String = "untitled file", in directory: URL) throws -> URL {
        let url = uniqueDestinationURL(forFilename: name, in: directory)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            // `createFile` reports failure as a plain false with no error.
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    @discardableResult
    static func createSymbolicLink(for url: URL, in directory: URL) throws -> URL {
        let linkURL = uniqueDestinationURL(for: url, in: directory)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: url)
        return linkURL
    }

    @discardableResult
    static func createHardLink(for url: URL, in directory: URL) throws -> URL {
        let linkURL = uniqueDestinationURL(for: url, in: directory)
        try FileManager.default.linkItem(at: url, to: linkURL)
        return linkURL
    }

    /// Matches Finder's "Make Alias" (⌘L) naming: `"<name> alias.<ext>"`.
    @discardableResult
    static func createAlias(for url: URL, in directory: URL) throws -> URL {
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let aliasName = "\(baseName) alias"
        let aliasBase = ext.isEmpty ? aliasName : "\(aliasName).\(ext)"
        let aliasURL = uniqueDestinationURL(
            for: directory.appendingPathComponent(aliasBase),
            in: directory
        )
        let data = try url.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(data, to: aliasURL)
        return aliasURL
    }

    enum CompressionError: LocalizedError {
        case noItems
        case processFailed(exitCode: Int32)
        case rarCreationNotSupported
        case rarExtractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noItems:
                return "Nothing to compress."
            case .processFailed(let exitCode):
                return "Compression failed (exit code \(exitCode))."
            case .rarCreationNotSupported:
                return "Creating .rar archives isn't supported — RAR's compression format is proprietary."
            case .rarExtractionFailed(let message):
                return message
            }
        }
    }

    /// Shells out to `/usr/bin/zip` or `/usr/bin/tar` (both ship with
    /// macOS) rather than `ditto`, since `zip -r`/`tar -C` both take
    /// multiple top-level items directly — one process handles the whole
    /// selection regardless of count, with names kept relative to their
    /// shared parent directory instead of embedding absolute paths.
    /// `.rar` is rejected outright — see `CompressionFormat`'s doc comment
    /// for why creating RAR archives isn't something this app can do; the
    /// UI never offers it as a creation option (`CompressionFormat
    /// .creatableCases`), this is a defensive guard, not a normal path.
    @discardableResult
    static func compress(_ urls: [URL], to destination: URL, format: CompressionFormat) throws -> URL {
        guard format != .rar else {
            throw CompressionError.rarCreationNotSupported
        }
        guard let parent = urls.first?.deletingLastPathComponent() else {
            throw CompressionError.noItems
        }
        let names = urls.map(\.lastPathComponent)

        let process = Process()
        if format == .zip {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = parent
            process.arguments = ["-r", "-q", destination.path] + names
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-czf", destination.path, "-C", parent.path] + names
        }

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CompressionError.processFailed(exitCode: process.terminationStatus)
        }
        return destination
    }

    /// Extracts into a freshly-created `destination` directory (the caller
    /// picks where — see `FileBrowserViewModel.open`, which extracts into a
    /// uniquely-named folder under `/tmp` rather than opening the archive
    /// in Finder/Archive Utility). `/usr/bin/unzip -q` and
    /// `/usr/bin/tar -xzf -C` mirror the tools `compress(_:to:format:)`
    /// uses to create those two formats; `.rar` extraction goes through
    /// `extractRar` instead, since there's no macOS-bundled `unrar` binary.
    @discardableResult
    static func extract(_ archive: URL, to destination: URL, format: CompressionFormat) throws -> URL {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        if format == .rar {
            try extractRar(archive, to: destination)
            return destination
        }

        let process = Process()
        if format == .zip {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", archive.path, "-d", destination.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archive.path, "-C", destination.path]
        }

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CompressionError.processFailed(exitCode: process.terminationStatus)
        }
        return destination
    }

    /// Extracts a `.rar` archive via `Unrar` (`mtgto/Unrar.swift`, wrapping
    /// RARLAB's own free "unrar" source — see `CompressionFormat`'s doc
    /// comment). Unlike `unzip`/`tar`, the library has no direct-to-disk
    /// extraction call — `Archive.extract(_:handler:)` streams decompressed
    /// bytes to a closure, so writing each entry to disk and reconstructing
    /// the directory tree from `Entry.fileName`/`.directory` is done here
    /// by hand.
    private static func extractRar(_ archive: URL, to destination: URL) throws {
        let rarArchive: Archive
        do {
            rarArchive = try Archive(fileURL: archive)
        } catch {
            throw CompressionError.rarExtractionFailed(rarErrorMessage(for: error))
        }
        // The library can't reassemble a multi-volume set (.part1.rar,
        // .part2.rar, ...) — extracting just the first part would silently
        // produce truncated files rather than a clear failure, so this is
        // rejected up front instead.
        guard !rarArchive.isVolume else {
            throw CompressionError.rarExtractionFailed(
                "Multi-volume RAR sets (.part1.rar, .part2.rar, ...) aren't supported yet."
            )
        }
        let entries: [Entry]
        do {
            entries = try rarArchive.entries()
        } catch {
            throw CompressionError.rarExtractionFailed(rarErrorMessage(for: error))
        }
        for entry in entries {
            let entryURL = destination.appendingPathComponent(entry.fileName)
            if entry.directory {
                try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(
                at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(atPath: entryURL.path, contents: nil) else {
                throw CompressionError.rarExtractionFailed("Couldn't create \(entry.fileName).")
            }
            let handle = try FileHandle(forWritingTo: entryURL)
            defer { try? handle.close() }
            do {
                try rarArchive.extract(entry) { data, _ in handle.write(data) }
            } catch {
                throw CompressionError.rarExtractionFailed(rarErrorMessage(for: error))
            }
        }
    }

    /// `UnrarError` (unlike this file's own `CompressionError`) has no
    /// `LocalizedError` messages of its own — just bare cases — so this
    /// maps them to text worth actually showing someone, rather than
    /// letting Swift's generic default `localizedDescription` reach the
    /// blocking progress window's failure state.
    private static func rarErrorMessage(for error: Error) -> String {
        guard let unrarError = error as? UnrarError else {
            return error.localizedDescription
        }
        switch unrarError {
        case .missingPassword:
            return "This archive is password-protected, which isn't supported yet."
        case .badArchive, .badData, .unknownFormat:
            return "This doesn't look like a valid RAR archive."
        case .eopen:
            return "Couldn't open the archive file."
        case .noMemory, .unknown:
            return "RAR extraction failed."
        }
    }
}
