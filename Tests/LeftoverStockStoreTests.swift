import XCTest
@testable import CardShowScanner

@MainActor final class LeftoverStockStoreTests: XCTestCase {
    private final class Disk {
        var data: Data?
        var writes = 0
        var failRead = false
        var failWrite = false
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LeftoverStockTests-" + UUID().uuidString)
    }

    private func card() -> CardCandidate {
        .init(identity: .init(game: "Pokémon", productID: "p:42", skuID: "4200", printing: "Holofoil"),
              name: "Fixture", set: "Fixture set", number: "42", marketPrice: 8, confidence: 100, printings: ["Holofoil"])
    }

    private func baseline() -> LeftoverStockBaseline {
        .init(location: .init(id: 259401, name: "Card Show"), fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
              rows: [.init(inventoryID: 7, card: card(), quantity: 5)])
    }

    private func store(_ disk: Disk) -> LeftoverStockStore {
        .init(directory: directory(), read: { _ in
            if disk.failRead { throw CocoaError(.fileReadNoPermission) }
            return disk.data
        }, write: { data, _ in
            if disk.failWrite { throw CocoaError(.fileWriteOutOfSpace) }
            disk.writes += 1; disk.data = data
        }, now: { Date(timeIntervalSince1970: 1_800_000_001) })
    }

    func testMissingFileDoesNotWriteAndZeroCountModePersistsBeforeAnyListExists() throws {
        let disk = Disk(), store = store(disk)
        XCTAssertTrue(store.isLoaded); XCTAssertNil(store.active); XCTAssertEqual(disk.writes, 0)
        let session = try store.start(baseline: baseline())
        XCTAssertTrue(session.countListIDs.isEmpty); XCTAssertFalse(session.countComplete)
        try store.setCountComplete(true, sessionID: session.id, counts: [])
        let reopened = self.store(disk), restored = try XCTUnwrap(reopened.active)
        XCTAssertEqual(restored.id, session.id); XCTAssertEqual(restored.baseline, baseline())
        XCTAssertTrue(restored.isCountComplete(for: []))
        XCTAssertTrue(restored.countListIDs.isEmpty)
    }

    func testPendingDraftReferencesRoundTripWithoutCreatingModelsAndRefChangesInvalidateCompletion() throws {
        let disk = Disk(), store = store(disk), listID = UUID()
        let session = try store.start(baseline: baseline())
        try store.addCountList(id: listID, sessionID: session.id)
        try store.addCountList(id: listID, sessionID: session.id)
        XCTAssertEqual(store.active?.countListIDs, [listID])
        let row = LeftoverStockCountRow(id: UUID(), card: card(), quantity: 2)
        try store.setCountComplete(true, sessionID: session.id, counts: [row])
        XCTAssertTrue(try XCTUnwrap(store.active).isCountComplete(for: [row]))
        let reopened = self.store(disk)
        XCTAssertEqual(reopened.active?.countListIDs, [listID])
        XCTAssertTrue(try XCTUnwrap(reopened.active).isCountComplete(for: [row]))
        XCTAssertFalse(try XCTUnwrap(reopened.active).isCountComplete(for: []))
        let edited = LeftoverStockCountRow(id: row.id, card: row.card, quantity: 1)
        XCTAssertFalse(try XCTUnwrap(reopened.active).isCountComplete(for: [edited]))
        try reopened.removeCountList(id: listID, sessionID: session.id)
        XCTAssertFalse(try XCTUnwrap(reopened.active).isCountComplete(for: [row]))
        XCTAssertEqual(reopened.active?.countListIDs, [])
    }

    func testFailedWritesRetainPreviousDurableAndInMemoryStateAndAllowRetry() throws {
        let disk = Disk(), store = store(disk)
        let session = try store.start(baseline: baseline()), original = disk.data
        disk.failWrite = true
        XCTAssertThrowsError(try store.addCountList(id: UUID(), sessionID: session.id))
        XCTAssertEqual(store.active, session); XCTAssertEqual(disk.data, original); XCTAssertTrue(store.isLoaded)
        XCTAssertThrowsError(try store.clear(sessionID: session.id))
        XCTAssertEqual(store.active, session); XCTAssertEqual(disk.data, original)
        disk.failWrite = false
        try store.addCountList(id: UUID(), sessionID: session.id)
        XCTAssertEqual(store.active?.countListIDs.count, 1)
    }

