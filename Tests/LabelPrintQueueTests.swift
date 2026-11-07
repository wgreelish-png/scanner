import XCTest
@testable import CardShowScanner

@MainActor final class LabelPrintQueueTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LabelPrintQueueTests-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("label-print-queue.json")
    }

    private func labels(copies: Int = 3, name: String = "Fixture card",
                        paperSize: InventoryLabelSize = .small30x14,
                        style: InventoryLabelStyle = .cardDetails) throws -> [LabelQueueEntry] {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Holofoil"),
            name: name, set: "Fixture set", number: "42", marketPrice: 12,
            confidence: 100, printings: ["Holofoil"])
        var draft = InventoryLabelDraft(item: ShowInventoryItem(card: card, quantity: 1))
        draft.askingPriceText = "14.00"
        draft.copies = copies
        draft.paperSize = paperSize
        draft.style = style
        let raster = LabelRaster(width: paperSize.headDots, height: paperSize.feedDots,
                                 data: Data(repeating: 0x80, count: 12 * paperSize.feedDots))
        return try (1...copies).map { try LabelQueueEntry(draft: draft, raster: raster, copyNumber: $0) }
    }

    private func queue(_ storage: LabelQueueTestStorage) -> LabelPrintQueue {
        LabelPrintQueue(url: location(), read: { _ in try storage.read() }, write: { data, _ in try storage.write(data) })
    }

    private func pricedLabels(_ price: Decimal?, name: String, copies: Int = 1,
                              marker: UInt8) throws -> [LabelQueueEntry] {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "sort:" + name, printing: "Normal"),
            name: name, set: "Sort fixture", number: "1", marketPrice: price, confidence: 100, printings: ["Normal"])
        var draft = InventoryLabelDraft(item: ShowInventoryItem(card: card, quantity: copies))
        draft.copies = copies
        let raster = LabelRaster(width: draft.paperSize.headDots, height: draft.paperSize.feedDots,
                                 data: Data(repeating: marker, count: 12 * draft.paperSize.feedDots))
        return try (1...copies).map { try LabelQueueEntry(draft: draft, raster: raster, copyNumber: $0) }
    }

    func testReorderPendingPersistsOnlyPendingPositionsAndPrinterUsesThatExactSavedOrder() async throws {
        let high = try pricedLabels(100, name: "Card 100", marker: 0x80)[0]
        let two = try pricedLabels(2, name: "Card 2", copies: 2, marker: 0x40)
        let ten = try pricedLabels(10, name: "Card 10", marker: 0x20)[0]
        let bulk = try pricedLabels(Decimal(string: "0.50"), name: "Bulk", marker: 0x10)[0]
        let blank = try pricedLabels(nil, name: "Write in", marker: 0x08)[0]
        var receipt = try pricedLabels(5, name: "Receipt", marker: 0x04)[0]
        receipt.state = .completed
        var uncertain = try pricedLabels(6, name: "Uncertain", marker: 0x02)[0]
        uncertain.state = .uncertain; uncertain.lastIssue = .connectionLost
        var failed = try pricedLabels(7, name: "Failed", marker: 0x01)[0]
        failed.state = .failed; failed.lastIssue = .printerNotReady
        let original = [high, receipt, two[0], uncertain, bulk, failed, two[1], blank, ten]
        let expected = [bulk, receipt, two[0], uncertain, two[1], failed, ten, high, blank]
        let storage = LabelQueueTestStorage(entries: original), queue = queue(storage)
        let printer = LabelQueueTestBatchPrinter()
        XCTAssertTrue(queue.canReorder)
        try queue.reorderPending(using: .priceAscending)
        XCTAssertEqual(queue.entries, expected, "Only pending slots move; every immutable snapshot and receipt is retained")
        XCTAssertEqual(try storage.entries(), expected)
        XCTAssertEqual(storage.writeAttempts, 1)
        XCTAssertTrue(printer.rasters.isEmpty, "Choosing an order cannot start printing")
        let restored = self.queue(storage)
        XCTAssertEqual(restored.entries, expected)
        let pending = [bulk, two[0], two[1], ten, high, blank]
        printer.onSend = { page, raster in
            XCTAssertEqual(raster, pending[page].raster)
            XCTAssertEqual(try? storage.entries().filter { $0.state == .sending }.map(\.id), [pending[page].id])
        }
        await restored.start(using: printer)
        XCTAssertEqual(printer.batches, [pending.map(\.raster)])
        XCTAssertEqual(restored.entries[1], receipt)
        XCTAssertEqual(restored.entries[3], uncertain)
        XCTAssertEqual(restored.entries[5], failed)
        XCTAssertFalse(restored.canReorder)
    }

    func testReorderPendingWithEqualNamesAndPricesKeepsCopyOrderAndSkipsUnneededSaves() throws {
        let copies = try labels(copies: 3)
        let original = [copies[2], copies[0], copies[1]]
        let storage = LabelQueueTestStorage(entries: original), queue = queue(storage)
        let bytes = storage.bytes
        XCTAssertTrue(queue.canReorder)
        for order in [LabelPrintOrder.cardName, .priceAscending, .priceDescending] {
            try queue.reorderPending(using: order)
            XCTAssertEqual(queue.entries, original)
            XCTAssertEqual(queue.entries.map(\.copyNumber), [3, 1, 2])
        }
        XCTAssertEqual(storage.writeAttempts, 0)
        XCTAssertEqual(storage.bytes, bytes)
        let single = self.queue(LabelQueueTestStorage(entries: [copies[0]]))
        XCTAssertFalse(single.canReorder)
        XCTAssertNoThrow(try single.reorderPending(using: .priceDescending))
        XCTAssertEqual(single.entries, [copies[0]])
    }

    func testReorderPendingRefusesUnreadableStorageAndActivePrintingWithoutChangingTheJob() async throws {
        let unreadable = LabelQueueTestStorage(bytes: Data([0xff]))
        let unloaded = queue(unreadable)
        XCTAssertFalse(unloaded.canReorder)
        XCTAssertThrowsError(try unloaded.reorderPending(using: .cardName)) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .notLoaded)
        }
        XCTAssertEqual(unreadable.bytes, Data([0xff]))
        XCTAssertEqual(unreadable.writeAttempts, 0)
        let original = try labels(copies: 3)
        let storage = LabelQueueTestStorage(entries: original), queue = queue(storage)
        let printer = LabelQueueTestPrinter()
        printer.held = true
        let job = Task { await queue.start(using: printer) }
        defer { printer.finish(0, with: .uncertain(.cancelled)); job.cancel() }
        try await printer.waitForSends(1)
        let sending = queue.entries, saved = storage.bytes, writes = storage.writeAttempts
        XCTAssertFalse(queue.canReorder)
        XCTAssertThrowsError(try queue.reorderPending(using: .priceDescending)) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .printing)
        }
        XCTAssertEqual(queue.entries, sending)
        XCTAssertEqual(storage.bytes, saved)
        XCTAssertEqual(storage.writeAttempts, writes)
        XCTAssertEqual(printer.rasters, [original[0].raster])
        printer.finish(0, with: .notSent(.printerNotReady))
        await job.value
        XCTAssertEqual(queue.entries.map(\.id), original.map(\.id))
        XCTAssertEqual(queue.entries.map(\.state), [.failed, .pending, .pending])
    }

    func testReorderSaveFailureKeepsInMemorySnapshotsAndRequiresReloadBeforeFurtherChanges() throws {
        let low = try pricedLabels(2, name: "Low", marker: 0x80)[0]
        let high = try pricedLabels(100, name: "High", marker: 0x40)[0]
        let ten = try pricedLabels(10, name: "Ten", marker: 0x20)[0]
        let original = [low, high, ten], expected = [high, ten, low]
        for failAfterPersist in [false, true] {
            let storage = LabelQueueTestStorage(entries: original), queue = queue(storage)
            storage.failOnWrite = 1
            storage.failAfterPersist = failAfterPersist
            XCTAssertThrowsError(try queue.reorderPending(using: .priceDescending)) {
                XCTAssertEqual($0 as? LabelPrintQueueFailure, .saveFailed)
            }
            XCTAssertEqual(queue.entries, original)
            XCTAssertFalse(queue.isLoaded)
            XCTAssertFalse(queue.canReorder)
            XCTAssertFalse(queue.canStart)
            XCTAssertNotNil(queue.error)
            XCTAssertEqual(try storage.entries(), failAfterPersist ? expected : original)
            XCTAssertThrowsError(try queue.reorderPending(using: .cardName)) {
                XCTAssertEqual($0 as? LabelPrintQueueFailure, .notLoaded)
            }
            XCTAssertEqual(storage.writeAttempts, 1)
            storage.failOnWrite = nil
            queue.reload()
            XCTAssertTrue(queue.isLoaded)
            XCTAssertEqual(queue.entries, failAfterPersist ? expected : original)
            try queue.reorderPending(using: .priceDescending)
            XCTAssertEqual(queue.entries, expected)
            XCTAssertEqual(try storage.entries(), expected)
        }
    }

    func testOfflinePreparationSavesCopiesWithoutStartingAndRestoresTheirSnapshots() throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestPrinter()
        let queue = queue(storage), entries = try labels()
        XCTAssertTrue(queue.isLoaded)
        XCTAssertTrue(queue.entries.isEmpty)
        XCTAssertEqual(storage.writeAttempts, 0, "A missing queue does not create a file")
        try queue.replace(with: entries)
        XCTAssertEqual(queue.entries, entries)
        XCTAssertEqual(queue.pendingCount, 3)
        XCTAssertTrue(queue.canStart)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertTrue(printer.rasters.isEmpty)
        XCTAssertEqual(entries.map(\.copyNumber), [1, 2, 3])
        XCTAssertEqual(Set(entries.map(\.id)).count, 3)
        XCTAssertEqual(Set(entries.map(\.inventoryID)).count, 1)
        XCTAssertTrue(entries.allSatisfy { $0.priceCents == 1_400 })
        XCTAssertTrue(entries.allSatisfy { $0.paperSize == .small30x14 && $0.style == .cardDetails })
        let restored = self.queue(storage)
        XCTAssertEqual(restored.entries, entries)
        XCTAssertTrue(restored.canStart)
        XCTAssertEqual(storage.writeAttempts, 1, "Restoring pending work never starts or rewrites it")
    }

    func testSelectedPaperAndTemplatePersistWithEachRasterAfterRelaunch() throws {
        for paperSize in InventoryLabelSize.allCases {
            for style in InventoryLabelStyle.allCases {
                let storage = LabelQueueTestStorage(), queue = queue(storage)
                let entries = try labels(copies: 1, paperSize: paperSize, style: style)
                try queue.replace(with: entries)
                let restored = self.queue(storage)
                XCTAssertEqual(restored.entries.first?.paperSize, paperSize)
                XCTAssertEqual(restored.entries.first?.style, style)
                XCTAssertEqual(restored.entries.first?.raster.width, paperSize.headDots)
                XCTAssertEqual(restored.entries.first?.raster.height, paperSize.feedDots)
            }
        }
    }

    func testLegacyCentsSnapshotWithoutPricingRevisionRestoresWithoutChangingSavedBytes() throws {
        let original = try labels(copies: 1)[0]
        let encoded = try JSONEncoder().encode(LabelQueueTestDocument(entries: [original]))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var rows = try XCTUnwrap(document["entries"] as? [[String: Any]])
        rows[0]["priceCents"] = 1_450
        rows[0].removeValue(forKey: "pricingRevisionID")
        XCTAssertNil(rows[0]["pricingRevisionID"])
        document["entries"] = rows
        let bytes = try JSONSerialization.data(withJSONObject: document)
        let storage = LabelQueueTestStorage(bytes: bytes), queue = queue(storage)
        let restored = try XCTUnwrap(queue.entries.first)
        XCTAssertTrue(queue.isLoaded)
        XCTAssertTrue(queue.canStart)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.priceCents, 1_450)
        XCTAssertEqual(restored.raster, original.raster)
        XCTAssertEqual(restored.state, .pending)
        XCTAssertNil(restored.pricingRevisionID)
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(storage.writeAttempts, 0)
    }

    func testNewQueueEntryRejectsFractionalDollarPrices() throws {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Holofoil"),
            name: "Fixture card", set: "Fixture set", number: "42", marketPrice: 12,
            confidence: 100, printings: ["Holofoil"])
        var draft = InventoryLabelDraft(item: ShowInventoryItem(card: card, quantity: 1))
        draft.askingPriceText = "14.50"
        let raster = try labels(copies: 1)[0].raster
        XCTAssertThrowsError(try LabelQueueEntry(draft: draft, raster: raster, copyNumber: 1)) {
            XCTAssertEqual($0 as? InventoryLabelFailure, .wholeDollarRequired)
        }
    }

    func testNewQueueEntryKeepsInventoryIdentityAndBulkCategoryDistinctFromAnIndividualZeroPrice() throws {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Holofoil"),
            name: "Fixture card", set: "Fixture set", number: "42", marketPrice: Decimal(string: "0.50"),
            confidence: 100, printings: ["Holofoil"])
        let draft = InventoryLabelDraft(item: ShowInventoryItem(card: card, quantity: 1))
        let raster = try labels(copies: 1)[0].raster
        XCTAssertTrue(draft.isBulk)
        XCTAssertNil(draft.priceCents)
        let entry = try LabelQueueEntry(draft: draft, raster: raster, copyNumber: 1)
        XCTAssertEqual(entry.source, .inventory)
        XCTAssertEqual(entry.inventoryID, draft.id)
        XCTAssertEqual(entry.inventoryBulk, true)
        XCTAssertNil(entry.customBulk)
        XCTAssertEqual(entry.priceCents, 0)
        XCTAssertEqual(entry.stickerTag, .twoForOne)
        XCTAssertEqual(entry.priceText, StickerPrice.twoForOne.displayText)
        XCTAssertNoThrow(try entry.validate())
    }

    func testMismatchedSavedPaperAndRasterFailClosed() throws {
        let entry = try labels(copies: 1)[0]
        let encoded = try JSONEncoder().encode(LabelQueueTestDocument(entries: [entry]))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var rows = try XCTUnwrap(document["entries"] as? [[String: Any]])
        rows[0]["paperSize"] = InventoryLabelSize.large50x14.rawValue
        document["entries"] = rows
        let bytes = try JSONSerialization.data(withJSONObject: document)
        let storage = LabelQueueTestStorage(bytes: bytes), queue = queue(storage)
        XCTAssertFalse(queue.isLoaded)
        XCTAssertTrue(queue.entries.isEmpty)
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(storage.writeAttempts, 0)
    }

    func testSendingAndEachCompletionAreDurableBeforeTransportAdvances() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestPrinter()
        let queue = queue(storage), entries = try labels()
        try queue.replace(with: entries)
        printer.onSend = { index, raster in
            let saved = try? storage.entries()
            let expected: [LabelQueueState] = Array(repeating: .completed, count: index)
                + [.sending] + Array(repeating: .pending, count: entries.count - index - 1)
            XCTAssertEqual(saved?.map(\.state), expected)
            XCTAssertEqual(saved?[index].id, entries[index].id)
            XCTAssertEqual(raster, entries[index].raster)
            XCTAssertTrue(queue.isPrinting)
            XCTAssertFalse(queue.canStart)
        }
        await queue.start(using: printer)
        XCTAssertEqual(printer.rasters.count, 3)
        XCTAssertEqual(queue.completedCount, 3)
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertEqual(queue.uncertainCount, 0)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertNil(queue.error)
        XCTAssertEqual(storage.writeAttempts, 7)
        let restored = self.queue(storage)
        XCTAssertEqual(restored.entries, queue.entries)
        await restored.start(using: printer)
        XCTAssertEqual(printer.rasters.count, 3, "Completed labels are never automatically repeated")
    }

    func testAtomicDiskStorageRestoresCompletedQueueAndAllowsExplicitNewBatch() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = LabelPrintQueue(url: url), printer = LabelQueueTestPrinter()
        let original = try labels(copies: 2)
        try queue.replace(with: original)
        XCTAssertEqual(LabelPrintQueue(url: url).entries, original)
        await queue.start(using: printer)
        let restored = LabelPrintQueue(url: url)
        XCTAssertTrue(restored.isLoaded)
        XCTAssertEqual(restored.completedCount, 2)
        XCTAssertFalse(restored.canStart)
        XCTAssertEqual(restored.entries, queue.entries)
        let replacement = try labels(copies: 1)
        try restored.replace(with: replacement)
        XCTAssertEqual(LabelPrintQueue(url: url).entries, replacement)
        XCTAssertEqual(printer.rasters.count, 2)
    }

    func testContinuousBatchUsesOneTaskAndSavesEachPageBeforeTransportCanAdvance() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestBatchPrinter()
        let queue = queue(storage), entries = try labels()
        try queue.replace(with: entries)
        printer.onSend = { page, raster in
            XCTAssertEqual(try? storage.entries().map(\.state),
                Array(repeating: .completed, count: page) + [.sending]
                    + Array(repeating: .pending, count: entries.count - page - 1))
            XCTAssertEqual(raster, entries[page].raster)
            XCTAssertTrue(queue.isPrinting)
        }
        printer.onCompleted = { page in
            XCTAssertEqual(try? storage.entries().map(\.state),
                Array(repeating: .completed, count: page + 1)
                    + Array(repeating: .pending, count: entries.count - page - 1))
        }
        await queue.start(using: printer)
        XCTAssertEqual(printer.batches, [entries.map(\.raster)])
        XCTAssertEqual(printer.singleLabelCalls, 0)
        XCTAssertEqual(printer.rasters.count, 3)
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .completed, .completed])
        XCTAssertEqual(storage.writeAttempts, 7)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertNil(queue.error)
        let restored = self.queue(storage)
        await restored.start(using: printer)
        XCTAssertEqual(printer.batches.count, 1, "Completed work is never replayed on reopening")
    }

    func testContinuousBatchIncludesOnlyPendingSnapshotsInTheirSavedOrder() async throws {
        var entries = try labels(copies: 4)
        entries[0].state = .completed
        entries[2].state = .uncertain
        entries[2].lastIssue = .connectionLost
        let storage = LabelQueueTestStorage(entries: entries), queue = queue(storage)
        let printer = LabelQueueTestBatchPrinter()
        printer.onSend = { page, _ in
            let expectedIndex = [1, 3][page]
            let saved = try? storage.entries()
            XCTAssertEqual(saved?[expectedIndex].id, entries[expectedIndex].id)
            XCTAssertEqual(saved?[expectedIndex].state, .sending)
            XCTAssertEqual(saved?[2].state, .uncertain)
        }
        await queue.start(using: printer)
        XCTAssertEqual(printer.batches, [[entries[1].raster, entries[3].raster]])
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .completed, .uncertain, .completed])
        XCTAssertEqual(queue.entries[2].lastIssue, .connectionLost)
    }

    func testContinuousBatchFailureChangesOnlyItsActivePageAndRequiresExplicitRetry() async throws {
        for failure in [LabelSendOutcome.notSent(.printerNotReady), .uncertain(.responseTimeout)] {
            let storage = LabelQueueTestStorage(), printer = LabelQueueTestBatchPrinter()
            let queue = queue(storage), entries = try labels()
            try queue.replace(with: entries)
            printer.outcomes = [.completed, failure]
            await queue.start(using: printer)
            let state: LabelQueueState = failure == .notSent(.printerNotReady) ? .failed : .uncertain
            XCTAssertEqual(queue.entries.map(\.state), [.completed, state, .pending])
            XCTAssertEqual(printer.batches.count, 1)
            XCTAssertEqual(printer.rasters.count, 2)
            XCTAssertEqual(try storage.entries(), queue.entries)
            XCTAssertNotNil(queue.error)
            let restored = self.queue(storage)
            XCTAssertEqual(restored.entries, queue.entries)
            XCTAssertEqual(printer.rasters.count, 2, "Restoring the queue must not start a printer")
            if state == .uncertain {
                XCTAssertThrowsError(try restored.retry(ids: [entries[1].id])) {
                    XCTAssertEqual($0 as? LabelPrintQueueFailure, .acknowledgeUncertain)
                }
            }
            try restored.retry(ids: [entries[1].id], acknowledgeUncertain: true)
            XCTAssertEqual(printer.batches.count, 1, "Selecting a retry requires a separate Start")
            await restored.start(using: printer)
            XCTAssertEqual(printer.batches.count, 2)
            XCTAssertEqual(printer.rasters.count, 4)
            XCTAssertEqual(restored.completedCount, 3)
        }
    }

    func testContinuousBatchSendingSaveFailureNeverDispatchesThatPageOrLaterPages() async throws {
        for failAfterPersist in [false, true] {
            let storage = LabelQueueTestStorage(), printer = LabelQueueTestBatchPrinter()
            let queue = queue(storage), entries = try labels()
            try queue.replace(with: entries)
            storage.failOnWrite = 4 // The second page's sending marker.
            storage.failAfterPersist = failAfterPersist
            await queue.start(using: printer)
            XCTAssertEqual(printer.batches.count, 1)
            XCTAssertEqual(printer.rasters.count, 1)
            XCTAssertEqual(queue.entries.map(\.state), [.completed, .pending, .pending])
            XCTAssertFalse(queue.isLoaded)
            XCTAssertFalse(queue.canStart)
            await queue.start(using: printer)
            XCTAssertEqual(printer.batches.count, 1)
            storage.failOnWrite = nil
            queue.reload()
            XCTAssertEqual(queue.entries.map(\.state),
                failAfterPersist ? [.completed, .uncertain, .pending] : [.completed, .pending, .pending])
            XCTAssertEqual(printer.rasters.count, 1)
        }
    }

    func testContinuousBatchInitialSendingSaveFailurePreventsAllPageBytes() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestBatchPrinter()
        let queue = queue(storage), entries = try labels()
        try queue.replace(with: entries)
        storage.failOnWrite = 2
        await queue.start(using: printer)
        XCTAssertEqual(printer.batches.count, 1)
        XCTAssertTrue(printer.rasters.isEmpty)
        XCTAssertEqual(queue.entries, entries)
        XCTAssertFalse(queue.isLoaded)
        XCTAssertFalse(queue.canStart)
        XCTAssertEqual(try storage.entries(), entries)
    }

    func testContinuousBatchCompletionSaveFailureRetainsObservedResultAndBlocksFuturePages() async throws {
        for failAfterPersist in [false, true] {
            let storage = LabelQueueTestStorage(), printer = LabelQueueTestBatchPrinter()
            let queue = queue(storage), entries = try labels()
            try queue.replace(with: entries)
            storage.failOnWrite = 5 // The second page's confirmed completion.
            storage.failAfterPersist = failAfterPersist
            await queue.start(using: printer)
            XCTAssertEqual(printer.rasters.count, 2)
            XCTAssertEqual(queue.entries.map(\.state), [.completed, .completed, .pending])
            XCTAssertFalse(queue.isLoaded)
            XCTAssertFalse(queue.isPrinting)
            XCTAssertFalse(queue.canStart)
            await queue.start(using: printer)
            XCTAssertEqual(printer.batches.count, 1)
            storage.failOnWrite = nil
            queue.reload()
            XCTAssertEqual(queue.entries.map(\.state),
                failAfterPersist ? [.completed, .completed, .pending] : [.completed, .uncertain, .pending])
            XCTAssertEqual(printer.rasters.count, 2)
        }
    }

    func testContinuousBatchStopAfterConfirmationLeavesFuturePagesPending() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestBatchPrinter()
        let stalePrinter = LabelQueueTestPrinter(), queue = queue(storage)
        try queue.replace(with: labels())
        printer.onCompleted = { page in
            if page == 0 {
                queue.stop(using: stalePrinter)
                queue.stop(using: stalePrinter)
            }
        }
        await queue.start(using: printer)
        XCTAssertEqual(printer.cancellations, 1)
        XCTAssertEqual(stalePrinter.cancellations, 0)
        XCTAssertEqual(printer.rasters.count, 1)
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .pending, .pending])
        XCTAssertEqual(try storage.entries(), queue.entries)
    }

    func testContinuousBatchStopKeepsLatePhysicalConfirmationAndRejectsDoubleStart() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestBatchPrinter()
        let stalePrinter = LabelQueueTestPrinter(), queue = queue(storage)
        try queue.replace(with: labels())
        printer.held = true
        let job = Task { await queue.start(using: printer) }
        try await printer.waitForSends(1)
        await queue.start(using: stalePrinter)
        XCTAssertTrue(stalePrinter.rasters.isEmpty)
        queue.stop(using: stalePrinter)
        XCTAssertTrue(queue.isPrinting)
        printer.finish(0, with: .completed)
        await job.value
        XCTAssertEqual(printer.cancellations, 1)
        XCTAssertEqual(printer.rasters.count, 1)
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .pending, .pending])
        XCTAssertFalse(queue.isPrinting)
    }

    func testContinuousBatchTaskCancellationMarksOnlyUnconfirmedPageUncertain() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestBatchPrinter()
        let queue = queue(storage)
        try queue.replace(with: labels())
        printer.outcomes = [.completed]
        printer.onCompleted = { page in if page == 0 { printer.held = true } }
        printer.cancelOutcome = .uncertain(.cancelled)
        let job = Task { await queue.start(using: printer) }
        try await printer.waitForSends(2)
        job.cancel()
        await job.value
        XCTAssertEqual(printer.cancellations, 1)
        XCTAssertEqual(printer.rasters.count, 2)
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .uncertain, .pending])
        XCTAssertEqual(queue.entries[1].lastIssue, .cancelled)
        XCTAssertEqual(try storage.entries(), queue.entries)
        XCTAssertTrue(queue.isLoaded)
    }

    func testContinuousBatchRechecksApprovalBeforeEveryPage() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestBatchPrinter()
        let entries = try labels()
        var revoked = false
        let queue = LabelPrintQueue(url: location(), read: { _ in try storage.read() },
            write: { data, _ in try storage.write(data) }, approvalIssue: { entry in
                revoked && entry.id == entries[1].id ? "Approve the updated price before printing." : nil
            })
        try queue.replace(with: entries)
        printer.onCompleted = { _ in revoked = true }
        await queue.start(using: printer)
        XCTAssertEqual(printer.rasters.count, 1)
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .failed, .pending])
        XCTAssertEqual(queue.entries[1].lastIssue, .invalidLabel)
        XCTAssertEqual(queue.error, "Approve the updated price before printing.")
        XCTAssertEqual(try storage.entries(), queue.entries)
    }

    func testContinuousBatchTaskSuccessCannotReplaceAMissingPageConfirmation() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestBatchPrinter()
        let queue = queue(storage)
        try queue.replace(with: labels())
        printer.omitCompletionAt = 0
        await queue.start(using: printer)
        XCTAssertEqual(printer.rasters.count, 1)
        XCTAssertEqual(queue.entries.map(\.state), [.uncertain, .pending, .pending])
        XCTAssertEqual(queue.entries[0].lastIssue, .unsupportedResponse)
        XCTAssertEqual(try storage.entries(), queue.entries)
    }

    func testContinuousBatchEndFailureDoesNotInvalidateAlreadyConfirmedPages() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestBatchPrinter()
        let queue = queue(storage)
        try queue.replace(with: labels())
        printer.endOutcome = .uncertain(.connectionLost)
        await queue.start(using: printer)
        XCTAssertEqual(printer.rasters.count, 3)
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .completed, .completed])
        XCTAssertEqual(queue.error, LabelPrinterIssue.connectionLost.localizedDescription)
        XCTAssertFalse(queue.canStart)
        XCTAssertEqual(try storage.entries(), queue.entries)
    }

    func testContinuousBatchLateCallbacksCannotMutateANewerSession() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestBatchPrinter()
        let queue = queue(storage)
        try queue.replace(with: labels(copies: 1))
        await queue.start(using: printer)
        let oldBefore = try XCTUnwrap(printer.savedBeforePage)
        let oldAfter = try XCTUnwrap(printer.savedAfterPage)
        try queue.replace(with: labels(copies: 1))
        printer.held = true
        let job = Task { await queue.start(using: printer) }
        try await printer.waitForSends(2)
        let bytes = storage.bytes
        do { try await oldBefore(0); XCTFail("A stale callback must fail") }
        catch { XCTAssertEqual(error as? LabelPrinterIssue, .cancelled) }
        do { try await oldAfter(0); XCTFail("A stale callback must fail") }
        catch { XCTAssertEqual(error as? LabelPrinterIssue, .cancelled) }
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(queue.entries.map(\.state), [.sending])
        printer.finish(1, with: .completed)
        await job.value
        XCTAssertEqual(queue.entries.map(\.state), [.completed])
    }

    func testBufferedContinuousPrintingJournalsTwoGroupsAndSavesPartialCumulativeProofAtomically() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
        let queue = queue(storage), entries = try labels(copies: 6)
        try queue.replace(with: entries)
        printer.steps = [.send([0, 1]), .send([2, 3]), .confirm([0, 1, 2]),
                         .send([4, 5]), .confirm([3, 4, 5])]
        printer.onSend = { pages in
            let expected: [LabelQueueState]
            switch pages {
            case [0, 1]: expected = [.sending, .sending, .pending, .pending, .pending, .pending]
            case [2, 3]: expected = [.sending, .sending, .sending, .sending, .pending, .pending]
            default: expected = [.completed, .completed, .completed, .sending, .sending, .sending]
            }
            XCTAssertEqual(try? storage.entries().map(\.state), expected)
            XCTAssertTrue(queue.isPrinting)
        }
        printer.onConfirm = { pages in
            XCTAssertEqual(try? storage.entries().map(\.state), pages == [0, 1, 2]
                ? [.completed, .completed, .completed, .sending, .pending, .pending]
                : Array(repeating: .completed, count: 6))
        }
        await queue.start(using: printer)
        XCTAssertEqual(printer.jobs, [entries.map(\.raster)])
        XCTAssertEqual(printer.batchCalls, 0, "The continuous capability takes precedence over the older batch path")
        XCTAssertEqual(printer.singleLabelCalls, 0)
        XCTAssertEqual(printer.dispatched, [[0, 1], [2, 3], [4, 5]])
        XCTAssertEqual(queue.completedCount, 6)
        XCTAssertEqual(storage.writeAttempts, 6, "Each group marker and each cumulative receipt is saved once")
        XCTAssertNil(queue.error)
        let restored = self.queue(storage)
        await restored.start(using: printer)
        XCTAssertEqual(printer.jobs.count, 1, "Confirmed copies never replay after reopening")
    }

    func testBufferedContinuousSnapshotMapsOnlyPendingCopiesAndPreservesPreviousOutcomes() async throws {
        var entries = try labels(copies: 5)
        entries[0].state = .completed
        entries[2].state = .failed
        entries[2].lastIssue = .printerNotReady
        let storage = LabelQueueTestStorage(entries: entries), queue = queue(storage)
        let printer = LabelQueueTestContinuousPrinter()
        printer.steps = [.send([0, 1]), .confirm([0]), .finish(.uncertain(.connectionLost))]
        await queue.start(using: printer)
        XCTAssertEqual(printer.jobs, [[entries[1].raster, entries[3].raster, entries[4].raster]])
        XCTAssertEqual(queue.entries.map(\.id), entries.map(\.id))
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .completed, .failed, .uncertain, .pending])
        XCTAssertEqual(queue.entries[2].lastIssue, .printerNotReady)
        XCTAssertEqual(queue.entries[3].lastIssue, .connectionLost)
        XCTAssertEqual(try storage.entries(), queue.entries)
    }

    func testBufferedFailurePreservesPhysicalProofAndMarksEveryRemainingInFlightCopyUncertain() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
        let queue = queue(storage), entries = try labels(copies: 18)
        try queue.replace(with: entries)
        printer.steps = [.send(Array(0..<8)), .send(Array(8..<16)), .confirm(Array(0..<5)),
                         .finish(.uncertain(.responseTimeout))]
        await queue.start(using: printer)
        XCTAssertEqual(queue.entries.map(\.state), Array(repeating: .completed, count: 5)
            + Array(repeating: .uncertain, count: 11) + [.pending, .pending])
        XCTAssertTrue(queue.entries[5..<16].allSatisfy { $0.lastIssue == .responseTimeout })
        XCTAssertTrue(queue.entries[16...].allSatisfy { $0.lastIssue == nil })
        XCTAssertEqual(try storage.entries(), queue.entries)
        let restored = self.queue(storage)
        XCTAssertEqual(restored.entries, queue.entries)
        XCTAssertEqual(printer.jobs.count, 1)
        XCTAssertThrowsError(try restored.retry(ids: Set(entries[5..<16].map(\.id)))) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .acknowledgeUncertain)
        }
        try restored.retry(ids: [entries[5].id], acknowledgeUncertain: true)
        XCTAssertEqual(printer.jobs.count, 1, "Acknowledging a retry never starts it")
        XCTAssertEqual(restored.entries[5].state, .pending)
        XCTAssertEqual(restored.entries[6].state, .uncertain)
    }

    func testBufferedJournalWithNoDispatchedPhysicalCommandCanBeReportedNotSent() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
        let queue = queue(storage)
        try queue.replace(with: labels(copies: 5))
        printer.steps = [.prepare([0, 1, 2]), .finish(.notSent(.notConnected))]
        await queue.start(using: printer)
        XCTAssertTrue(printer.dispatched.isEmpty)
        XCTAssertEqual(queue.entries.map(\.state), [.failed, .failed, .failed, .pending, .pending])
        XCTAssertTrue(queue.entries.prefix(3).allSatisfy { $0.lastIssue == .notConnected })
        XCTAssertEqual(try storage.entries(), queue.entries)
    }

    func testRestartRecoversEveryBufferedSendingMarkerWithoutPrintingOrChangingReceipts() async throws {
        var entries = try labels(copies: 8)
        entries[0].state = .completed
        for index in 1...6 { entries[index].state = .sending }
        let storage = LabelQueueTestStorage(entries: entries), printer = LabelQueueTestContinuousPrinter()
        let queue = queue(storage)
        XCTAssertTrue(queue.isLoaded)
        XCTAssertEqual(queue.entries.map(\.state), [.completed] + Array(repeating: .uncertain, count: 6) + [.pending])
        XCTAssertTrue(queue.entries[1...6].allSatisfy { $0.lastIssue == .connectionLost })
        XCTAssertEqual(try storage.entries(), queue.entries)
        XCTAssertEqual(storage.writeAttempts, 1, "Recovery saves every interrupted copy in one update")
        XCTAssertTrue(printer.jobs.isEmpty)
        XCTAssertThrowsError(try queue.retry(ids: Set(entries[1...6].map(\.id)))) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .acknowledgeUncertain)
        }
    }

    func testBufferedSendingSaveFailurePreventsNextGroupBytesAndLeavesRecoveryMarkersIntact() async throws {
        for failAfterPersist in [false, true] {
            let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
            let queue = queue(storage)
            try queue.replace(with: labels(copies: 6))
            storage.failOnWrite = 3 // Second group's atomic sending marker.
            storage.failAfterPersist = failAfterPersist
            printer.steps = [.send([0, 1]), .send([2, 3]), .send([4, 5])]
            await queue.start(using: printer)
            XCTAssertEqual(printer.dispatched, [[0, 1]])
            XCTAssertFalse(queue.isLoaded)
            XCTAssertFalse(queue.canStart)
            XCTAssertEqual(queue.entries.map(\.state), [.sending, .sending, .pending, .pending, .pending, .pending])
            XCTAssertEqual(storage.writeAttempts, 3, "No status write follows a failed durable marker")
            storage.failOnWrite = nil
            queue.reload()
            XCTAssertEqual(queue.entries.map(\.state), failAfterPersist
                ? [.uncertain, .uncertain, .uncertain, .uncertain, .pending, .pending]
                : [.uncertain, .uncertain, .pending, .pending, .pending, .pending])
            XCTAssertEqual(printer.jobs.count, 1)
        }
    }

    func testBufferedCumulativeCompletionSaveFailureRetainsAllObservedProofAndStopsFutureWrites() async throws {
        for failAfterPersist in [false, true] {
            let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
            let queue = queue(storage)
            try queue.replace(with: labels(copies: 6))
            storage.failOnWrite = 4 // One receipt proves three copies together.
            storage.failAfterPersist = failAfterPersist
            printer.steps = [.send([0, 1]), .send([2, 3]), .confirm([0, 1, 2]), .send([4, 5])]
            await queue.start(using: printer)
            XCTAssertEqual(printer.dispatched, [[0, 1], [2, 3]])
            XCTAssertEqual(queue.entries.map(\.state), [.completed, .completed, .completed, .sending, .pending, .pending])
            XCTAssertFalse(queue.isLoaded)
            XCTAssertFalse(queue.canStart)
            XCTAssertEqual(storage.writeAttempts, 4)
            await queue.start(using: printer)
            XCTAssertEqual(printer.jobs.count, 1)
            storage.failOnWrite = nil
            queue.reload()
            XCTAssertEqual(queue.entries.map(\.state), failAfterPersist
                ? [.completed, .completed, .completed, .uncertain, .pending, .pending]
                : [.uncertain, .uncertain, .uncertain, .uncertain, .pending, .pending])
            XCTAssertEqual(printer.dispatched.count, 2)
        }
    }

    func testBufferedStopOrCancellationStillPersistsLateCumulativeProofBeforeResolvingRemainder() async throws {
        for cancelTask in [false, true] {
            let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
            let stalePrinter = LabelQueueTestPrinter(), queue = queue(storage)
            try queue.replace(with: labels(copies: 5))
            printer.steps = [.send([0, 1]), .send([2, 3]), .hold, .confirm([0, 1, 2]), .send([4])]
            printer.releaseOnCancel = cancelTask
            let job = Task { await queue.start(using: printer) }
            try await printer.waitUntilHeld()
            await queue.start(using: stalePrinter)
            XCTAssertTrue(stalePrinter.rasters.isEmpty)
            if cancelTask { job.cancel() }
            else {
                queue.stop(using: stalePrinter)
                queue.stop(using: stalePrinter)
                printer.release()
            }
            await job.value
            XCTAssertEqual(printer.cancellations, 1)
            XCTAssertEqual(stalePrinter.cancellations, 0)
            XCTAssertEqual(printer.dispatched, [[0, 1], [2, 3]])
            XCTAssertEqual(queue.entries.map(\.state), [.completed, .completed, .completed, .uncertain, .pending])
            XCTAssertEqual(queue.entries[3].lastIssue, .cancelled)
            XCTAssertEqual(try storage.entries(), queue.entries)
            XCTAssertFalse(queue.isPrinting)
        }
    }

    func testBufferedApprovalChecksWholeGroupBeforeAnyMemberCanBeSent() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
        let entries = try labels(copies: 4)
        var checked: [UUID] = []
        let queue = LabelPrintQueue(url: location(), read: { _ in try storage.read() },
            write: { data, _ in try storage.write(data) }, approvalIssue: { entry in
                checked.append(entry.id)
                return [entries[1].id, entries[2].id].contains(entry.id) ? "Approve this updated tag first." : nil
            })
        try queue.replace(with: entries)
        printer.steps = [.send([0, 1, 2])]
        await queue.start(using: printer)
        XCTAssertEqual(checked, entries.prefix(3).map(\.id))
        XCTAssertTrue(printer.dispatched.isEmpty)
        XCTAssertEqual(queue.entries.map(\.state), [.pending, .failed, .failed, .pending])
        XCTAssertEqual(queue.error, "Approve this updated tag first.")
        XCTAssertEqual(storage.writeAttempts, 2)
        XCTAssertEqual(try storage.entries(), queue.entries)
    }

    func testBufferedLaterApprovalRejectionPreservesItsMessageAndLeavesUnsentMembersPending() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
        let entries = try labels(copies: 5)
        let queue = LabelPrintQueue(url: location(), read: { _ in try storage.read() },
            write: { data, _ in try storage.write(data) }, approvalIssue: {
                $0.id == entries[3].id ? "The fourth tag needs a new approval." : nil
            })
        try queue.replace(with: entries)
        printer.steps = [.send([0, 1]), .send([2, 3])]
        await queue.start(using: printer)
        XCTAssertEqual(printer.dispatched, [[0, 1]])
        XCTAssertEqual(queue.entries.map(\.state), [.uncertain, .uncertain, .pending, .failed, .pending])
        XCTAssertEqual(queue.error, "The fourth tag needs a new approval.")
        XCTAssertEqual(queue.entries[3].lastIssue, .invalidLabel)
        XCTAssertEqual(try storage.entries(), queue.entries)
    }

    func testBufferedGroupsRejectEmptyDuplicateSkippedAndOversizedIndicesBeforeDispatch() async throws {
        for pages in [[], [0, 0], [1], [Int.max], Array(0..<9)] {
            let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
            let queue = queue(storage), entries = try labels(copies: 10)
            try queue.replace(with: entries)
            printer.steps = [.send(pages)]
            await queue.start(using: printer)
            XCTAssertTrue(printer.dispatched.isEmpty)
            XCTAssertEqual(queue.entries, entries)
            XCTAssertEqual(storage.writeAttempts, 1)
            XCTAssertNotNil(queue.error)
        }
    }

    func testBufferedWindowRejectsMoreThanSixteenUnconfirmedCopiesWithoutSendingFutureGroup() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
        let queue = queue(storage)
        try queue.replace(with: labels(copies: 18))
        printer.steps = [.send(Array(0..<8)), .send(Array(8..<16)), .send([16, 17])]
        await queue.start(using: printer)
        XCTAssertEqual(printer.dispatched.count, 2)
        XCTAssertEqual(queue.entries.map(\.state), Array(repeating: .uncertain, count: 16) + [.pending, .pending])
        XCTAssertEqual(try storage.entries(), queue.entries)
    }

    func testBufferedCompletionRequiresAContiguousUnconfirmedPrefix() async throws {
        for proof in [[], [1], [0, 0], [0, 1, 2, 3, 4]] {
            let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
            let queue = queue(storage)
            try queue.replace(with: labels(copies: 5))
            printer.steps = [.send([0, 1]), .send([2, 3]), .confirm(proof)]
            await queue.start(using: printer)
            XCTAssertEqual(queue.entries.map(\.state), [.uncertain, .uncertain, .uncertain, .uncertain, .pending])
            XCTAssertEqual(queue.completedCount, 0)
            XCTAssertEqual(try storage.entries(), queue.entries)
        }
    }

    func testBufferedTaskSuccessCannotSubstituteForPhysicalCompletionCallbacks() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
        let queue = queue(storage)
        try queue.replace(with: labels(copies: 3))
        printer.steps = [.send([0, 1])]
        await queue.start(using: printer)
        XCTAssertEqual(queue.entries.map(\.state), [.uncertain, .uncertain, .pending])
        XCTAssertTrue(queue.entries.prefix(2).allSatisfy { $0.lastIssue == .unsupportedResponse })
        XCTAssertEqual(try storage.entries(), queue.entries)
    }

    func testBufferedLateCallbacksCannotMutateANewerPrintingSession() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
        let queue = queue(storage)
        try queue.replace(with: labels(copies: 2))
        printer.steps = [.send([0, 1]), .confirm([0, 1])]
        await queue.start(using: printer)
        let oldBefore = try XCTUnwrap(printer.savedBeforePages)
        let oldAfter = try XCTUnwrap(printer.savedAfterPages)
        try queue.replace(with: labels(copies: 2))
        printer.steps = [.send([0, 1]), .hold, .confirm([0, 1])]
        let job = Task { await queue.start(using: printer) }
        try await printer.waitUntilHeld()
        let bytes = storage.bytes
        do { try await oldBefore([0, 1]); XCTFail("A stale group marker must fail") }
        catch { XCTAssertEqual(error as? LabelPrinterIssue, .cancelled) }
        do { try await oldAfter([0, 1]); XCTFail("A stale completion must fail") }
        catch { XCTAssertEqual(error as? LabelPrinterIssue, .cancelled) }
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(queue.entries.map(\.state), [.sending, .sending])
        printer.release()
        await job.value
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .completed])
    }

    func testInterruptedCopyRestoresUncertainAndRequiresAcknowledgementAndSeparateStart() async throws {
        var entries = try labels()
        entries[0].state = .completed
        entries[1].state = .sending
        let storage = LabelQueueTestStorage(entries: entries), printer = LabelQueueTestPrinter()
        let queue = queue(storage)
        XCTAssertTrue(queue.isLoaded)
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .uncertain, .pending])
        XCTAssertEqual(queue.entries[1].lastIssue, .connectionLost)
        XCTAssertEqual(try storage.entries(), queue.entries)
        XCTAssertEqual(storage.writeAttempts, 1)
        XCTAssertTrue(printer.rasters.isEmpty)
        let before = storage.bytes
        XCTAssertThrowsError(try queue.retry(ids: [entries[1].id])) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .acknowledgeUncertain)
        }
        XCTAssertEqual(storage.bytes, before)
        try queue.retry(ids: [entries[1].id], acknowledgeUncertain: true)
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .pending, .pending])
        XCTAssertNil(queue.entries[1].lastIssue)
        XCTAssertTrue(printer.rasters.isEmpty, "Retry selection never starts a printer")
        await queue.start(using: printer)
        XCTAssertEqual(printer.rasters.count, 2)
        XCTAssertEqual(queue.completedCount, 3)
        XCTAssertEqual(queue.entries.map(\.id), entries.map(\.id))
    }

    func testFailedInterruptedRecoveryPreservesBytesAndBlocksAllPrintingUntilReload() async throws {
        var entries = try labels(copies: 2)
        entries[0].state = .sending
        let storage = LabelQueueTestStorage(entries: entries), printer = LabelQueueTestPrinter()
        let original = storage.bytes
        storage.failOnWrite = 1
        let queue = queue(storage)
        XCTAssertFalse(queue.isLoaded)
        XCTAssertFalse(queue.canStart)
        XCTAssertEqual(queue.entries.map(\.state), [.uncertain, .pending])
        XCTAssertEqual(storage.bytes, original)
        await queue.start(using: printer)
        XCTAssertTrue(printer.rasters.isEmpty)
        XCTAssertThrowsError(try queue.retry(ids: [entries[0].id], acknowledgeUncertain: true)) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .notLoaded)
        }
        storage.failOnWrite = nil
        queue.reload()
        XCTAssertTrue(queue.isLoaded)
        XCTAssertEqual(queue.entries.map(\.state), [.uncertain, .pending])
        XCTAssertEqual(try storage.entries(), queue.entries)
        XCTAssertTrue(printer.rasters.isEmpty)
    }

    func testSendingMarkerWriteFailureBeforeOrAfterAtomicReplacementNeverSendsBytes() async throws {
        for failAfterPersist in [false, true] {
            let storage = LabelQueueTestStorage(), printer = LabelQueueTestPrinter()
            let queue = queue(storage), entries = try labels(copies: 2)
            try queue.replace(with: entries)
            storage.failOnWrite = 2
            storage.failAfterPersist = failAfterPersist
            await queue.start(using: printer)
            XCTAssertTrue(printer.rasters.isEmpty)
            XCTAssertFalse(queue.isLoaded)
            XCTAssertFalse(queue.isPrinting)
            XCTAssertFalse(queue.canStart)
            XCTAssertNotNil(queue.error)
            await queue.start(using: printer)
            XCTAssertEqual(storage.writeAttempts, 2, "A failed save must not automatically retry")
            XCTAssertThrowsError(try queue.clear()) {
                XCTAssertEqual($0 as? LabelPrintQueueFailure, .notLoaded)
            }
            storage.failOnWrite = nil
            queue.reload()
            XCTAssertEqual(queue.entries.map(\.state), failAfterPersist ? [.uncertain, .pending] : [.pending, .pending])
            XCTAssertTrue(printer.rasters.isEmpty)
        }
    }

    func testCompletionWriteFailureBeforeOrAfterAtomicReplacementStopsBeforeNextCopy() async throws {
        for failAfterPersist in [false, true] {
            let storage = LabelQueueTestStorage(), printer = LabelQueueTestPrinter()
            let queue = queue(storage), entries = try labels(copies: 2)
            try queue.replace(with: entries)
            storage.failOnWrite = 3
            storage.failAfterPersist = failAfterPersist
            await queue.start(using: printer)
            XCTAssertEqual(printer.rasters.count, 1)
            XCTAssertEqual(queue.entries.map(\.state), [.completed, .pending], "The observed result stays visible")
            XCTAssertFalse(queue.isLoaded)
            XCTAssertFalse(queue.isPrinting)
            XCTAssertFalse(queue.canStart)
            await queue.start(using: printer)
            XCTAssertEqual(printer.rasters.count, 1)
            storage.failOnWrite = nil
            queue.reload()
            XCTAssertTrue(queue.isLoaded)
            XCTAssertEqual(queue.entries.map(\.state), failAfterPersist ? [.completed, .pending] : [.uncertain, .pending])
            XCTAssertEqual(printer.rasters.count, 1, "Recovery never emits bytes")
            if !failAfterPersist {
                XCTAssertThrowsError(try queue.retry(ids: [entries[0].id])) {
                    XCTAssertEqual($0 as? LabelPrintQueueFailure, .acknowledgeUncertain)
                }
            }
        }
    }

    func testKnownNotSentPausesBatchAndOnlySelectedFailedCopyCanBeRetried() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestPrinter()
        let queue = queue(storage), entries = try labels()
        try queue.replace(with: entries)
        printer.outcomes = [.completed, .notSent(.printerNotReady)]
        await queue.start(using: printer)
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .failed, .pending])
        XCTAssertEqual(queue.failedCount, 1)
        XCTAssertEqual(queue.entries[1].lastIssue, .printerNotReady)
        XCTAssertEqual(printer.rasters.count, 2)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertNotNil(queue.error)
        let before = storage.bytes, writes = storage.writeAttempts
        let selections: [Set<UUID>] = [[], [UUID()], [entries[0].id], [entries[0].id, entries[1].id], [entries[2].id]]
        for ids in selections {
            XCTAssertThrowsError(try queue.retry(ids: ids, acknowledgeUncertain: true)) {
                XCTAssertEqual($0 as? LabelPrintQueueFailure, .invalidSelection)
            }
        }
        XCTAssertEqual(storage.bytes, before)
        XCTAssertEqual(storage.writeAttempts, writes)
        try queue.retry(ids: [entries[1].id])
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .pending, .pending])
        XCTAssertEqual(printer.rasters.count, 2)
        XCTAssertNil(queue.error)
        await queue.start(using: printer)
        XCTAssertEqual(queue.completedCount, 3)
        XCTAssertEqual(printer.rasters.count, 4)
    }

    func testUncertainRetryRequiresExplicitAcknowledgementForEverySelectedUnknownCopy() throws {
        var entries = try labels()
        entries[0].state = .uncertain; entries[0].lastIssue = .responseTimeout
        entries[1].state = .failed; entries[1].lastIssue = .notConnected
        let storage = LabelQueueTestStorage(entries: entries), queue = queue(storage)
        let before = storage.bytes
        XCTAssertThrowsError(try queue.retry(ids: [entries[0].id, entries[1].id])) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .acknowledgeUncertain)
        }
        XCTAssertEqual(queue.entries, entries)
        XCTAssertEqual(storage.bytes, before)
        try queue.retry(ids: [entries[1].id])
        XCTAssertEqual(queue.entries.map(\.state), [.uncertain, .pending, .pending])
        try queue.retry(ids: [entries[0].id], acknowledgeUncertain: true)
        XCTAssertEqual(queue.entries.map(\.state), [.pending, .pending, .pending])
        XCTAssertTrue(queue.entries.allSatisfy { $0.lastIssue == nil })
        XCTAssertFalse(queue.isPrinting)
    }

    func testUnconfirmedTransportCompletionPersistsUncertainAndPausesBeforeNextCopy() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestPrinter()
        let queue = queue(storage), entries = try labels(copies: 2)
        try queue.replace(with: entries)
        printer.outcomes = [.uncertain(.responseTimeout)]
        await queue.start(using: printer)
        XCTAssertEqual(printer.rasters.count, 1)
        XCTAssertEqual(queue.entries.map(\.state), [.uncertain, .pending])
        XCTAssertEqual(queue.entries[0].lastIssue, .responseTimeout)
        XCTAssertEqual(try storage.entries(), queue.entries)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertEqual(queue.uncertainCount, 1)
        XCTAssertThrowsError(try queue.retry(ids: [entries[0].id])) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .acknowledgeUncertain)
        }
        XCTAssertEqual(printer.rasters.count, 1)
    }

    func testDoubleStartAndRepeatedStopCannotDuplicateOrCancelTheWrongTransport() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestPrinter(), stalePrinter = LabelQueueTestPrinter()
        let queue = queue(storage), entries = try labels(copies: 2)
        try queue.replace(with: entries)
        printer.held = true
        let job = Task { await queue.start(using: printer) }
        try await printer.waitForSends(1)
        await queue.start(using: stalePrinter)
        XCTAssertTrue(stalePrinter.rasters.isEmpty)
        let currentBytes = storage.bytes
        XCTAssertThrowsError(try queue.replace(with: entries)) { XCTAssertEqual($0 as? LabelPrintQueueFailure, .printing) }
        XCTAssertThrowsError(try queue.clear()) { XCTAssertEqual($0 as? LabelPrintQueueFailure, .printing) }
        XCTAssertThrowsError(try queue.clearCompleted()) { XCTAssertEqual($0 as? LabelPrintQueueFailure, .printing) }
        XCTAssertThrowsError(try queue.retry(ids: [entries[0].id])) { XCTAssertEqual($0 as? LabelPrintQueueFailure, .printing) }
        XCTAssertThrowsError(try queue.discardSavedQueue()) { XCTAssertEqual($0 as? LabelPrintQueueFailure, .printing) }
        queue.reload()
        XCTAssertEqual(storage.bytes, currentBytes)
        queue.stop(using: stalePrinter)
        queue.stop(using: stalePrinter)
        XCTAssertEqual(printer.cancellations, 1)
        XCTAssertEqual(stalePrinter.cancellations, 0)
        XCTAssertTrue(queue.isPrinting, "Stop waits for the active transport's result")
        printer.finish(0, with: .completed)
        await job.value
        XCTAssertEqual(queue.entries.map(\.state), [.completed, .pending])
        XCTAssertFalse(queue.isPrinting)
        XCTAssertEqual(printer.rasters.count, 1)
        printer.held = false
        await queue.start(using: printer)
        XCTAssertEqual(queue.completedCount, 2)
        XCTAssertEqual(printer.rasters.count, 2, "Continuing never repeats the confirmed copy")
    }

    func testTaskCancellationCancelsActivePrinterAndPersistsUncertainWithoutAdvancing() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestPrinter()
        let queue = queue(storage), entries = try labels(copies: 2)
        try queue.replace(with: entries)
        printer.held = true
        printer.cancelOutcome = .uncertain(.cancelled)
        let job = Task { await queue.start(using: printer) }
        try await printer.waitForSends(1)
        job.cancel()
        await job.value
        XCTAssertEqual(printer.cancellations, 1)
        XCTAssertEqual(printer.rasters.count, 1)
        XCTAssertEqual(queue.entries.map(\.state), [.uncertain, .pending])
        XCTAssertEqual(queue.entries[0].lastIssue, .cancelled)
        XCTAssertEqual(try storage.entries(), queue.entries)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertTrue(queue.isLoaded)
    }

    func testAlreadyCancelledStartDoesNotWriteSendingMarkerOrCallPrinter() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestPrinter()
        let queue = queue(storage), entries = try labels(copies: 1)
        try queue.replace(with: entries)
        let job = Task { await queue.start(using: printer) }
        job.cancel()
        await job.value
        XCTAssertEqual(queue.entries, entries)
        XCTAssertTrue(printer.rasters.isEmpty)
        XCTAssertEqual(storage.writeAttempts, 1)
        XCTAssertFalse(queue.isPrinting)
    }

    func testRetryWriteFailureRetainsDurableUnknownAndRequiresReloadBeforeAnotherMutation() throws {
        var entries = try labels(copies: 1)
        entries[0].state = .uncertain; entries[0].lastIssue = .connectionLost
        let storage = LabelQueueTestStorage(entries: entries), queue = queue(storage)
        storage.failOnWrite = 1
        let bytes = storage.bytes
        XCTAssertThrowsError(try queue.retry(ids: [entries[0].id], acknowledgeUncertain: true)) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .saveFailed)
        }
        XCTAssertEqual(queue.entries, entries)
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertFalse(queue.isLoaded)
        XCTAssertThrowsError(try queue.retry(ids: [entries[0].id], acknowledgeUncertain: true)) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .notLoaded)
        }
        storage.failOnWrite = nil
        queue.reload()
        XCTAssertTrue(queue.isLoaded)
        XCTAssertEqual(queue.entries, entries)
    }

    func testClearIfUnprintedDurablyClearsPendingAndKnownUnsentFailures() throws {
        let clearable: [[LabelQueueState]] = [[.pending, .pending], [.failed, .failed], [.pending, .failed]]
        for states in clearable {
            var entries = try labels(copies: states.count)
            for index in entries.indices {
                entries[index].state = states[index]
                entries[index].lastIssue = states[index] == .failed ? .notConnected : nil
            }
            let storage = LabelQueueTestStorage(entries: entries), queue = queue(storage)
            XCTAssertTrue(try queue.clearIfUnprinted())
            XCTAssertTrue(queue.entries.isEmpty)
            XCTAssertTrue(queue.isLoaded)
            XCTAssertFalse(queue.canStart)
            XCTAssertEqual(try storage.entries(), [])
            XCTAssertEqual(self.queue(storage).entries, [], "Leaving the screen must clear the durable queue too")
            XCTAssertEqual(storage.writeAttempts, 1)
            XCTAssertFalse(try queue.clearIfUnprinted())
            XCTAssertEqual(storage.writeAttempts, 1, "Repeated disappearance callbacks must not rewrite the empty queue")
        }
    }

    func testClearIfUnprintedDoesNotCreateOrRewriteAnEmptyQueue() throws {
        for persisted in [false, true] {
            let storage = persisted ? LabelQueueTestStorage(entries: []) : LabelQueueTestStorage()
            let queue = queue(storage), before = storage.bytes
            for _ in 0..<3 { XCTAssertFalse(try queue.clearIfUnprinted()) }
            XCTAssertTrue(queue.isLoaded)
            XCTAssertTrue(queue.entries.isEmpty)
            XCTAssertEqual(storage.bytes, before)
            XCTAssertEqual(storage.writeAttempts, 0)
        }
    }

    func testClearIfUnprintedPreservesCompletedUncertainAndRecoveredSendingReceipts() throws {
        let protected: [[LabelQueueState]] = [
            [.completed], [.uncertain], [.sending], [.completed, .pending],
            [.pending, .uncertain], [.failed, .completed, .pending]
        ]
        for states in protected {
            var entries = try labels(copies: states.count)
            for index in entries.indices {
                entries[index].state = states[index]
                switch states[index] {
                case .uncertain: entries[index].lastIssue = .connectionLost
                case .failed: entries[index].lastIssue = .notConnected
                default: entries[index].lastIssue = nil
                }
            }
            let storage = LabelQueueTestStorage(entries: entries), queue = queue(storage)
            // A restored sending marker is first durably recovered as uncertain.
            let recovered = queue.entries, bytes = storage.bytes, writes = storage.writeAttempts
            XCTAssertFalse(try queue.clearIfUnprinted())
            XCTAssertEqual(queue.entries, recovered)
            XCTAssertEqual(storage.bytes, bytes)
            XCTAssertEqual(storage.writeAttempts, writes)
            XCTAssertEqual(self.queue(storage).entries, recovered)
            XCTAssertEqual(storage.writeAttempts, writes, "Recovery receipts survive reopening without another write")
        }
    }

    func testClearIfUnprintedLeavesUnreadableAndFailedReloadStorageUntouched() throws {
        let corrupt = Data("unreadable queue".utf8)
        let corruptStorage = LabelQueueTestStorage(bytes: corrupt), unreadable = self.queue(corruptStorage)
        XCTAssertFalse(unreadable.isLoaded)
        XCTAssertFalse(try unreadable.clearIfUnprinted())
        XCTAssertEqual(corruptStorage.bytes, corrupt)
        XCTAssertEqual(corruptStorage.writeAttempts, 0)

        let entries = try labels(copies: 1)
        let storage = LabelQueueTestStorage(entries: entries), queue = queue(storage)
        let before = storage.bytes
        storage.failRead = true
        queue.reload()
        XCTAssertFalse(queue.isLoaded)
        XCTAssertFalse(try queue.clearIfUnprinted())
        XCTAssertEqual(queue.entries, entries)
        XCTAssertEqual(storage.bytes, before)
        XCTAssertEqual(storage.writeAttempts, 0)
        storage.failRead = false
        queue.reload()
        XCTAssertEqual(queue.entries, entries)
    }

    func testClearIfUnprintedSaveFailureKeepsOriginalWorkAndRequiresReload() throws {
        let entries = try labels(copies: 2)
        let storage = LabelQueueTestStorage(entries: entries), queue = queue(storage)
        let before = storage.bytes
        storage.failOnWrite = 1
        XCTAssertThrowsError(try queue.clearIfUnprinted()) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .saveFailed)
        }
        XCTAssertEqual(queue.entries, entries)
        XCTAssertEqual(storage.bytes, before)
        XCTAssertFalse(queue.isLoaded)
        XCTAssertNotNil(queue.error)
        XCTAssertFalse(try queue.clearIfUnprinted())
        XCTAssertEqual(storage.writeAttempts, 1, "An automatic cleanup must not retry a failed save")
        storage.failOnWrite = nil
        queue.reload()
        XCTAssertTrue(queue.isLoaded)
        XCTAssertEqual(queue.entries, entries)
        XCTAssertTrue(try queue.clearIfUnprinted())
        XCTAssertEqual(try storage.entries(), [])
        XCTAssertEqual(storage.writeAttempts, 2)
    }

    func testClearIfUnprintedWaitsForActiveTransportEvenBeforeAnyCopyIsDispatched() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestContinuousPrinter()
        let queue = queue(storage), entries = try labels(copies: 2)
        try queue.replace(with: entries)
        printer.steps = [.hold, .send([0, 1]), .confirm([0, 1])]
        defer { printer.release() }
        let job = Task { await queue.start(using: printer) }
        try await printer.waitUntilHeld()
        let bytes = storage.bytes, writes = storage.writeAttempts
        XCTAssertTrue(queue.isPrinting)
        XCTAssertEqual(queue.entries, entries, "The active driver has not yet journaled a sending marker")
        XCTAssertFalse(try queue.clearIfUnprinted())
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(storage.writeAttempts, writes)
        queue.stop(using: printer)
        XCTAssertTrue(queue.isPrinting, "Stop still waits for the driver's result")
        XCTAssertFalse(try queue.clearIfUnprinted())
        printer.release()
        await job.value
        XCTAssertTrue(printer.dispatched.isEmpty)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertTrue(queue.entries.isEmpty, "The pending clear runs only after the active driver has stopped")
        XCTAssertEqual(try storage.entries(), [])
        XCTAssertFalse(try queue.clearIfUnprinted(), "The settled cleanup is already durable")
    }

    func testDeferredClearIfUnprintedClearsKnownUnsentResultAfterTransportSettles() async throws {
        let storage = LabelQueueTestStorage(), printer = LabelQueueTestPrinter()
        let queue = queue(storage)
        try queue.replace(with: labels(copies: 2))
        printer.held = true
        defer { printer.finish(0, with: .notSent(.notConnected)) }
        let job = Task { await queue.start(using: printer) }
        try await printer.waitForSends(1)
        let bytes = storage.bytes, writes = storage.writeAttempts
        XCTAssertEqual(queue.entries.map(\.state), [.sending, .pending])
        XCTAssertFalse(try queue.clearIfUnprinted())
        XCTAssertTrue(queue.isPrinting)
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(storage.writeAttempts, writes)
        printer.finish(0, with: .notSent(.notConnected))
        await job.value
        XCTAssertFalse(queue.isPrinting)
        XCTAssertTrue(queue.isLoaded)
        XCTAssertTrue(queue.entries.isEmpty, "Known-unsent failed and pending copies are cleared after settlement")
        XCTAssertFalse(queue.lastRunCompletedSuccessfully)
        XCTAssertEqual(try storage.entries(), [])
        XCTAssertEqual(self.queue(storage).entries, [])
        XCTAssertEqual(printer.rasters.count, 1, "Cleanup never dispatches the next copy")
        let replacement = try labels(copies: 1)
        try queue.replace(with: replacement)
        queue.reload()
        XCTAssertEqual(queue.entries, replacement, "The old session's cleanup intent cannot erase a later batch")
        XCTAssertEqual(printer.rasters.count, 1)
    }

    func testClearIfUnprintedPreservesLateCompletionOrUncertainOutcomeAfterStop() async throws {
        for outcome in [LabelSendOutcome.completed, .uncertain(.cancelled)] {
            let storage = LabelQueueTestStorage(), printer = LabelQueueTestPrinter()
            let queue = queue(storage)
            try queue.replace(with: labels(copies: 2))
            printer.held = true
            defer { printer.finish(0, with: .uncertain(.cancelled)) }
            let job = Task { await queue.start(using: printer) }
            try await printer.waitForSends(1)
            let before = storage.bytes, writes = storage.writeAttempts
            XCTAssertEqual(queue.entries.map(\.state), [.sending, .pending])
            XCTAssertFalse(try queue.clearIfUnprinted())
            queue.stop(using: printer)
            XCTAssertFalse(try queue.clearIfUnprinted())
            XCTAssertEqual(storage.bytes, before)
            XCTAssertEqual(storage.writeAttempts, writes)
            printer.finish(0, with: outcome)
            await job.value
            let state: LabelQueueState = outcome == .completed ? .completed : .uncertain
            XCTAssertEqual(queue.entries.map(\.state), [state, .pending])
            let finished = queue.entries, durable = storage.bytes, finishedWrites = storage.writeAttempts
            XCTAssertFalse(try queue.clearIfUnprinted())
            XCTAssertEqual(queue.entries, finished)
            XCTAssertEqual(storage.bytes, durable)
            XCTAssertEqual(storage.writeAttempts, finishedWrites)
            XCTAssertEqual(self.queue(storage).entries, finished)
            XCTAssertEqual(printer.rasters.count, 1, "Closing must not dispatch or replay the next label")
        }
    }

    func testUnfinishedBatchRequiresExplicitClearAndClearCompletedPreservesFailuresAndPending() throws {
        var entries = try labels()
        entries[0].state = .completed
        entries[1].state = .failed; entries[1].lastIssue = .notConnected
        let storage = LabelQueueTestStorage(entries: entries), queue = queue(storage)
        let replacement = try labels(copies: 1)
        XCTAssertThrowsError(try queue.replace(with: replacement)) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .unfinishedQueue)
        }
        try queue.clearCompleted()
        XCTAssertEqual(queue.entries, Array(entries.dropFirst()))
        XCTAssertEqual(try storage.entries(), queue.entries)
        try queue.clear()
        XCTAssertTrue(queue.entries.isEmpty)
        try queue.replace(with: replacement)
        XCTAssertEqual(queue.entries, replacement)
    }

    func testCorruptUnsupportedDuplicateInvalidAndOversizedQueuesStayUntouchedUntilExplicitDiscard() async throws {
        let entry = try XCTUnwrap(labels(copies: 1).first)
        var invalid = entry; invalid.state = .failed
        let badFiles = try [Data("corrupt JSON".utf8),
            JSONEncoder().encode(LabelQueueTestDocument(version: 99, entries: [])),
            JSONEncoder().encode(LabelQueueTestDocument(entries: [entry, entry])),
            JSONEncoder().encode(LabelQueueTestDocument(entries: [invalid])),
            Data(repeating: 0, count: LabelPrintQueue.maximumBytes + 1)]
        for bytes in badFiles {
            let storage = LabelQueueTestStorage(bytes: bytes), printer = LabelQueueTestPrinter()
            let queue = queue(storage)
            XCTAssertFalse(queue.isLoaded)
            XCTAssertNotNil(queue.error)
            XCTAssertTrue(queue.entries.isEmpty)
            XCTAssertFalse(queue.canStart)
            XCTAssertThrowsError(try queue.replace(with: [entry])) {
                XCTAssertEqual($0 as? LabelPrintQueueFailure, .notLoaded)
            }
            XCTAssertThrowsError(try queue.clear())
            XCTAssertThrowsError(try queue.clearCompleted())
            XCTAssertThrowsError(try queue.retry(ids: [entry.id], acknowledgeUncertain: true))
            await queue.start(using: printer)
            XCTAssertTrue(printer.rasters.isEmpty)
            XCTAssertEqual(storage.writeAttempts, 0)
            XCTAssertEqual(storage.bytes, bytes)
            try queue.discardSavedQueue()
            XCTAssertTrue(queue.isLoaded)
            XCTAssertTrue(queue.entries.isEmpty)
            XCTAssertEqual(try storage.entries(), [])
        }
    }

    func testReadFailureKeepsCurrentEntriesAndReloadRecoversWithoutAutomaticallyPrinting() throws {
        let storage = LabelQueueTestStorage(), queue = queue(storage)
        let entries = try labels(copies: 1)
        try queue.replace(with: entries)
        storage.failRead = true
        queue.reload()
        XCTAssertFalse(queue.isLoaded)
        XCTAssertEqual(queue.entries, entries)
        XCTAssertThrowsError(try queue.clear())
        XCTAssertEqual(storage.writeAttempts, 1)
        storage.failRead = false
        queue.reload()
        XCTAssertTrue(queue.isLoaded)
        XCTAssertEqual(queue.entries, entries)
        XCTAssertTrue(queue.canStart)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertEqual(storage.writeAttempts, 1)
    }

    func testQueueLimitRejectsTwoHundredFiftyOneCopiesWithoutChangingSavedQueue() throws {
        let storage = LabelQueueTestStorage(), queue = queue(storage)
        let entries = try (0..<LabelPrintQueue.maximumLabels).map { _ in try labels(copies: 1)[0] }
        try queue.replace(with: entries)
        XCTAssertEqual(queue.pendingCount, 250)
        let before = storage.bytes
        try queue.clear()
        let empty = storage.bytes, writes = storage.writeAttempts
        XCTAssertThrowsError(try queue.replace(with: entries + labels(copies: 1))) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .tooManyLabels)
        }
        XCTAssertTrue(queue.entries.isEmpty)
        XCTAssertEqual(storage.bytes, empty)
        XCTAssertEqual(storage.writeAttempts, writes)
        XCTAssertTrue(queue.isLoaded)
        let tooMany = try JSONEncoder().encode(LabelQueueTestDocument(entries: entries + labels(copies: 1)))
        storage.bytes = tooMany
        queue.reload()
        XCTAssertFalse(queue.isLoaded)
        XCTAssertEqual(storage.bytes, tooMany)
        XCTAssertNotNil(before)
    }

    func testDuplicateAndInvalidPendingReplacementNeverTouchesDurableQueue() throws {
        let storage = LabelQueueTestStorage(), queue = queue(storage)
        let entry = try labels(copies: 1)[0]
        XCTAssertThrowsError(try queue.replace(with: [entry, entry])) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .duplicateIdentity)
        }
        var completed = entry; completed.state = .completed
        XCTAssertThrowsError(try queue.replace(with: [completed])) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .invalidEntry)
        }
        var pendingWithIssue = entry; pendingWithIssue.lastIssue = .writeFailed
        XCTAssertThrowsError(try queue.replace(with: [pendingWithIssue])) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .invalidEntry)
        }
        XCTAssertEqual(storage.writeAttempts, 0)
        XCTAssertNil(storage.bytes)
        XCTAssertTrue(queue.isLoaded)
    }

    func testEncodedByteLimitStopsOversizedUnicodeSnapshotsBeforeCallingWriter() throws {
        // Character limits alone cannot bound UTF-8 storage: each joined family
        // is one Character but occupies many bytes in the persisted JSON.
        let family = "👩‍👩‍👩‍👩‍👩‍👩‍👩‍👩‍👩‍👩"
        let name = String(repeating: family, count: 500)
        XCTAssertEqual(name.count, 500)
        let entries = try (0..<LabelPrintQueue.maximumLabels).map { _ in try labels(copies: 1, name: name)[0] }
        let storage = LabelQueueTestStorage(), queue = queue(storage)
        XCTAssertThrowsError(try queue.replace(with: entries)) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .saveFailed)
        }
        XCTAssertEqual(storage.writeAttempts, 0)
        XCTAssertNil(storage.bytes)
        XCTAssertTrue(queue.entries.isEmpty)
        XCTAssertFalse(queue.isLoaded)
        XCTAssertFalse(queue.canStart)
    }

    func testDirectoryAtQueuePathIsRejectedInsteadOfBeingTreatedAsEmpty() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let queue = LabelPrintQueue(url: url)
        XCTAssertFalse(queue.isLoaded)
        XCTAssertThrowsError(try queue.replace(with: labels(copies: 1))) {
            XCTAssertEqual($0 as? LabelPrintQueueFailure, .notLoaded)
        }
        var directory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &directory))
        XCTAssertTrue(directory.boolValue)
    }
}

