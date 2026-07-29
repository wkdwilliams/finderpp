import Foundation
import Testing
@testable import FinderAlternative

struct FileSystemServiceTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderAlternativeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func uniqueDestinationURLReturnsOriginalWhenFree() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = URL(fileURLWithPath: "/tmp/report.txt")
        let result = FileSystemService.uniqueDestinationURL(for: source, in: dir)

        #expect(result == dir.appendingPathComponent("report.txt"))
    }

    @Test func uniqueDestinationURLAppendsCopySuffixOnCollision() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        FileManager.default.createFile(atPath: dir.appendingPathComponent("report.txt").path, contents: nil)

        let source = URL(fileURLWithPath: "/tmp/report.txt")
        let result = FileSystemService.uniqueDestinationURL(for: source, in: dir)

        #expect(result == dir.appendingPathComponent("report copy.txt"))
    }

    @Test func uniqueDestinationURLIncrementsPastMultipleCollisions() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["report.txt", "report copy.txt", "report copy 2.txt"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil)
        }

        let source = URL(fileURLWithPath: "/tmp/report.txt")
        let result = FileSystemService.uniqueDestinationURL(for: source, in: dir)

        #expect(result == dir.appendingPathComponent("report copy 3.txt"))
    }

    @Test func uniqueDestinationURLHandlesExtensionlessNames() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        FileManager.default.createFile(atPath: dir.appendingPathComponent("README").path, contents: nil)

        let source = URL(fileURLWithPath: "/tmp/README")
        let result = FileSystemService.uniqueDestinationURL(for: source, in: dir)

        #expect(result == dir.appendingPathComponent("README copy"))
    }

    @Test func contentsSortsDirectoriesBeforeFilesThenNaturalOrder() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(at: dir.appendingPathComponent("zzz-folder"), withIntermediateDirectories: true)
        for name in ["banana.txt", "Apple.txt", "file10.txt", "file2.txt"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil)
        }

        let names = FileSystemService.contents(of: dir).map(\.name)

        #expect(names == ["zzz-folder", "Apple.txt", "banana.txt", "file2.txt", "file10.txt"])
    }

    @Test func copyItemCreatesCopyAndLeavesOriginal() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("note.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        let destDir = dir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let copied = try FileSystemService.copyItem(at: source, toDirectory: destDir)

        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: copied, encoding: .utf8) == "hello")
    }

    @Test func copyItemAvoidsCollisionWithFinderStyleNaming() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("note.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)

        let copied = try FileSystemService.copyItem(at: source, toDirectory: dir)

        #expect(copied == dir.appendingPathComponent("note copy.txt"))
        #expect(FileManager.default.fileExists(atPath: source.path), "original must survive a same-directory copy")
    }

    @Test func moveItemRelocatesAndRemovesSource() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("note.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        let destDir = dir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let moved = try FileSystemService.moveItem(at: source, toDirectory: destDir)

        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func renameProducesNewPathAndRemovesOld() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("note.txt")
        try "hello".write(to: original, atomically: true, encoding: .utf8)

        let renamed = try FileSystemService.rename(original, to: "renamed.txt")

        #expect(renamed == dir.appendingPathComponent("renamed.txt"))
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func createSymbolicLinkPointsAtOriginal() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("note.txt")
        try "hello".write(to: original, atomically: true, encoding: .utf8)
        let linkDir = dir.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)

        let link = try FileSystemService.createSymbolicLink(for: original, in: linkDir)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == original.path)
    }

    @Test func createHardLinkSharesContentWithOriginal() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("note.txt")
        try "hello".write(to: original, atomically: true, encoding: .utf8)
        let linkDir = dir.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)

        let link = try FileSystemService.createHardLink(for: original, in: linkDir)

        #expect(FileManager.default.fileExists(atPath: link.path))
        #expect(try String(contentsOf: link, encoding: .utf8) == "hello")
    }

    @Test func createAliasUsesFinderStyleNamingAndHasBookmarkData() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("note.txt")
        try "hello".write(to: original, atomically: true, encoding: .utf8)

        let alias = try FileSystemService.createAlias(for: original, in: dir)

        #expect(alias.lastPathComponent == "note alias.txt")
        let data = try Data(contentsOf: alias)
        #expect(!data.isEmpty)
    }

    @Test func directoryCompletionsMatchesByPrefixAndExcludesPlainFiles() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("Document.txt").path, contents: nil)

        let completions = FileSystemService.directoryCompletions(for: dir.path + "/Doc")

        #expect(completions.map { ($0 as NSString).lastPathComponent } == ["Documents"])
    }

    @Test func directoryCompletionsWithTrailingSlashListsAllChildrenExcludingHidden() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["Documents", "Downloads", ".hidden-dir"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let completions = FileSystemService.directoryCompletions(for: dir.path + "/")

        #expect(Set(completions.map { ($0 as NSString).lastPathComponent }) == Set(["Documents", "Downloads"]))
    }

    @Test func directoryCompletionsShowsHiddenEntriesOnlyWhenPrefixStartsWithDot() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".hidden-dir"), withIntermediateDirectories: true)

        let completions = FileSystemService.directoryCompletions(for: dir.path + "/.hid")

        #expect(completions.map { ($0 as NSString).lastPathComponent } == [".hidden-dir"])
    }

    @Test func directoryCompletionsForNonexistentParentReturnsEmpty() {
        let completions = FileSystemService.directoryCompletions(for: "/nonexistent-\(UUID().uuidString)/foo")

        #expect(completions.isEmpty)
    }

    @Test func isSameVolumeIsTrueForTwoPathsOnTheSameRealVolume() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileA = dir.appendingPathComponent("a.txt")
        let fileB = dir.appendingPathComponent("b.txt")
        FileManager.default.createFile(atPath: fileA.path, contents: nil)
        FileManager.default.createFile(atPath: fileB.path, contents: nil)

        #expect(FileSystemService.isSameVolume(fileA, fileB))
    }

    @Test func isSameVolumeIsFalseWhenAPathDoesNotExist() {
        let real = FileManager.default.temporaryDirectory
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/missing.txt")

        #expect(!FileSystemService.isSameVolume(real, missing))
    }

    @Test func totalSizeOfAFileIsItsByteCount() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try "hello world".write(to: file, atomically: true, encoding: .utf8)

        #expect(FileSystemService.totalSize(of: file) == 11)
    }

    @Test func totalSizeOfADirectoryIsTheSumOfItsFiles() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "12345".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let subdir = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "1234567890".write(to: subdir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        #expect(FileSystemService.totalSize(of: dir) == 15)
    }

    @Test func copyItemWithProgressCopiesFileAndMarksProgressComplete() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("note.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        let destDir = dir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let progress = Progress(totalUnitCount: FileSystemService.totalSize(of: source))

        let copied = try FileSystemService.copyItemWithProgress(at: source, toDirectory: destDir, progress: progress)

        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(progress.completedUnitCount == progress.totalUnitCount)
    }

    @Test func moveItemWithProgressRelocatesAndRemovesSource() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("note.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        let destDir = dir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let progress = Progress(totalUnitCount: FileSystemService.totalSize(of: source))

        let moved = try FileSystemService.moveItemWithProgress(at: source, toDirectory: destDir, progress: progress)

        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }
}
