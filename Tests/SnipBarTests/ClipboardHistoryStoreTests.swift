import XCTest
@testable import SnipBar

final class ClipboardHistoryStoreTests: XCTestCase {
    @MainActor
    private func makeIsolatedStore() -> ClipboardHistoryStore {
        let suiteName = "dev.snipbar.tests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        return ClipboardHistoryStore(storageURL: nil, userDefaultsSuiteName: suiteName)
    }

    @MainActor
    func testHardCapAt50Entries() {
        let store = makeIsolatedStore()
        store.maxEntries = 50

        for idx in 1...65 {
            store.record(content: "Clipboard entry #\(idx)", sourceApp: "Terminal")
        }

        XCTAssertEqual(store.entries.count, 50)
        XCTAssertEqual(store.entries.first?.content, "Clipboard entry #65")
        XCTAssertEqual(store.entries.last?.content, "Clipboard entry #16")
    }

    @MainActor
    func testDeduplicationMovesExistingEntryToTop() {
        let store = makeIsolatedStore()
        store.record(content: "first", sourceApp: "Notes")
        store.record(content: "second", sourceApp: "Safari")
        store.record(content: "first", sourceApp: "Xcode")

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries[0].content, "first")
        XCTAssertEqual(store.entries[0].sourceApp, "Xcode")
        XCTAssertEqual(store.entries[1].content, "second")
    }

    @MainActor
    func testIgnoresBlankOrWhitespaceOnlyCopies() {
        let store = makeIsolatedStore()
        XCTAssertNil(store.record(content: "   \n\t  ", sourceApp: "Terminal"))
        XCTAssertTrue(store.entries.isEmpty)
    }

    @MainActor
    func testRemoveAndClearAll() {
        let store = makeIsolatedStore()
        let first = store.record(content: "alpha")!
        _ = store.record(content: "beta")!

        store.remove(id: first.id)
        XCTAssertEqual(store.entries.map(\.content), ["beta"])

        store.clearAll()
        XCTAssertTrue(store.entries.isEmpty)
    }

    @MainActor
    func testFilterEntriesFindsItemAtSlot50AndPreservesOriginalRank() {
        let store = makeIsolatedStore()
        store.maxEntries = 50

        // Record 50 entries: entry 1 will end up at slot #50 (oldest), entry 50 at slot #1 (newest)
        store.record(content: "psql postgres://prod-analytics:5432/metrics", sourceApp: "TablePlus")
        for idx in 2...50 {
            store.record(content: "Regular copied text item \(idx)", sourceApp: "Safari")
        }

        XCTAssertEqual(store.entries.count, 50)

        // Search by small text snippet present only in slot #50
        let matches = ClipboardHistoryStore.filterEntries(store.entries, query: "analytics")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].originalRank, 50)
        XCTAssertTrue(matches[0].entry.content.contains("prod-analytics"))

        // Search by source app name
        let appMatches = ClipboardHistoryStore.filterEntries(store.entries, query: "tableplus")
        XCTAssertEqual(appMatches.count, 1)
        XCTAssertEqual(appMatches[0].originalRank, 50)

        // Search by explicit rank token #50
        let rankMatches = ClipboardHistoryStore.filterEntries(store.entries, query: "#50")
        XCTAssertEqual(rankMatches.count, 1)
        XCTAssertEqual(rankMatches[0].originalRank, 50)

        // Empty query returns all 50 entries in order with ranks 1...50
        let all = ClipboardHistoryStore.filterEntries(store.entries, query: "   ")
        XCTAssertEqual(all.count, 50)
        XCTAssertEqual(all.first?.originalRank, 1)
        XCTAssertEqual(all.last?.originalRank, 50)
    }
}