private struct LabelQueueTestDocument: Codable {
    var version = 1
    var entries: [LabelQueueEntry]
}

@MainActor private final class LabelQueueTestStorage {
    var bytes: Data?
    var failRead = false
    var failOnWrite: Int?
    var failAfterPersist = false
    private(set) var writeAttempts = 0

    init(bytes: Data? = nil) { self.bytes = bytes }

    convenience init(entries: [LabelQueueEntry]) {
        self.init(bytes: try! JSONEncoder().encode(LabelQueueTestDocument(entries: entries)))
    }

    func read() throws -> Data? {
        if failRead { throw CocoaError(.fileReadNoPermission) }
        return bytes
    }

    func write(_ data: Data) throws {
        writeAttempts += 1
        let fail = failOnWrite == writeAttempts
        if fail && !failAfterPersist { throw CocoaError(.fileWriteOutOfSpace) }
        bytes = data
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
    }

    func entries() throws -> [LabelQueueEntry] {
        try JSONDecoder().decode(LabelQueueTestDocument.self, from: XCTUnwrap(bytes)).entries
    }
}

@MainActor private final class LabelQueueTestPrinter: LabelPrinterSending {
    var held = false
    var outcomes: [LabelSendOutcome] = []
    var cancelOutcome: LabelSendOutcome?
    var onSend: ((Int, LabelRaster) -> Void)?
    private(set) var rasters: [LabelRaster] = []
    private(set) var cancellations = 0
    private var pending: [Int: CheckedContinuation<LabelSendOutcome, Never>] = [:]

    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome {
        let index = rasters.count
        rasters.append(raster)
        onSend?(index, raster)
        if !held { return outcomes.isEmpty ? .completed : outcomes.removeFirst() }
        return await withCheckedContinuation { pending[index] = $0 }
    }

