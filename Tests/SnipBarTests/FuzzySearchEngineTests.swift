import XCTest
@testable import SnipBar

final class FuzzySearchEngineTests: XCTestCase {
    private func makeFixture() -> [SnippetRecord] {
        let sqlTag = TagRecord(name: "sql", color: .blue)
        let devopsTag = TagRecord(name: "devops", color: .rose)
        let gitTag = TagRecord(name: "git", color: .amber)

        let pgQuery = SnippetRecord(
            title: "PostgreSQL Active Queries",
            content: "SELECT pid, query FROM pg_stat_activity WHERE state <> 'idle';",
            tags: [sqlTag, devopsTag],
            isPinned: true
        )
        pgQuery.usageCount = 12

        let gitPrune = SnippetRecord(
            title: "Git Prune Merged Branches",
            content: "git fetch -p && git branch --merged main",
            tags: [gitTag],
            isPinned: false
        )
        gitPrune.usageCount = 4

        let secretToken = SnippetRecord(
            title: "Staging Stripe Webhook Secret",
            content: "whsec_super_secret_token_9911",
            tags: [devopsTag],
            isPinned: false,
            isSecret: true,
            requireBiometrics: true
        )

        return [gitPrune, secretToken, pgQuery]
    }

    func testEmptyQuerySortsPinnedFirst() {
        let results = FuzzySearchEngine.filter(snippets: makeFixture(), rawQuery: "")
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.first?.title, "PostgreSQL Active Queries")
    }

    func testMultiTokenFuzzyMatchAcrossTitleAndTag() {
        let results = FuzzySearchEngine.filter(snippets: makeFixture(), rawQuery: "pg #sql")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "PostgreSQL Active Queries")
    }

    func testSecretBodyIsNeverIndexedBySearch() {
        let results = FuzzySearchEngine.filter(snippets: makeFixture(), rawQuery: "whsec_super_secret")
        XCTAssertTrue(results.isEmpty, "Secret snippet bodies must never match fuzzy search queries.")
    }

    func testSecretStillMatchesByTitleAndTag() {
        let results = FuzzySearchEngine.filter(snippets: makeFixture(), rawQuery: "stripe #devops")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Staging Stripe Webhook Secret")
        XCTAssertEqual(results.first?.safePreviewLine, "••••••••••••••••••••••••")
    }

    func testPinnedOnlyFilter() {
        let results = FuzzySearchEngine.filter(
            snippets: makeFixture(),
            rawQuery: "",
            selectedTag: nil,
            pinnedOnly: true
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.allSatisfy(\.isPinned))
    }
}
