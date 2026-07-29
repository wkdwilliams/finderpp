import Foundation
import Testing
@testable import FinderAlternative

struct FileDragDropTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func crossDirectoryDropIsEligible() {
        #expect(urlsEligibleForDrop([url("/tmp/src/a.txt")], into: url("/tmp/dst")) == [url("/tmp/src/a.txt")])
    }

    @Test func dropIntoOwnParentIsFiltered() {
        #expect(urlsEligibleForDrop([url("/tmp/src/a.txt")], into: url("/tmp/src")).isEmpty)
    }

    @Test func folderOntoItselfIsFiltered() {
        #expect(urlsEligibleForDrop([url("/tmp/src")], into: url("/tmp/src")).isEmpty)
    }

    @Test func folderIntoOwnDescendantIsFiltered() {
        #expect(urlsEligibleForDrop([url("/tmp/src")], into: url("/tmp/src/sub/deep")).isEmpty)
    }

    @Test func siblingWithSharedNamePrefixIsEligible() {
        #expect(urlsEligibleForDrop([url("/tmp/src")], into: url("/tmp/srcother")) == [url("/tmp/src")])
    }

    @Test func mixedBatchKeepsOnlyEligibleURLs() {
        let result = urlsEligibleForDrop(
            [url("/tmp/src/a.txt"), url("/tmp/dst/b.txt")],
            into: url("/tmp/dst")
        )
        #expect(result == [url("/tmp/src/a.txt")])
    }

    @Test func trailingSlashDestinationNormalizes() {
        #expect(urlsEligibleForDrop([url("/tmp/src/a.txt")], into: url("/tmp/src/")).isEmpty)
    }

    @Test func dotDotComponentsNormalize() {
        #expect(urlsEligibleForDrop([url("/tmp/src/sub/../a.txt")], into: url("/tmp/src")).isEmpty)
    }

    @Test func dropIntoSubdirectoryOfParentIsEligible() {
        #expect(urlsEligibleForDrop([url("/tmp/src/a.txt")], into: url("/tmp/src/sub")) == [url("/tmp/src/a.txt")])
    }
}