    func cancelPrinting() {
        cancellations += 1
        if let cancelOutcome, let index = pending.keys.min() { finish(index, with: cancelOutcome) }
    }

    func finish(_ index: Int, with outcome: LabelSendOutcome) {
        pending.removeValue(forKey: index)?.resume(returning: outcome)
    }

    func waitForSends(_ count: Int) async throws {
        for _ in 0..<1_000 {
            if rasters.count >= count { return }
            await Task.yield()
        }
        XCTFail("The queue did not call its printer")
        throw CocoaError(.coderReadCorrupt)
    }
}

/// Models the batch driver's physical counter gate: no page is dispatched until
/// beforePage returns, and the next page waits for the durable afterPage return.
@MainActor private final class LabelQueueTestBatchPrinter: LabelBatchPrinterSending {
    typealias PageCallback = @MainActor (Int) async throws -> Void

    var held = false
    var outcomes: [LabelSendOutcome] = []
    var cancelOutcome: LabelSendOutcome?
    var omitCompletionAt: Int?
    var endOutcome = LabelSendOutcome.completed
    var onSend: ((Int, LabelRaster) -> Void)?
    var onCompleted: ((Int) -> Void)?
    private(set) var batches: [[LabelRaster]] = []
    private(set) var rasters: [LabelRaster] = []
    private(set) var singleLabelCalls = 0
    private(set) var cancellations = 0
    private(set) var savedBeforePage: PageCallback?
    private(set) var savedAfterPage: PageCallback?
    private var pending: [Int: CheckedContinuation<LabelSendOutcome, Never>] = [:]

    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome {
        singleLabelCalls += 1
        return .notSent(.unsupportedPrinter)
    }

