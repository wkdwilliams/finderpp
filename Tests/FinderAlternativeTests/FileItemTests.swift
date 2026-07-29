import Foundation
import Testing
@testable import FinderAlternative

struct FileItemTests {
    @Test func idIsStableAcrossRepeatedConstructionFromSameURL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderAlternativeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let first = FileItem(url: url)
        let second = FileItem(url: url)

        #expect(first.id == second.id, "id must be derived from the path, not a fresh UUID per construction")
        #expect(first.id == url.path)
    }

    @Test func idDiffersForDifferentURLs() throws {
        let a = FileItem(url: URL(fileURLWithPath: "/tmp/a.txt"))
        let b = FileItem(url: URL(fileURLWithPath: "/tmp/b.txt"))

        #expect(a.id != b.id)
    }
}
