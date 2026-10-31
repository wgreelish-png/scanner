import XCTest
@testable import CardShowScanner

@MainActor final class ShowBudgetStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ShowBudgetStoreTests-" + UUID().uuidString)
            .appendingPathComponent("show-budgets.json")
    }
    private func sale(id: UUID = UUID()) -> ShowBudgetEntry {
        ShowBudgetEntry(id: id, kind: .sale, grossReceivedCents: 20_000, feeCents: 1_000,
                        recordedAt: now, listID: UUID(), listName: "Original list", note: "Recorded cash")
    }

    func testScheduledCashRecordingRechecksTodayAndKeepsCompletedRetriesAndHistory() async throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func date(_ day: Int, _ hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        var clock = date(30, 12), bytes: Data?, writes = 0
        let store = ShowBudgetStore(url: location(), read: { _ in bytes }, write: { data, _ in bytes = data; writes += 1 },
            now: { clock }, calendar: calendar)
        let showID = try store.create(name: "Saturday", startingCents: 30_000, startDate: date(31), endDate: date(31))
        XCTAssertNotNil(store.activeShow, "An upcoming show remains selectable for review")
        XCTAssertNil(store.eligibleActiveShow); XCTAssertFalse(store.canRecord(showID: showID))
        let before = store.book, firstBytes = bytes, beforeWrites = writes
        var receipt = ShowBudgetEntry(kind: .purchase, paidCents: 10_000, recordedAt: date(31, 10))
        XCTAssertThrowsError(try store.record(receipt, showID: showID)) {
            XCTAssertEqual($0 as? ShowBudgetStoreFailure, .outsideShowDates)
        }
        XCTAssertEqual(store.book, before); XCTAssertEqual(bytes, firstBytes); XCTAssertEqual(writes, beforeWrites)
        clock = date(31, 10)
        XCTAssertEqual(store.eligibleActiveShow?.id, showID); XCTAssertTrue(store.canRecord(showID: showID))
        try store.record(receipt, showID: showID)
        XCTAssertEqual(try store.activeShow?.totals().availableCents, 20_000)
        clock = calendar.date(byAdding: .day, value: 1, to: date(31))!
        XCTAssertNil(store.eligibleActiveShow); XCTAssertFalse(store.canRecord(showID: showID))
        let savedWrites = writes
        try store.record(receipt, showID: showID)
        XCTAssertEqual(writes, savedWrites, "An exact committed retry is not a new out-of-date transaction")
        receipt.id = UUID()
        XCTAssertThrowsError(try store.record(receipt, showID: showID), "Backdating recordedAt cannot bypass today's schedule")
        XCTAssertEqual(store.activeShow?.entries.count, 1)
        try store.void(entryID: try XCTUnwrap(store.activeShow?.entries.first?.id), showID: showID, now: clock)
        XCTAssertEqual(try store.activeShow?.totals().availableCents, 30_000, "Historical correction remains possible after the show")
    }

    func testShowDatesPersistEditAndClearWithoutRewritingReceiptsOrAllocations() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ShowBudgetStore(url: url, now: { self.now })
        let end = now.addingTimeInterval(86_400)
        let id = try store.create(name: "Weekend show", startingCents: 30_000, startDate: now, endDate: end)
        let receipt = sale(); try store.record(receipt, showID: id)
        let original = try XCTUnwrap(store.activeShow), totals = try original.totals()
        var reopened = ShowBudgetStore(url: url)
        XCTAssertEqual(reopened.activeShow?.startDate, now); XCTAssertEqual(reopened.activeShow?.endDate, end)
        try reopened.update(showID: id, name: "Renamed show", startingCents: 30_000)
        XCTAssertEqual(reopened.activeShow?.startDate, now, "An ordinary name/budget update retains show dates")
        let moved = now.addingTimeInterval(7 * 86_400)
        try reopened.update(showID: id, name: "Renamed show", startingCents: 30_000, startDate: moved, endDate: moved)
        reopened = ShowBudgetStore(url: url)
        XCTAssertEqual(reopened.activeShow?.startDate, moved); XCTAssertEqual(reopened.activeShow?.endDate, moved)
        XCTAssertEqual(reopened.activeShow?.createdAt, original.createdAt)
        XCTAssertEqual(reopened.activeShow?.entries, [receipt]); XCTAssertEqual(try reopened.activeShow?.totals(), totals)
        try reopened.update(showID: id, name: "Renamed show", startingCents: 30_000, startDate: nil, endDate: nil)
        reopened = ShowBudgetStore(url: url)
        XCTAssertNil(reopened.activeShow?.startDate); XCTAssertNil(reopened.activeShow?.endDate)
        XCTAssertEqual(reopened.activeShow?.entries.first?.recordedAt, receipt.recordedAt)
        XCTAssertEqual(try reopened.activeShow?.totals(), totals)
    }

    func testInvalidOrFailedDateUpdateKeepsSavedDateRangeAndLedgerUntilRetry() async throws {
        var data: Data?, fail = false
        let store = ShowBudgetStore(url: location(), read: { _ in data }, write: { value, _ in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }; data = value
        }, now: { self.now })
        let id = try store.create(name: "Show", startingCents: 30_000, startDate: now, endDate: now)
        try store.record(sale(), showID: id)
        let before = store.book, bytes = data, moved = now.addingTimeInterval(86_400)
        XCTAssertThrowsError(try store.update(showID: id, name: "Show", startingCents: 30_000,
                                               startDate: moved, endDate: now)) {
            XCTAssertEqual($0 as? ShowBudgetFailure, .invalidDates)
        }
        XCTAssertEqual(store.book, before); XCTAssertEqual(data, bytes)
        fail = true
        XCTAssertThrowsError(try store.update(showID: id, name: "Show", startingCents: 30_000,
                                               startDate: moved, endDate: moved))
        XCTAssertEqual(store.book, before); XCTAssertEqual(data, bytes)
        fail = false
        try store.update(showID: id, name: "Show", startingCents: 30_000, startDate: moved, endDate: moved)
        XCTAssertEqual(store.activeShow?.startDate, moved); XCTAssertEqual(store.activeShow?.entries, before.shows[0].entries)
    }

    func testMissingFileBeginsEmptyWithoutCreatingOrChangingInventoryStorage() async throws {
        let url = location()
        let store = ShowBudgetStore(url: url)
        XCTAssertTrue(store.isLoaded)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.book.shows.isEmpty)
        XCTAssertNil(store.activeShow)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testShowAndGrossSplitLedgerPersistAcrossRestartAndRetainListReceiptSnapshot() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ShowBudgetStore(url: url)
        let show = try store.create(name: "  Saturday show  ", startingCents: 30_000)
        let receipt = sale()
        try store.record(receipt, showID: show)
        let original = try XCTUnwrap(store.activeShow)
        let totals = try original.totals()
        XCTAssertEqual(totals.reinvestedCents, 13_000)
        XCTAssertEqual(totals.savedCents, 7_000)
        XCTAssertEqual(totals.availableCents, 42_000)
        let restarted = ShowBudgetStore(url: url)
        XCTAssertTrue(restarted.isLoaded)
        XCTAssertEqual(restarted.book, store.book)
        XCTAssertEqual(restarted.activeShow?.id, show)
        XCTAssertEqual(restarted.activeShow?.name, "Saturday show")
        XCTAssertEqual(restarted.activeShow?.entries.first?.listID, receipt.listID)
        XCTAssertEqual(restarted.activeShow?.entries.first?.listName, "Original list")
    }

    func testFailedWriteKeepsBookAndDurableBytesThenExactReceiptCanRetryOnce() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let seed = ShowBudgetStore(url: url)
        let show = try seed.create(name: "Show", startingCents: 30_000)
        let bytes = try Data(contentsOf: url)
        var fail = true
        let store = ShowBudgetStore(url: url, write: { data, destination in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: destination, options: .atomic)
        })
        let before = store.book, receipt = sale()
        XCTAssertThrowsError(try store.record(receipt, showID: show)) { error in
            XCTAssertEqual(error as? ShowBudgetStoreFailure, .saveFailed)
        }
        XCTAssertEqual(store.book, before)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(store.isSaving)
        XCTAssertNotNil(store.error)
        fail = false
        try store.record(receipt, showID: show)
        XCTAssertNil(store.error)
        try store.record(receipt, showID: show)
        XCTAssertEqual(store.activeShow?.entries, [receipt])
        XCTAssertEqual(ShowBudgetStore(url: url).activeShow?.entries, [receipt])
    }

    func testRepeatedExactConfirmationDoesNotWriteAgainAndConflictingIdentityCannotDoubleCount() async throws {
        var data: Data?
        var writes = 0
        let store = ShowBudgetStore(url: location(), read: { _ in data }, write: { value, _ in data = value; writes += 1 })
        let show = try store.create(name: "Show", startingCents: 30_000)
        let receipt = sale()
        try store.record(receipt, showID: show)
        let count = writes
        try store.record(receipt, showID: show)
        XCTAssertEqual(writes, count)
        var changed = receipt
        changed.grossReceivedCents += 1
        XCTAssertThrowsError(try store.record(changed, showID: show)) { error in
            XCTAssertEqual(error as? ShowBudgetStoreFailure, .conflictingEntry)
        }
        XCTAssertEqual(writes, count)
        XCTAssertEqual(store.activeShow?.entries, [receipt])
    }

    func testNewShowsAndSelectionKeepPriorLedgersIsolatedAcrossRestart() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ShowBudgetStore(url: url)
        let first = try store.create(name: "First", startingCents: 30_000)
        let receipt = sale()
        try store.record(receipt, showID: first)
        let second = try store.create(name: "Second", startingCents: 10_000)
        XCTAssertEqual(store.activeShow?.id, second)
        XCTAssertTrue(store.activeShow?.entries.isEmpty == true)
        XCTAssertThrowsError(try store.record(receipt, showID: second))
        try store.select(showID: first)
        XCTAssertEqual(store.activeShow?.entries, [receipt])
        try store.select(showID: nil)
        XCTAssertNil(store.activeShow)
        let restarted = ShowBudgetStore(url: url)
        XCTAssertNil(restarted.activeShow)
        XCTAssertEqual(restarted.book.shows.count, 2)
        try restarted.select(showID: first)
        XCTAssertEqual(restarted.activeShow?.entries, [receipt])
    }

    func testFailedVoidPreservesEntryThenRetryReversesTotalsWithoutDeletingAuditRecord() async throws {
        var data: Data?
        var fail = false
        let store = ShowBudgetStore(url: location(), read: { _ in data }, write: { value, _ in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }; data = value
        })
        let show = try store.create(name: "Show", startingCents: 30_000), receipt = sale()
        try store.record(receipt, showID: show)
        let before = store.book, persisted = data
        fail = true
        XCTAssertThrowsError(try store.void(entryID: receipt.id, showID: show, now: now.addingTimeInterval(10)))
        XCTAssertEqual(store.book, before)
        XCTAssertEqual(data, persisted)
        fail = false
        try store.void(entryID: receipt.id, showID: show, now: now.addingTimeInterval(10))
        XCTAssertEqual(store.activeShow?.entries.count, 1)
        XCTAssertEqual(store.activeShow?.entries.first?.voidedAt, now.addingTimeInterval(10))
        let totals = try XCTUnwrap(store.activeShow).totals()
        XCTAssertEqual(totals.availableCents, 30_000)
        XCTAssertEqual(totals.savedCents, 0)
        let voided = store.book
        try store.void(entryID: receipt.id, showID: show, now: now.addingTimeInterval(100))
        XCTAssertEqual(store.book, voided, "Repeated void must preserve the original audit timestamp")
    }

    func testUpdatingStartingFundsOrNamePreservesExistingSaleAllocationsAndPersists() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ShowBudgetStore(url: url)
        let show = try store.create(name: "Show", startingCents: 30_000), receipt = sale()
        try store.record(receipt, showID: show)
        let allocations = try XCTUnwrap(store.activeShow).totals()
        try store.update(showID: show, name: "Corrected show", startingCents: 40_000)
        let updated = try XCTUnwrap(ShowBudgetStore(url: url).activeShow)
        XCTAssertEqual(updated.id, show)
        XCTAssertEqual(updated.name, "Corrected show")
        XCTAssertEqual(updated.entries, [receipt])
        let totals = try updated.totals()
        XCTAssertEqual(totals.reinvestedCents, allocations.reinvestedCents)
        XCTAssertEqual(totals.savedCents, allocations.savedCents)
        XCTAssertEqual(totals.availableCents, allocations.availableCents + 10_000)
    }

    func testFailedStartingFundsUpdateRetainsOriginalBudgetAndLedger() async throws {
        var data: Data?, fail = false
        let store = ShowBudgetStore(url: location(), read: { _ in data }, write: { value, _ in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }; data = value
        })
        let show = try store.create(name: "Show", startingCents: 30_000)
        try store.record(sale(), showID: show)
        let before = store.book, bytes = data
        fail = true
        XCTAssertThrowsError(try store.update(showID: show, name: "Edited", startingCents: 50_000))
        XCTAssertEqual(store.book, before)
        XCTAssertEqual(data, bytes)
        XCTAssertFalse(store.isSaving)
    }

    func testCorruptOrUnsupportedVersionFileIsPreservedAndCannotBeOverwrittenByCreate() async throws {
        for bytes in [Data("broken JSON".utf8), Data(#"{"version":99,"shows":[],"activeShowID":null}"#.utf8)] {
            let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            let store = ShowBudgetStore(url: url)
            XCTAssertFalse(store.isLoaded)
            XCTAssertNotNil(store.error)
            XCTAssertThrowsError(try store.create(name: "Replacement", startingCents: 30_000)) { error in
                XCTAssertEqual(error as? ShowBudgetStoreFailure, .notLoaded)
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testReadFailureBlocksMutationAndSuccessfulReloadRecoversExistingBook() async throws {
        let original = ShowBudgetBook(shows: [ShowBudgetEvent(name: "Recovered show", startingCents: 30_000)])
        let bytes = try JSONEncoder().encode(original)
        var fail = true, writes = 0
        let store = ShowBudgetStore(url: location(), read: { _ in
            if fail { throw CocoaError(.fileReadNoPermission) }; return bytes
        }, write: { _, _ in writes += 1 })
        XCTAssertFalse(store.isLoaded)
        XCTAssertThrowsError(try store.create(name: "New", startingCents: 1))
        XCTAssertEqual(writes, 0)
        fail = false
        store.reload()
        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(store.book, original)
        XCTAssertNil(store.error)
    }

    func testOversizedReadAndInvalidEntryAreRejectedWithoutPublishingOrWriting() async throws {
        var writes = 0
        let oversized = ShowBudgetStore(url: location(), read: { _ in Data(repeating: 0, count: ShowBudgetStore.maximumBytes + 1) },
                                        write: { _, _ in writes += 1 })
        XCTAssertFalse(oversized.isLoaded)
        XCTAssertEqual(writes, 0)
        var data: Data?
        let store = ShowBudgetStore(url: location(), read: { _ in data }, write: { value, _ in data = value; writes += 1 })
        let show = try store.create(name: "Show", startingCents: 30_000)
        let before = store.book, count = writes
        let invalid = ShowBudgetEntry(kind: .sale, paidCents: 100, grossReceivedCents: 20_000, recordedAt: now)
        XCTAssertThrowsError(try store.record(invalid, showID: show))
        XCTAssertEqual(store.book, before)
        XCTAssertEqual(writes, count)
    }
}