    func printBatch(_ pages: [LabelRaster], beforePage: @escaping PageCallback,
                    afterPage: @escaping PageCallback) async -> LabelSendOutcome {
        batches.append(pages)
        savedBeforePage = beforePage
        savedAfterPage = afterPage
        for (page, raster) in pages.enumerated() {
            do { try await beforePage(page) }
            catch { return .notSent(error as? LabelPrinterIssue ?? .writeFailed) }
            let sendIndex = rasters.count
            rasters.append(raster)
            onSend?(page, raster)
            let outcome: LabelSendOutcome
            if held {
                outcome = await withCheckedContinuation { pending[sendIndex] = $0 }
            } else {
                outcome = outcomes.isEmpty ? .completed : outcomes.removeFirst()
            }
            guard outcome == .completed else { return outcome }
            if omitCompletionAt == page { return .completed }
            do { try await afterPage(page) }
            catch { return .uncertain(error as? LabelPrinterIssue ?? .writeFailed) }
            onCompleted?(page)
        }
        return endOutcome
    }

    func cancelPrinting() {
        cancellations += 1
        if let cancelOutcome, let index = pending.keys.min() { finish(index, with: cancelOutcome) }
    }

    func finish(_ index: Int, with outcome: LabelSendOutcome) {
        pending.removeValue(forKey: index)?.resume(returning: outcome)
    }

