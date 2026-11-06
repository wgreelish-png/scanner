import XCTest
@testable import CardShowScanner

@MainActor final class TagApprovalStoreTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TagApprovalStoreTests-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("tag-approvals.json")
    }

    private func store(_ storage: TagApprovalTestStorage, clock: TagApprovalTestClock? = nil) -> TagApprovalStore {
        let clock = clock ?? TagApprovalTestClock()
        return TagApprovalStore(url: location(), read: { _ in try storage.read() },
                                write: { data, _ in try storage.write(data) }, now: { clock.date })
    }

    private func request(_ id: UUID, cents: Int64 = 1_000, market: Decimal? = 10,
                         manual: Bool = false) -> TagApprovalRequest {
        TagApprovalRequest(id: id, approvedTag: .individual(cents), currentMarket: market,
                           isManualOverride: manual)
    }

    private func item(id: UUID = UUID(), quantity: Int = 3, cost: Int64? = 1_000) -> ShowInventoryItem {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Normal"),
            name: "Approval fixture", set: "Set", number: "42", marketPrice: 10,
            confidence: 100, printings: ["Normal"])
        return ShowInventoryItem(id: id, card: card, quantity: quantity, remainingCostCents: cost)
    }

    private func labels(for id: UUID, cents: Int64 = 1_000, copies: Int = 2,
                        pricingRevisionID: UUID? = nil) throws -> [LabelQueueEntry] {
        var draft = InventoryLabelDraft(item: item(id: id))
        draft.askingPriceText = InventoryLabelDraft.inputText(cents)
        draft.copies = copies
        let raster = LabelRaster(width: draft.paperSize.headDots, height: draft.paperSize.feedDots,
                                 data: Data(repeating: 0x80, count: 12 * draft.paperSize.feedDots))
        return try (1...copies).map {
            try LabelQueueEntry(draft: draft, raster: raster, copyNumber: $0,
                                pricingRevisionID: pricingRevisionID)
        }
    }

    func testMissingFileDoesNotCreateApprovalOrInferPrintedBaselineFromOldQueue() throws {
        let storage = TagApprovalTestStorage(), store = store(storage), id = UUID()
        XCTAssertTrue(store.isLoaded)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(storage.writes, 0)
        var oldQueue = try labels(for: id)
        for index in oldQueue.indices { oldQueue[index].state = .completed }
        try store.observeCompletedQueue(oldQueue)
        XCTAssertNil(store.record(for: id))
        XCTAssertEqual(storage.writes, 0, "Completed legacy labels cannot create an approval")
        try store.approve([request(id)])
        try store.observeCompletedQueue(oldQueue)
        XCTAssertTrue(try XCTUnwrap(store.record(for: id)).needsLabels)
        XCTAssertNil(store.record(for: id)?.lastPrintedTag)
        XCTAssertEqual(storage.writes, 1, "Legacy labels without a pricing revision cannot acknowledge a new approval")
    }

    func testEveryApprovalResetsCurrentMarketAndManualStatusEvenWhenTagIsUnchanged() throws {
        let storage = TagApprovalTestStorage(), clock = TagApprovalTestClock(), store = store(storage, clock: clock)
        let id = UUID()
        XCTAssertEqual(try store.approve([request(id, market: 10, manual: true)]), [id])
        let firstDate = clock.date
        let firstRevision = try XCTUnwrap(store.record(for: id)).priceRevisionID
        clock.date.addTimeInterval(60)
        XCTAssertEqual(try store.approve([request(id, market: Decimal(string: "10.40"))]), [])
        let record = try XCTUnwrap(store.record(for: id))
        XCTAssertEqual(record.marketAtLastApproval, Decimal(string: "10.40"))
        XCTAssertFalse(record.isManualOverride)
        XCTAssertEqual(record.approvedAt, clock.date)
        XCTAssertNotEqual(record.approvedAt, firstDate)
        XCTAssertEqual(record.priceRevisionID, firstRevision)
        XCTAssertTrue(record.needsLabels)
        let restored = self.store(storage)
        XCTAssertEqual(restored.record(for: id), record)
        clock.date.addTimeInterval(60)
        XCTAssertEqual(try store.approve([request(id, market: nil, manual: true)]), [])
        XCTAssertNil(store.record(for: id)?.marketAtLastApproval)
        XCTAssertEqual(store.record(for: id)?.isManualOverride, true)
        XCTAssertEqual(store.record(for: id)?.priceRevisionID, firstRevision)
    }

    func testMarketChangesAccumulateAgainstLastApprovalUntilExplicitlyApprovedAgain() throws {
        let storage = TagApprovalTestStorage(), store = store(storage), id = UUID()
        try store.approve([request(id, market: 10)])
        for quote in [Decimal(string: "10.40")!, Decimal(string: "10.80")!, Decimal(string: "11.00")!] {
            let evaluation = RepricingPolicy.evaluate(baselineMarket: store.record(for: id)?.marketAtLastApproval,
                currentMarket: quote, approvedStickerCents: store.record(for: id)?.approvedTag.integerPriceCents)
            XCTAssertEqual(evaluation.marketDelta, quote - 10)
            XCTAssertEqual(evaluation.reasons.contains(.marketIncrease), quote >= 11)
        }
        XCTAssertEqual(store.record(for: id)?.marketAtLastApproval, 10)
        XCTAssertEqual(storage.writes, 1)
        XCTAssertEqual(try store.approve([request(id, market: 11)]), [])
        let reset = RepricingPolicy.evaluate(baselineMarket: store.record(for: id)?.marketAtLastApproval,
                                            currentMarket: Decimal(string: "11.40"), approvedStickerCents: 1_000)
        XCTAssertFalse(reset.reasons.contains(.marketIncrease))
    }

    func testAllApprovedTagsDifferentFromLastPrintedTagNeedLabels() throws {
        let storage = TagApprovalTestStorage(), store = store(storage), id = UUID(), bulk = UUID()
        try store.approve([request(id), .init(id: bulk, approvedTag: .twoForOne, currentMarket: 0.5)])
        XCTAssertTrue(try XCTUnwrap(store.record(for: id)).needsLabels)
        XCTAssertTrue(try XCTUnwrap(store.record(for: bulk)).needsLabels)
        try store.markLabeled(ids: [id])
        let printed = try XCTUnwrap(store.record(for: id))
        XCTAssertFalse(printed.needsLabels)
        XCTAssertEqual(printed.lastPrintedTag, .individual(1_000))
        XCTAssertNotNil(printed.lastPrintedAt)
        XCTAssertEqual(try store.approve([request(id, market: 11)]), [])
        XCTAssertFalse(try XCTUnwrap(store.record(for: id)).needsLabels)
        XCTAssertEqual(try store.approve([request(id, cents: 1_100, market: 11)]), [id])
        XCTAssertTrue(try XCTUnwrap(store.record(for: id)).needsLabels)
        XCTAssertEqual(store.record(for: id)?.lastPrintedTag, printed.lastPrintedTag)
        XCTAssertEqual(store.record(for: id)?.lastPrintedAt, printed.lastPrintedAt)
        XCTAssertEqual(try store.approve([request(id)]), [id])
        XCTAssertFalse(try XCTUnwrap(store.record(for: id)).needsLabels,
                       "Returning to the physical tag does not require another label")
    }

    func testQueueCompletionWaitsForEveryCurrentPriceCopyAndIgnoresStalePrices() throws {
        let storage = TagApprovalTestStorage(), clock = TagApprovalTestClock(), store = store(storage, clock: clock)
        let id = UUID()
        try store.approve([request(id)])
        let revision = try XCTUnwrap(store.record(for: id)).priceRevisionID
        var current = try labels(for: id, pricingRevisionID: revision)
        var stale = try labels(for: id, cents: 900, copies: 1, pricingRevisionID: revision)
        stale[0].state = .completed
        current[0].state = .completed
        try store.observeCompletedQueue(current + stale)
        XCTAssertNil(store.record(for: id)?.lastPrintedTag)
        current[1].state = .failed
        current[1].lastIssue = .printerNotReady
        try store.observeCompletedQueue(current + stale)
        XCTAssertTrue(try XCTUnwrap(store.record(for: id)).needsLabels)
        current[1].state = .completed
        current[1].lastIssue = nil
        clock.date.addTimeInterval(60)
        try store.observeCompletedQueue(current + stale)
        let printed = try XCTUnwrap(store.record(for: id))
        XCTAssertFalse(printed.needsLabels)
        XCTAssertEqual(printed.lastPrintedTag, .individual(1_000))
        XCTAssertEqual(printed.lastPrintedAt, clock.date)
        let writes = storage.writes
        clock.date.addTimeInterval(60)
        try store.observeCompletedQueue(current + stale)
        try store.observeCompletedQueue([])
        XCTAssertEqual(storage.writes, writes, "Callbacks and a cleared queue keep the durable print history")
        XCTAssertEqual(store.record(for: id), printed)
        try store.approve([request(id, cents: 1_100)])
        try store.observeCompletedQueue(current)
        XCTAssertTrue(try XCTUnwrap(store.record(for: id)).needsLabels)
        XCTAssertEqual(store.record(for: id)?.lastPrintedTag, .individual(1_000))
    }

    func testCompletedQueueFromEarlierPriceCycleCannotAcknowledgeMatchingCurrentPrice() throws {
        let storage = TagApprovalTestStorage(), store = store(storage), id = UUID()
        try store.approve([request(id)])
        let firstRevision = try XCTUnwrap(store.record(for: id)).priceRevisionID
        var originalQueue = try labels(for: id, pricingRevisionID: firstRevision)
        for index in originalQueue.indices { originalQueue[index].state = .completed }
        try store.observeCompletedQueue(originalQueue)
        XCTAssertFalse(try XCTUnwrap(store.record(for: id)).needsLabels)

        try store.approve([request(id, cents: 1_200, market: 12)])
        let secondRevision = try XCTUnwrap(store.record(for: id)).priceRevisionID
        XCTAssertNotEqual(secondRevision, firstRevision)
        try store.markLabeled(ids: [id])
        XCTAssertEqual(store.record(for: id)?.lastPrintedTag, .individual(1_200))

        try store.approve([request(id)])
        let currentRevision = try XCTUnwrap(store.record(for: id)).priceRevisionID
        XCTAssertNotEqual(currentRevision, firstRevision)
        XCTAssertNotEqual(currentRevision, secondRevision)
        try store.observeCompletedQueue(originalQueue)
        XCTAssertTrue(try XCTUnwrap(store.record(for: id)).needsLabels,
                      "An old completed queue with the same price belongs to its original approval cycle")
        XCTAssertEqual(store.record(for: id)?.lastPrintedTag, .individual(1_200))

        var currentQueue = try labels(for: id, pricingRevisionID: currentRevision)
        currentQueue[0].state = .completed
        try store.observeCompletedQueue(originalQueue + currentQueue)
        XCTAssertTrue(try XCTUnwrap(store.record(for: id)).needsLabels)
        currentQueue[1].state = .completed
        try store.observeCompletedQueue(originalQueue + currentQueue)
        XCTAssertFalse(try XCTUnwrap(store.record(for: id)).needsLabels)
        XCTAssertEqual(store.record(for: id)?.lastPrintedTag, .individual(1_000))
    }

    func testExplicitMarkLabeledIsAtomicAndDoesNotApproveUnknownLots() throws {
        let storage = TagApprovalTestStorage(), store = store(storage), id = UUID()
        try store.approve([request(id)])
        let before = storage.bytes
        XCTAssertThrowsError(try store.markLabeled(ids: [id, UUID()]))
        XCTAssertTrue(try XCTUnwrap(store.record(for: id)).needsLabels)
        XCTAssertEqual(storage.bytes, before)
        try store.markLabeled(ids: [id])
        let writes = storage.writes, printed = store.record(for: id)
        try store.markLabeled(ids: [id])
        XCTAssertEqual(storage.writes, writes)
        XCTAssertEqual(store.record(for: id), printed)
    }

    func testBatchApprovalAndExistingStickerConfirmationUseOneAtomicSave() throws {
        let storage = TagApprovalTestStorage(), clock = TagApprovalTestClock(), store = store(storage, clock: clock)
        let changed = UUID(), retained = UUID(), untouched = UUID(), added = UUID(), bulk = UUID()
        try store.approve([request(changed), request(retained), request(untouched)])
        try store.markLabeled(ids: [retained])
        let oldChanged = try XCTUnwrap(store.record(for: changed))
        let oldRetained = try XCTUnwrap(store.record(for: retained))
        let oldUntouched = try XCTUnwrap(store.record(for: untouched))
        let writes = storage.writes
        clock.date.addTimeInterval(60)

        XCTAssertEqual(try store.approve([
            request(added, cents: 0, market: 0), request(changed, cents: 1_100, market: nil, manual: true),
            request(retained, market: 11), .init(id: bulk, approvedTag: .twoForOne, currentMarket: 0.5)
        ], keepingExistingStickerIDs: [added, changed, retained]), [added, changed, bulk])

        XCTAssertEqual(storage.writes, writes + 1)
        XCTAssertEqual(store.records.map(\.id), [changed, retained, untouched, added, bulk],
                       "Updating a batch retains saved record order and appends new records in request order")
        let confirmed = try XCTUnwrap(store.record(for: changed))
        XCTAssertEqual(confirmed.approvedTag, .individual(1_100))
        XCTAssertNotEqual(confirmed.priceRevisionID, oldChanged.priceRevisionID)
        XCTAssertNil(confirmed.marketAtLastApproval, "An explicitly unavailable current quote resets the baseline")
        XCTAssertTrue(confirmed.isManualOverride)
        XCTAssertEqual(confirmed.approvedAt, clock.date)
        XCTAssertEqual(confirmed.lastPrintedTag, .individual(1_100))
        XCTAssertEqual(confirmed.lastPrintedAt, clock.date)
        XCTAssertFalse(confirmed.needsLabels)
        XCTAssertEqual(store.record(for: retained)?.priceRevisionID, oldRetained.priceRevisionID)
        XCTAssertEqual(store.record(for: retained)?.lastPrintedAt, oldRetained.lastPrintedAt,
                       "Keeping an already confirmed sticker does not rewrite its physical-label history")
        XCTAssertEqual(store.record(for: retained)?.marketAtLastApproval, 11)
        XCTAssertEqual(store.record(for: untouched), oldUntouched)
        XCTAssertEqual(store.record(for: added)?.lastPrintedTag, .individual(0))
        XCTAssertFalse(try XCTUnwrap(store.record(for: added)).needsLabels)
        XCTAssertTrue(try XCTUnwrap(store.record(for: bulk)).needsLabels)
        XCTAssertNil(store.record(for: bulk)?.lastPrintedTag)
        XCTAssertEqual(self.store(storage).records, store.records)
    }

    func testCombinedApprovalRejectsUnknownOrUnselectedStickerIDsWithoutPartialApproval() throws {
        let storage = TagApprovalTestStorage(), store = store(storage)
        let selected = UUID(), unselected = UUID(), added = UUID()
        try store.approve([request(selected), request(unselected)])
        let before = storage.bytes, records = store.records, writes = storage.writes
        let selections: [Set<UUID>] = [[UUID()], [unselected], [selected, UUID()]]
        for ids in selections {
            XCTAssertThrowsError(try store.approve([
                request(selected, cents: 1_100, market: 11), request(added)
            ], keepingExistingStickerIDs: ids)) {
                XCTAssertEqual($0 as? TagApprovalStoreFailure, .invalidSelection)
            }
            XCTAssertEqual(store.records, records)
            XCTAssertEqual(storage.bytes, before)
            XCTAssertEqual(storage.writes, writes)
            XCTAssertTrue(store.isLoaded)
            XCTAssertNil(store.record(for: added))
        }
    }

    func testCombinedApprovalConfirmsBulkCategoryWithoutChangingItToAnIndividualZeroSticker() throws {
        let storage = TagApprovalTestStorage(), store = store(storage), id = UUID(), bulk = UUID()
        try store.approve([request(id)])
        let writes = storage.writes
        XCTAssertNoThrow(try store.approve([
            request(id, cents: 1_100), .init(id: bulk, approvedTag: .twoForOne, currentMarket: 0.5)
        ], keepingExistingStickerIDs: [id, bulk]))
        XCTAssertEqual(store.record(for: bulk)?.approvedTag, .twoForOne)
        XCTAssertEqual(store.record(for: bulk)?.lastPrintedTag, .twoForOne)
        XCTAssertFalse(try XCTUnwrap(store.record(for: bulk)).needsLabels)
        XCTAssertEqual(store.record(for: id)?.lastPrintedTag, .individual(1_100))
        XCTAssertEqual(storage.writes, writes + 1)
        XCTAssertTrue(store.isLoaded)
    }

    func testCombinedApprovalSaveFailurePublishesNeitherApprovalNorStickerHistoryUntilReload() throws {
        for failAfterPersist in [false, true] {
            let storage = TagApprovalTestStorage(), store = store(storage), id = UUID(), added = UUID()
            try store.approve([request(id)])
            let before = storage.bytes, records = store.records, writes = storage.writes
            storage.failWrite = true
            storage.failAfterPersist = failAfterPersist
            XCTAssertThrowsError(try store.approve([
                request(id, cents: 1_100, market: 11, manual: true), request(added)
            ], keepingExistingStickerIDs: [id])) {
                XCTAssertEqual($0 as? TagApprovalStoreFailure, .saveFailed)
            }
            XCTAssertEqual(store.records, records)
            XCTAssertFalse(store.isLoaded)
            XCTAssertEqual(storage.writes, writes + 1)
            if !failAfterPersist { XCTAssertEqual(storage.bytes, before) }
            XCTAssertThrowsError(try store.approve([request(id)], keepingExistingStickerIDs: [id])) {
                XCTAssertEqual($0 as? TagApprovalStoreFailure, .notLoaded)
            }
            storage.failWrite = false
            store.reload()
            XCTAssertTrue(store.isLoaded)
            if failAfterPersist {
                let restored = try XCTUnwrap(store.record(for: id))
                XCTAssertEqual(restored.approvedTag, .individual(1_100))
                XCTAssertEqual(restored.lastPrintedTag, .individual(1_100))
                XCTAssertFalse(restored.needsLabels)
                XCTAssertTrue(restored.isManualOverride)
                XCTAssertNotNil(store.record(for: added))
                XCTAssertTrue(try XCTUnwrap(store.record(for: added)).needsLabels)
            } else {
                XCTAssertEqual(store.records, records)
                XCTAssertNil(store.record(for: added))
            }
        }
    }

    func testEmptyCombinedApprovalDoesNotWriteAndCannotConfirmUnselectedSticker() throws {
        let storage = TagApprovalTestStorage(), store = store(storage), id = UUID()
        XCTAssertEqual(try store.approve([], keepingExistingStickerIDs: []), [])
        XCTAssertEqual(storage.writes, 0)
        try store.approve([request(id)])
        let records = store.records, bytes = storage.bytes, writes = storage.writes
        XCTAssertThrowsError(try store.approve([], keepingExistingStickerIDs: [id])) {
            XCTAssertEqual($0 as? TagApprovalStoreFailure, .invalidSelection)
        }
        XCTAssertEqual(store.records, records)
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(storage.writes, writes)
    }

    func testInvalidApprovalRejectsWholeBatchWithoutReplacingStoredBaseline() throws {
        let storage = TagApprovalTestStorage(), store = store(storage), existing = UUID()
        try store.approve([request(existing)])
        let before = storage.bytes, records = store.records
        let invalid = [request(UUID(), cents: -100), request(UUID(), cents: 101),
                       request(UUID(), cents: ShowBudgetMoney.maximumCents + 1),
                       request(UUID(), market: -1), request(UUID(), market: Decimal.nan),
                       request(UUID(), market: ShowBudgetMoney.decimal(ShowBudgetMoney.maximumCents) + 1)]
        for bad in invalid {
            XCTAssertThrowsError(try store.approve([request(existing, cents: 1_100, market: 11), bad]))
            XCTAssertEqual(store.records, records)
            XCTAssertEqual(storage.bytes, before)
            XCTAssertTrue(store.isLoaded)
        }
        let duplicate = request(UUID())
        XCTAssertThrowsError(try store.approve([duplicate, duplicate]))
        let zero = UUID(), maximum = UUID(), unknown = UUID()
        XCTAssertEqual(Set(try store.approve([request(zero, cents: 0, market: 0),
            request(maximum, cents: ShowBudgetMoney.maximumCents / 100 * 100), request(unknown, market: nil)])),
                       [zero, maximum, unknown])
        XCTAssertEqual(store.record(for: zero)?.marketAtLastApproval, 0)
        XCTAssertNil(store.record(for: unknown)?.marketAtLastApproval)
    }

    func testFailedSaveBeforeOrAfterReplacementBlocksEditsUntilReloadAndAllowsExplicitRetry() throws {
        for failAfterPersist in [false, true] {
            let storage = TagApprovalTestStorage(), store = store(storage), id = UUID()
            try store.approve([request(id)])
            let old = store.record(for: id), before = storage.bytes
            storage.failWrite = true
            storage.failAfterPersist = failAfterPersist
            XCTAssertThrowsError(try store.approve([request(id, cents: 1_100, market: 11)])) {
                XCTAssertEqual($0 as? TagApprovalStoreFailure, .saveFailed)
            }
            XCTAssertEqual(store.record(for: id), old)
            XCTAssertFalse(store.isLoaded)
            XCTAssertNotNil(store.error)
            if !failAfterPersist { XCTAssertEqual(storage.bytes, before) }
            XCTAssertThrowsError(try store.markLabeled(ids: [id])) {
                XCTAssertEqual($0 as? TagApprovalStoreFailure, .notLoaded)
            }
            storage.failWrite = false
            store.reload()
            XCTAssertTrue(store.isLoaded)
            XCTAssertEqual(store.record(for: id)?.approvedTag, .individual(failAfterPersist ? 1_100 : 1_000))
            try store.approve([request(id, cents: 1_100, market: 11)])
            XCTAssertEqual(store.record(for: id)?.approvedTag, .individual(1_100))
        }
    }

    func testAtomicDiskStorageRestoresApprovalsPreferencesAndPrintedHistory() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TagApprovalStore(url: url), id = UUID()
        var preferences = TagPricingPreferences()
        preferences.minimumDesiredProfitCents = 200
        preferences.percentagePaymentFee = Decimal(string: "0.029")!
        preferences.enableTwoFiveForNine = true
        try store.updatePreferences(preferences)
        try store.approve([request(id, manual: true)])
        try store.markLabeled(ids: [id])
        let restored = TagApprovalStore(url: url)
        XCTAssertTrue(restored.isLoaded)
        XCTAssertEqual(restored.records, store.records)
        XCTAssertEqual(restored.preferences, preferences)
        XCTAssertFalse(try XCTUnwrap(restored.record(for: id)).needsLabels)
    }

    func testInvalidSavedDocumentsFailClosedPreserveBytesAndBlockChanges() throws {
        let source = TagApprovalTestStorage(), valid = store(source), id = UUID()
        try valid.approve([request(id)])
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(source.bytes)) as? [String: Any])
        let rows = try XCTUnwrap(document["records"] as? [[String: Any]])
        var unsupported = document
        unsupported["version"] = 2
        var duplicates = document
        duplicates["records"] = rows + rows
        var negativeMarket = document, badRow = try XCTUnwrap(rows.first)
        badRow["marketAtLastApproval"] = -1
        negativeMarket["records"] = [badRow]
        var invalidDate = document
        badRow = try XCTUnwrap(rows.first)
        badRow["approvedAt"] = "invalid"
        invalidDate["records"] = [badRow]
        var invalidPreferences = document
        var preferences = try XCTUnwrap(document["preferences"] as? [String: Any])
        preferences["percentagePaymentFee"] = 1
        invalidPreferences["preferences"] = preferences
        let invalidData = try [unsupported, duplicates, negativeMarket, invalidDate, invalidPreferences]
            .map { try JSONSerialization.data(withJSONObject: $0) }
            + [Data("broken".utf8), Data(repeating: 0, count: TagApprovalStore.maximumBytes + 1)]
        for bytes in invalidData {
            let storage = TagApprovalTestStorage(bytes: bytes), store = store(storage)
            XCTAssertFalse(store.isLoaded)
            XCTAssertTrue(store.records.isEmpty)
            XCTAssertEqual(storage.bytes, bytes)
            XCTAssertEqual(storage.writes, 0)
            XCTAssertThrowsError(try store.approve([request(UUID())]))
            XCTAssertThrowsError(try store.updatePreferences(TagPricingPreferences()))
            XCTAssertEqual(storage.bytes, bytes)
        }
    }

    func testReloadReadFailureKeepsVisibleHistoryAndDoesNotOverwriteFile() throws {
        let storage = TagApprovalTestStorage(), store = store(storage), id = UUID()
        try store.approve([request(id)])
        let before = storage.bytes, records = store.records, writes = storage.writes
        storage.failRead = true
        store.reload()
        XCTAssertFalse(store.isLoaded)
        XCTAssertEqual(store.records, records)
        XCTAssertEqual(storage.bytes, before)
        XCTAssertEqual(storage.writes, writes)
        storage.failRead = false
        store.reload()
        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(store.records, records)
    }

    func testPreferencesKeepUnknownAndKnownZeroCostsDistinctAndRoundLotCostConservatively() throws {
        let preferences = TagPricingPreferences()
        XCTAssertNil(preferences.minimumDesiredProfitCents)
        XCTAssertEqual(preferences.allocatedExpensesCents, 0)
        XCTAssertEqual(preferences.fixedPaymentFeeCents, 0)
        XCTAssertEqual(preferences.percentagePaymentFee, 0)
        XCTAssertFalse(preferences.enableTwoFiveForNine)
        XCTAssertFalse(preferences.enableThreeFiveForThirteen)
        XCTAssertFalse(preferences.allowPromotionStacking)
        let unknown = preferences.profitInputs(for: item(cost: nil))
        XCTAssertNil(unknown.acquisitionCost)
        XCTAssertNil(unknown.minimumDesiredProfit)
        XCTAssertEqual(preferences.profitInputs(for: item(cost: 0)).acquisitionCost, 0)
        XCTAssertEqual(preferences.profitInputs(for: item(quantity: 3, cost: 1_000)).acquisitionCost,
                       Decimal(string: "3.34"))
        XCTAssertEqual(preferences.profitInputs(for: item(quantity: 2, cost: 666)).acquisitionCost,
                       Decimal(string: "3.33"))
        XCTAssertEqual(preferences.profitInputs(for: item(quantity: 3, cost: 1_000), quantity: 2).acquisitionCost,
                       Decimal(string: "3.335"), "Two selected copies consume exactly 667 cents together")
        XCTAssertNil(preferences.profitInputs(for: item(), quantity: 0).acquisitionCost)
        XCTAssertNil(preferences.profitInputs(for: item(), quantity: 4).acquisitionCost)
        var configured = preferences
        configured.minimumDesiredProfitCents = 0
        configured.allocatedExpensesCents = 25
        configured.fixedPaymentFeeCents = 30
        configured.percentagePaymentFee = Decimal(string: "0.029")!
        let inputs = configured.profitInputs(for: item())
        XCTAssertEqual(inputs.minimumDesiredProfit, 0)
        XCTAssertEqual(inputs.allocatedExpenses, Decimal(string: "0.25"))
        XCTAssertEqual(inputs.fixedPaymentFee, Decimal(string: "0.30"))
        XCTAssertEqual(inputs.percentagePaymentFee, Decimal(string: "0.029"))
    }

    func testInvalidPreferencesCannotReplaceSavedSettingsOrApprovals() throws {
        let storage = TagApprovalTestStorage(), store = store(storage), id = UUID()
        try store.approve([request(id)])
        var configured = TagPricingPreferences()
        configured.minimumDesiredProfitCents = 0
        try store.updatePreferences(configured)
        let before = storage.bytes, records = store.records
        var invalid: [TagPricingPreferences] = []
        var next = configured; next.minimumDesiredProfitCents = -1; invalid.append(next)
        next = configured; next.allocatedExpensesCents = -1; invalid.append(next)
        next = configured; next.fixedPaymentFeeCents = ShowBudgetMoney.maximumCents + 1; invalid.append(next)
        for fee in [Decimal(-1), Decimal(1), Decimal.nan] {
            next = configured; next.percentagePaymentFee = fee; invalid.append(next)
        }
        for preferences in invalid {
            XCTAssertThrowsError(try store.updatePreferences(preferences))
            XCTAssertEqual(store.preferences, configured)
            XCTAssertEqual(store.records, records)
            XCTAssertEqual(storage.bytes, before)
            XCTAssertTrue(store.isLoaded)
        }
    }

    func testPrintPreparationReusesUnchangedRecordsExactlyWithoutWritingOrResettingReviewMetadata() throws {
        let storage = TagApprovalTestStorage(), clock = TagApprovalTestClock(), store = store(storage, clock: clock)
        let pending = UUID(), printed = UUID(), bulk = UUID()
        try store.approve([request(pending, manual: true), request(printed, market: nil, manual: true),
                           .init(id: bulk, approvedTag: .twoForOne, currentMarket: 0.5, isManualOverride: true)])
        try store.markLabeled(ids: [printed])
        let records = store.records, bytes = storage.bytes, writes = storage.writes
        clock.date.addTimeInterval(120)
        storage.failWrite = true

        try store.prepareForPrinting([request(pending, market: 99), request(printed, market: 42),
            .init(id: bulk, approvedTag: .twoForOne, currentMarket: 2)])
        try store.prepareForPrinting([])

        XCTAssertEqual(store.records, records, "A print request cannot change any unchanged price-cycle field")
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(storage.writes, writes, "Unchanged printing must succeed without attempting a new save")
        XCTAssertTrue(store.isLoaded)
        XCTAssertNil(store.error)
        XCTAssertTrue(try XCTUnwrap(store.record(for: pending)).needsLabels)
        XCTAssertFalse(try XCTUnwrap(store.record(for: printed)).needsLabels)
    }

    func testPrintPreparationAtomicallyBindsNewOrChangedPricesAndRetainsUnchangedRecordsAndPhysicalHistory() throws {
        let storage = TagApprovalTestStorage(), clock = TagApprovalTestClock(), store = store(storage, clock: clock)
        let changed = UUID(), unchanged = UUID(), untouched = UUID(), added = UUID(), bulk = UUID()
        try store.approve([request(changed), request(unchanged, manual: true), request(untouched)])
        try store.markLabeled(ids: [changed])
        let oldChanged = try XCTUnwrap(store.record(for: changed))
        let oldUnchanged = try XCTUnwrap(store.record(for: unchanged))
        let oldUntouched = try XCTUnwrap(store.record(for: untouched))
        let writes = storage.writes
        clock.date.addTimeInterval(60)

        try store.prepareForPrinting([request(added, cents: 0, market: 0),
            request(changed, cents: 1_200, market: nil, manual: true), request(unchanged, market: 500),
            .init(id: bulk, approvedTag: .twoForOne, currentMarket: 0.5)])

        XCTAssertEqual(storage.writes, writes + 1)
        XCTAssertEqual(store.records.map(\.id), [changed, unchanged, untouched, added, bulk])
        XCTAssertEqual(store.record(for: unchanged), oldUnchanged)
        XCTAssertEqual(store.record(for: untouched), oldUntouched)
        let bound = try XCTUnwrap(store.record(for: changed))
        XCTAssertEqual(bound.approvedTag, .individual(1_200))
        XCTAssertNotEqual(bound.priceRevisionID, oldChanged.priceRevisionID)
        XCTAssertNil(bound.marketAtLastApproval)
        XCTAssertTrue(bound.isManualOverride)
        XCTAssertEqual(bound.approvedAt, clock.date)
        XCTAssertEqual(bound.lastPrintedTag, oldChanged.lastPrintedTag)
        XCTAssertEqual(bound.lastPrintedAt, oldChanged.lastPrintedAt)
        XCTAssertTrue(bound.needsLabels, "Preparing new artwork alone cannot confirm that it was printed")
        let new = try XCTUnwrap(store.record(for: added))
        XCTAssertEqual(new.approvedTag, .individual(0))
        XCTAssertEqual(new.marketAtLastApproval, 0)
        XCTAssertEqual(new.approvedAt, clock.date)
        XCTAssertNil(new.lastPrintedTag)
        XCTAssertTrue(new.needsLabels)
        XCTAssertEqual(store.record(for: bulk)?.approvedTag, .twoForOne)
        XCTAssertEqual(self.store(storage).records, store.records)
    }

    func testPrintPreparationKeepsImmutableRevisionGuardsAcrossReprintsAndLaterPriceCycles() throws {
        let storage = TagApprovalTestStorage(), store = store(storage), id = UUID()
        try store.prepareForPrinting([request(id)])
        let first = try XCTUnwrap(store.record(for: id))
        let originalQueue = try labels(for: id, pricingRevisionID: first.priceRevisionID)
        XCTAssertNil(TagPricingContext.printingIssue(for: originalQueue[0], store: store))

        try store.prepareForPrinting([request(id, market: 99, manual: true)])
        XCTAssertEqual(store.record(for: id), first)
        XCTAssertNil(TagPricingContext.printingIssue(for: originalQueue[0], store: store))

        try store.prepareForPrinting([request(id, cents: 1_200, market: 12)])
        let second = try XCTUnwrap(store.record(for: id))
        XCTAssertNotEqual(second.priceRevisionID, first.priceRevisionID)
        XCTAssertNotNil(TagPricingContext.printingIssue(for: originalQueue[0], store: store))
        let changedQueue = try labels(for: id, cents: 1_200, pricingRevisionID: second.priceRevisionID)
        XCTAssertNil(TagPricingContext.printingIssue(for: changedQueue[0], store: store))

        try store.prepareForPrinting([request(id)])
        let current = try XCTUnwrap(store.record(for: id))
        XCTAssertNotEqual(current.priceRevisionID, first.priceRevisionID)
        XCTAssertNotEqual(current.priceRevisionID, second.priceRevisionID)
        XCTAssertNotNil(TagPricingContext.printingIssue(for: originalQueue[0], store: store),
                        "A return to the same numeric price must retain a distinct queue cycle")
        XCTAssertNotNil(TagPricingContext.printingIssue(for: changedQueue[0], store: store))
        let currentQueue = try labels(for: id, pricingRevisionID: current.priceRevisionID)
        XCTAssertNil(TagPricingContext.printingIssue(for: currentQueue[0], store: store))
        XCTAssertNil(current.lastPrintedTag)
    }

    func testPrintPreparationSavesExplicitExistingStickerConfirmationsInTheSameAtomicBinding() throws {
        let storage = TagApprovalTestStorage(), clock = TagApprovalTestClock(), store = store(storage, clock: clock)
        let unchanged = UUID(), changed = UUID(), alreadyPrinted = UUID(), added = UUID()
        try store.approve([request(unchanged, manual: true), request(changed), request(alreadyPrinted)])
        try store.markLabeled(ids: [alreadyPrinted])
        let oldUnchanged = try XCTUnwrap(store.record(for: unchanged))
        let oldPrinted = try XCTUnwrap(store.record(for: alreadyPrinted))
        let writes = storage.writes
        clock.date.addTimeInterval(90)

        try store.prepareForPrinting([request(unchanged, market: 100), request(changed, cents: 1_100, market: 11),
                                      request(alreadyPrinted, market: nil, manual: true), request(added, cents: 0, market: 0)],
                                     keepingExistingStickerIDs: [unchanged, changed, alreadyPrinted, added])

        XCTAssertEqual(storage.writes, writes + 1)
        var expected = oldUnchanged
        expected.lastPrintedTag = expected.approvedTag
        expected.lastPrintedAt = clock.date
        XCTAssertEqual(store.record(for: unchanged), expected,
                       "Explicit confirmation may update only printed history when the price is unchanged")
        XCTAssertEqual(store.record(for: alreadyPrinted), oldPrinted)
        XCTAssertEqual(store.record(for: changed)?.lastPrintedTag, .individual(1_100))
        XCTAssertEqual(store.record(for: changed)?.lastPrintedAt, clock.date)
        XCTAssertEqual(store.record(for: added)?.lastPrintedTag, .individual(0))
        XCTAssertTrue(store.records.allSatisfy { !$0.needsLabels })
        let records = store.records, bytes = storage.bytes, writesAfter = storage.writes
        clock.date.addTimeInterval(60)
        try store.prepareForPrinting([request(unchanged, market: nil)], keepingExistingStickerIDs: [unchanged])
        XCTAssertEqual(store.records, records)
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(storage.writes, writesAfter, "Confirming an already matching physical sticker is also a no-op")
    }

    func testPrintPreparationSaveFailurePublishesNoPartialBindingsOrStickerHistoryAndRequiresReload() throws {
        for failAfterPersist in [false, true] {
            let storage = TagApprovalTestStorage(), store = store(storage), existing = UUID(), added = UUID()
            try store.approve([request(existing)])
            let records = store.records, bytes = storage.bytes, writes = storage.writes
            storage.failWrite = true
            storage.failAfterPersist = failAfterPersist

            XCTAssertThrowsError(try store.prepareForPrinting([request(existing, cents: 1_200, market: 12, manual: true), request(added)],
                                                             keepingExistingStickerIDs: [existing])) {
                XCTAssertEqual($0 as? TagApprovalStoreFailure, .saveFailed)
            }
            XCTAssertEqual(store.records, records)
            XCTAssertNil(store.record(for: added))
            XCTAssertFalse(store.isLoaded)
            XCTAssertEqual(storage.writes, writes + 1)
            if !failAfterPersist { XCTAssertEqual(storage.bytes, bytes) }
            XCTAssertThrowsError(try store.prepareForPrinting([request(existing)])) {
                XCTAssertEqual($0 as? TagApprovalStoreFailure, .notLoaded)
            }
            storage.failWrite = false
            store.reload()
            XCTAssertTrue(store.isLoaded)
            if failAfterPersist {
                XCTAssertEqual(store.record(for: existing)?.approvedTag, .individual(1_200))
                XCTAssertEqual(store.record(for: existing)?.lastPrintedTag, .individual(1_200))
                XCTAssertEqual(store.record(for: existing)?.isManualOverride, true)
                XCTAssertNotNil(store.record(for: added))
            } else {
                XCTAssertEqual(store.records, records)
                XCTAssertNil(store.record(for: added))
            }
        }
    }

    func testPrintPreparationValidatesEntireSelectionIncludingIgnoredQuotesBeforeChangingAnything() throws {
        let storage = TagApprovalTestStorage(), store = store(storage), existing = UUID(), unselected = UUID()
        try store.approve([request(existing), request(unselected)])
        let records = store.records, bytes = storage.bytes, writes = storage.writes
        let invalid = [request(UUID(), cents: -100), request(UUID(), cents: 101),
            request(UUID(), cents: ShowBudgetMoney.maximumCents + 1), request(UUID(), market: -1),
            request(UUID(), market: Decimal.nan), request(UUID(), market: ShowBudgetMoney.decimal(ShowBudgetMoney.maximumCents) + 1),
            request(existing, market: Decimal.nan)]
        for bad in invalid {
            let first = bad.id == existing ? request(UUID()) : request(existing, cents: 1_200)
            XCTAssertThrowsError(try store.prepareForPrinting([first, bad])) {
                XCTAssertEqual($0 as? TagApprovalStoreFailure, .invalidApproval)
            }
            XCTAssertEqual(store.records, records)
            XCTAssertEqual(storage.bytes, bytes)
            XCTAssertEqual(storage.writes, writes)
        }
        XCTAssertThrowsError(try store.prepareForPrinting([request(existing), request(existing, cents: 1_100)])) {
            XCTAssertEqual($0 as? TagApprovalStoreFailure, .duplicateIdentity)
        }
        for keep in [Set([UUID()]), Set([unselected]), Set([existing, UUID()])] {
            XCTAssertThrowsError(try store.prepareForPrinting([request(existing, cents: 1_200)], keepingExistingStickerIDs: keep)) {
                XCTAssertEqual($0 as? TagApprovalStoreFailure, .invalidSelection)
            }
        }
        XCTAssertThrowsError(try store.prepareForPrinting([], keepingExistingStickerIDs: [existing])) {
            XCTAssertEqual($0 as? TagApprovalStoreFailure, .invalidSelection)
        }
        XCTAssertEqual(store.records, records)
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(storage.writes, writes)
        XCTAssertTrue(store.isLoaded)
    }

    func testPrintPreparationCannotBindOrSilentlyRepairAnUnavailableStore() throws {
        let storage = TagApprovalTestStorage(bytes: Data("broken".utf8)), store = store(storage)
        let bytes = storage.bytes
        XCTAssertFalse(store.isLoaded)
        for requests in [[], [request(UUID())]] {
            XCTAssertThrowsError(try store.prepareForPrinting(requests)) {
                XCTAssertEqual($0 as? TagApprovalStoreFailure, .notLoaded)
            }
        }
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(storage.writes, 0)
        XCTAssertTrue(store.records.isEmpty)
    }
}

@MainActor private final class TagApprovalTestClock {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
}

@MainActor private final class TagApprovalTestStorage {
    var bytes: Data?
    var writes = 0
    var failRead = false
    var failWrite = false
    var failAfterPersist = false

    init(bytes: Data? = nil) { self.bytes = bytes }

    func read() throws -> Data? {
        if failRead { throw CocoaError(.fileReadUnknown) }
        return bytes
    }

    func write(_ data: Data) throws {
        writes += 1
        if failWrite && !failAfterPersist { throw CocoaError(.fileWriteUnknown) }
        bytes = data
        if failWrite { throw CocoaError(.fileWriteUnknown) }
    }
}