    func testExplicitRestartIsOneAtomicReplacementAndFailedWriteKeepsOldCount() throws {
        let disk = Disk(), store = store(disk)
        let old = try store.start(baseline: baseline())
        try store.addCountList(id: UUID(), sessionID: old.id)
        let previous = store.active, bytes = disk.data, writes = disk.writes
        disk.failWrite = true
        XCTAssertThrowsError(try store.restart(baseline: baseline(), sessionID: old.id))
        XCTAssertEqual(store.active, previous); XCTAssertEqual(disk.data, bytes)
        disk.failWrite = false
        let next = try store.restart(baseline: baseline(), sessionID: old.id)
        XCTAssertNotEqual(next.id, old.id); XCTAssertTrue(next.countListIDs.isEmpty)
        XCTAssertFalse(next.countComplete); XCTAssertEqual(disk.writes, writes + 1)
        XCTAssertEqual(self.store(disk).active, next)
    }

    func testCorruptFutureOversizedAndDuplicateReferencesNeverOverwriteSavedFile() throws {
        let disk = Disk(), initial = store(disk)
        _ = try initial.start(baseline: baseline())
        let original = try XCTUnwrap(disk.data)
        var cases = [Data("broken".utf8), Data(repeating: 32, count: LeftoverStockStore.maximumBytes + 1)]
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        future["version"] = 99
        cases.append(try JSONSerialization.data(withJSONObject: future))
        var duplicate = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var active = try XCTUnwrap(duplicate["active"] as? [String: Any])
        let id = UUID().uuidString; active["countListIDs"] = [id, id]; duplicate["active"] = active
        cases.append(try JSONSerialization.data(withJSONObject: duplicate))
        for bytes in cases {
            disk.data = bytes
            let writes = disk.writes, reopened = store(disk)
            XCTAssertFalse(reopened.isLoaded)
            XCTAssertThrowsError(try reopened.start(baseline: baseline()))
            XCTAssertEqual(disk.data, bytes); XCTAssertEqual(disk.writes, writes)
        }
    }

    func testFailedReloadRetainsVisibleSessionAndBlocksMutationsUntilSuccessfulRead() throws {
        let disk = Disk(), store = store(disk)
        let session = try store.start(baseline: baseline())
        disk.failRead = true; store.reload()
        XCTAssertFalse(store.isLoaded); XCTAssertEqual(store.active, session)
        XCTAssertThrowsError(try store.clear(sessionID: session.id))
        disk.failRead = false; store.reload()
        XCTAssertTrue(store.isLoaded); XCTAssertEqual(store.active, session)
    }

    func testWrongSessionDuplicateStartAndInvalidCompletionLeaveFileUnchanged() throws {
        let disk = Disk(), store = store(disk)
        let session = try store.start(baseline: baseline()), original = disk.data
        XCTAssertThrowsError(try store.start(baseline: baseline()))
        XCTAssertThrowsError(try store.addCountList(id: UUID(), sessionID: UUID()))
        var invalid = card(); invalid.identity.skuID = nil; invalid.identity.productID = "p:other"
        XCTAssertThrowsError(try store.setCountComplete(true, sessionID: session.id,
            counts: [.init(id: UUID(), card: invalid, quantity: 1)]))
        XCTAssertEqual(disk.data, original); XCTAssertFalse(try XCTUnwrap(store.active).countComplete)
    }

    func testRealFileReopenClearAndRemovalOnlyChangeOwnMetadata() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sentinel = folder.appendingPathComponent("ordinary-inventory-and-finances.bin")
        let bytes = Data("existing independent records".utf8); try bytes.write(to: sentinel)
        let first = LeftoverStockStore(directory: folder), session = try first.start(baseline: baseline())
        try first.addCountList(id: UUID(), sessionID: session.id)
        let reopened = LeftoverStockStore(directory: folder)
        XCTAssertEqual(reopened.active, first.active)
        try reopened.clear(sessionID: session.id)
        XCTAssertNil(LeftoverStockStore(directory: folder).active)
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("leftover-stock.json"))
        reopened.reload(); XCTAssertTrue(reopened.isLoaded); XCTAssertNil(reopened.active)
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
    }
}