    func waitForSends(_ count: Int) async throws {
        for _ in 0..<1_000 {
            if rasters.count >= count { return }
            await Task.yield()
        }
        XCTFail("The queue did not dispatch the expected batch page")
        throw CocoaError(.coderReadCorrupt)
    }
}

/// A scripted driver separates durable group preparation, physical dispatch and
/// cumulative proof so the queue's crash and cancellation boundaries stay visible.
@MainActor private final class LabelQueueTestContinuousPrinter: LabelContinuousPrinterSending, LabelBatchPrinterSending {
    typealias PagesCallback = @MainActor ([Int]) async throws -> Void
    enum Step {
        case prepare([Int])
        case send([Int])
        case confirm([Int])
        case hold
        case finish(LabelSendOutcome)
    }

    var steps: [Step] = []
    var releaseOnCancel = false
    var onSend: (([Int]) -> Void)?
    var onConfirm: (([Int]) -> Void)?
    private(set) var jobs: [[LabelRaster]] = []
    private(set) var dispatched: [[Int]] = []
    private(set) var batchCalls = 0
    private(set) var singleLabelCalls = 0
    private(set) var cancellations = 0
    private(set) var savedBeforePages: PagesCallback?
    private(set) var savedAfterPages: PagesCallback?
    private var hold: CheckedContinuation<Void, Never>?

    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome {
        singleLabelCalls += 1
        return .notSent(.unsupportedPrinter)
    }

