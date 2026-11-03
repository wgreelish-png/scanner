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

    func testOnlyIndividualTagsDifferentFromLastPrintedTagNeedLabels() throws {
        let storage = TagApprovalTestStorage(), store = store(storage), id = UUID(), bulk = UUID()
        try store.approve([request(id), .init(id: bulk, approvedTag: .twoForOne, currentMarket: 0.5)])
        XCTAssertTrue(try XCTUnwrap(store.record(for: id)).needsLabels)
        XCTAssertFalse(try XCTUnwrap(store.record(for: bulk)).needsLabels)
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
