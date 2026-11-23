import XCTest
@testable import SnipBar

final class SnippetExchangeServiceTests: XCTestCase {
    func testSelectiveExportAndDecodeRoundTripPreservesTagsAndColors() throws {
        let sqlTag = TagRecord(name: "sql", color: .emerald)
        let unusedTag = TagRecord(name: "unused", color: .rose)

        let snippetA = SnippetRecord(
            title: "Active Queries",
            content: "SELECT * FROM pg_stat_activity;",
            tags: [sqlTag],
            isPinned: true
        )
        let snippetB = SnippetRecord(
            title: "Not Exported",
            content: "echo skip",
            tags: [unusedTag],
            isPinned: false
        )
        _ = snippetB

        let data = try SnippetExchangeService.encode(
            snippets: [snippetA],
            allTags: [sqlTag, unusedTag]
        )
        let decoded = try SnippetExchangeService.decode(data: data)

        XCTAssertEqual(decoded.format, SnipBarExportBundle.expectedFormat)
        XCTAssertEqual(decoded.version, SnipBarExportBundle.currentVersion)
        XCTAssertEqual(decoded.snippets.count, 1)
        XCTAssertEqual(decoded.snippets.first?.title, "Active Queries")
        XCTAssertEqual(decoded.snippets.first?.isPinned, true)
        XCTAssertEqual(decoded.snippets.first?.tags, ["sql"])
        XCTAssertEqual(decoded.tags, [ExportedTagDTO(name: "sql", color: "emerald")])
    }

    func testDuplicateDetectionMatchesNormalizedTitleAndExactContent() {
        let existing = [
            SnippetRecord(title: "  Git Prune  ", content: "git fetch -p")
        ]
        let same = ExportedSnippetDTO(title: "git prune", content: "git fetch -p")
        let modified = ExportedSnippetDTO(title: "git prune", content: "git fetch --all")

        XCTAssertTrue(SnippetExchangeService.isDuplicate(same, in: existing))
        XCTAssertFalse(SnippetExchangeService.isDuplicate(modified, in: existing))
    }

    func testDecodeRejectsInvalidFormat() {
        let bogus = Data(#"{"format":"other-app","version":1,"exportedAt":"2026-01-01T00:00:00Z","tags":[],"snippets":[]}"#.utf8)
        XCTAssertThrowsError(try SnippetExchangeService.decode(data: bogus))
    }

    func testEncodeRejectsEmptySelection() {
        XCTAssertThrowsError(try SnippetExchangeService.encode(snippets: [], allTags: []))
    }
}