    func printBatch(_ rasters: [LabelRaster], beforePage: @escaping @MainActor (Int) async throws -> Void,
                    afterPage: @escaping @MainActor (Int) async throws -> Void) async -> LabelSendOutcome {
        batchCalls += 1
        return .notSent(.unsupportedPrinter)
    }

    func printContinuously(_ rasters: [LabelRaster], beforePages: @escaping PagesCallback,
                           afterPages: @escaping PagesCallback) async -> LabelSendOutcome {
        jobs.append(rasters)
        savedBeforePages = beforePages
        savedAfterPages = afterPages
        var unconfirmed: Set<Int> = []
        let script = steps
        for step in script {
            switch step {
            case .prepare(let pages):
                do { try await beforePages(pages) }
                catch {
                    let issue = error as? LabelPrinterIssue ?? .writeFailed
                    return unconfirmed.isEmpty ? .notSent(issue) : .uncertain(issue)
                }
            case .send(let pages):
                do { try await beforePages(pages) }
                catch {
                    let issue = error as? LabelPrinterIssue ?? .writeFailed
                    return unconfirmed.isEmpty ? .notSent(issue) : .uncertain(issue)
                }
                unconfirmed.formUnion(pages)
                dispatched.append(pages)
                onSend?(pages)
            case .confirm(let pages):
                // A real cumulative counter proves only a dispatched prefix.
                // Keep malformed test proofs unconfirmed while the queue rejects them.
                if !pages.isEmpty, Array(unconfirmed.sorted().prefix(pages.count)) == pages {
                    unconfirmed.subtract(pages)
                }
                do { try await afterPages(pages) }
                catch {
                    let issue = error as? LabelPrinterIssue ?? .writeFailed
                    return unconfirmed.isEmpty ? .notSent(issue) : .uncertain(issue)
                }
                onConfirm?(pages)
            case .hold:
                await withCheckedContinuation { hold = $0 }
            case .finish(let outcome):
                return outcome
            }
        }
        return .completed
    }

    func cancelPrinting() {
        cancellations += 1
        if releaseOnCancel { release() }
    }

    func release() {
        let continuation = hold
        hold = nil
        continuation?.resume()
    }

    func waitUntilHeld() async throws {
        for _ in 0..<1_000 {
            if hold != nil { return }
            await Task.yield()
        }
        XCTFail("The continuous driver did not reach its held window")
        throw CocoaError(.coderReadCorrupt)
    }
}
