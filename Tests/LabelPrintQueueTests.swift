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

    func testNewQueueEntryRejectsCardsInTheBulkCategory() throws {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Holofoil"),
            name: "Fixture card", set: "Fixture set", number: "42", marketPrice: Decimal(string: "0.50"),
            confidence: 100, printings: ["Holofoil"])
        let draft = InventoryLabelDraft(item: ShowInventoryItem(card: card, quantity: 1))
        let raster = try labels(copies: 1)[0].raster
        XCTAssertTrue(draft.isBulk)
        XCTAssertNil(draft.priceCents)
        XCTAssertThrowsError(try LabelQueueEntry(draft: draft, raster: raster, copyNumber: 1)) {
            XCTAssertEqual($0 as? InventoryLabelFailure, .bulkCategory)
        }
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
