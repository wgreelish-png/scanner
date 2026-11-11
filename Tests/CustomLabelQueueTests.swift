import XCTest
@testable import CardShowScanner

@MainActor final class CustomLabelQueueTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CustomLabelQueueTests-" + UUID().uuidString)
    }

    private func raster(_ paper: InventoryLabelSize = .small30x14) -> LabelRaster {
        LabelRaster(width: paper.headDots, height: paper.feedDots,
                    data: Data(repeating: 0x80, count: 12 * paper.feedDots))
    }

    private func custom(price: Int64 = 500, copy: Int = 1,
                        paper: InventoryLabelSize = .small30x14, isBulk: Bool = false) throws -> LabelQueueEntry {
        try LabelQueueEntry(customPriceCents: price, raster: raster(paper), copyNumber: copy,
                           paperSize: paper, isBulk: isBulk)
    }

    private func inventory(id: UUID = UUID(), cents: Int64 = 1_000,
                           revision: UUID? = nil) throws -> LabelQueueEntry {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Normal"),
            name: "Inventory fixture", set: "Set", number: "42", marketPrice: 10,
            confidence: 100, printings: ["Normal"])
        var draft = InventoryLabelDraft(item: ShowInventoryItem(id: id, card: card, quantity: 1))
        draft.askingPriceText = InventoryLabelDraft.inputText(cents)
        return try LabelQueueEntry(draft: draft, raster: raster(), copyNumber: 1, pricingRevisionID: revision)
    }

    private func document(_ entry: LabelQueueEntry,
                          change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let encoded = try JSONEncoder().encode(entry)
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        change(&row)
        return try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [row]])
    }

    private func decodedEntry(_ data: Data) throws -> LabelQueueEntry {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        return try JSONDecoder().decode(LabelQueueEntry.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(entries.first)))
    }

    private func queue(_ storage: CustomLabelQueueStorage, approvals: TagApprovalStore? = nil) -> LabelPrintQueue {
        LabelPrintQueue(url: location(), read: { _ in storage.bytes },
            write: { data, _ in storage.bytes = data; storage.writes += 1 },
            onChanged: { entries in
                guard let approvals else { return }
                do { try approvals.observeCompletedQueue(entries) }
                catch { XCTFail("Custom-only queue must not require approval storage: \(error)") }
            }, approvalIssue: { entry in
                guard let approvals else { return nil }
                return TagPricingContext.printingIssue(for: entry, store: approvals)
            })
    }

    private func approvalStore(unavailable: Bool = false) -> TagApprovalStore {
        TagApprovalStore(url: location(), read: { _ in
            if unavailable { throw TagApprovalStoreFailure.loadFailed }
            return nil
        }, write: { _, _ in })
    }

    func testStandaloneInitializerRequiresWholeDollarPriceAndExistingPaperCopyLimits() throws {
        let entry = try custom(price: 0, copy: 100, paper: .large50x14)
        XCTAssertEqual(entry.source, .custom)
        XCTAssertNil(entry.inventoryID)
        XCTAssertNil(entry.pricingRevisionID)
        XCTAssertEqual(entry.cardName, "Custom price tag")
        XCTAssertEqual(entry.style, .priceOnly)
        XCTAssertEqual(entry.priceCents, 0, "Known zero is valid")
        XCTAssertNoThrow(try entry.validate())
        for price in [Int64(-100), 1, 550, ShowBudgetMoney.maximumCents + 1] {
            XCTAssertThrowsError(try custom(price: price))
        }
        for copy in [0, 101] { XCTAssertThrowsError(try custom(copy: copy)) }
        XCTAssertThrowsError(try LabelQueueEntry(customPriceCents: 500, raster: raster(), copyNumber: 1,
                                                paperSize: .large50x14))
    }

    func testStandaloneQueuePersistsWithoutStartingAndPrintsWithUnavailableApprovals() async throws {
        let storage = CustomLabelQueueStorage(), approvals = approvalStore(unavailable: true)
        let queue = queue(storage, approvals: approvals), printer = CustomLabelQueuePrinter()
        let entries = try [custom(copy: 1), custom(copy: 2)]
        XCTAssertFalse(approvals.isLoaded)
        try queue.replace(with: entries)
        XCTAssertEqual(printer.sent, 0)
        XCTAssertFalse(queue.isPrinting)
        let restored = self.queue(storage, approvals: approvals)
        XCTAssertEqual(restored.entries, entries)
        XCTAssertNil(TagPricingContext.printingIssue(for: entries[0], store: approvals))
        await restored.start(using: printer)
        XCTAssertEqual(printer.sent, 2)
        XCTAssertEqual(restored.completedCount, 2)
        XCTAssertTrue(approvals.records.isEmpty)
        let completed = self.queue(storage, approvals: approvals)
        XCTAssertEqual(completed.completedCount, 2)
        XCTAssertFalse(completed.canStart, "Completed standalone labels cannot restart automatically")
    }

    func testBulkDraftUsesAnExplicitCategoryWithZeroSentinelAndExistingCopyLimits() throws {
        let bulk = CustomPriceTagDraft(priceCents: 0, copies: 100, paperSize: .large50x14, isBulk: true)
        XCTAssertNoThrow(try bulk.validate())
        XCTAssertTrue(bulk.isBulk)
        XCTAssertEqual(bulk.priceText, StickerPrice.twoForOne.displayText)
        let zero = CustomPriceTagDraft(priceCents: 0, copies: 1, paperSize: .small30x14)
        XCTAssertFalse(zero.isBulk)
        XCTAssertEqual(zero.priceText, "")
        for price in [Int64(-100), 50, 100, 500] {
            XCTAssertThrowsError(try CustomPriceTagDraft(priceCents: price, copies: 1,
                paperSize: .small30x14, isBulk: true).validate())
            XCTAssertThrowsError(try custom(price: price, isBulk: true))
        }
        for copies in [0, 101] {
            XCTAssertThrowsError(try CustomPriceTagDraft(priceCents: 0, copies: copies,
                paperSize: .small30x14, isBulk: true).validate())
            XCTAssertThrowsError(try custom(price: 0, copy: copies, isBulk: true))
        }
    }

    func testBulkModelIgnoresPriceInputAndOnlyPreparesItsRequestedStickerCopies() throws {
        let storage = CustomLabelQueueStorage(), queue = queue(storage)
        var rendered: [CustomPriceTagDraft] = []
        let bitmap = raster(.medium40x12)
        let model = CustomPriceTagModel(queue: queue, paperSize: .medium40x12, render: {
            rendered.append($0)
            return bitmap
        })
        model.isBulk = true
        model.copies = "3"
        XCTAssertEqual(model.draft?.priceCents, 0)
        XCTAssertEqual(model.draft?.priceText, StickerPrice.twoForOne.displayText)
        model.price = "not a price"
        XCTAssertTrue(model.prepare())
        XCTAssertEqual(rendered.count, 1, "All copies reuse the same immutable bulk raster")
        XCTAssertEqual(rendered.first?.isBulk, true)
        XCTAssertEqual(queue.entries.count, 3)
        XCTAssertEqual(queue.entries.map(\.copyNumber), [1, 2, 3])
        XCTAssertTrue(queue.entries.allSatisfy {
            $0.source == .custom && $0.customBulk == true && $0.priceCents == 0
                && $0.cardName == "Bulk price tag" && $0.inventoryID == nil && $0.pricingRevisionID == nil
                && $0.paperSize == .medium40x12 && $0.raster == bitmap && $0.state == .pending
        })
        XCTAssertFalse(queue.isPrinting)
        XCTAssertEqual(storage.writes, 1)
        model.price = "99"
        XCTAssertTrue(model.hasPreparedQueue, "Unused individual price input does not change the bulk draft")
        XCTAssertTrue(model.prepare())
        XCTAssertEqual(storage.writes, 1)
        XCTAssertEqual(rendered.count, 1)
        model.isBulk = false
        XCTAssertEqual(model.draft?.priceCents, 9_900)
        XCTAssertFalse(model.hasPreparedQueue)
    }

    func testCustomPreparationReusesTheExactPreviewRasterForAllCopiesWithoutStartingPrinting() throws {
        for (price, bulk) in [("0", false), ("5", false), ("", true)] {
            let storage = CustomLabelQueueStorage(), queue = queue(storage)
            var renders = 0
            let model = CustomPriceTagModel(queue: queue, render: { draft in
                renders += 1
                return self.raster(draft.paperSize)
            })
            model.price = price; model.isBulk = bulk; model.copies = "3"
            let draft = try XCTUnwrap(model.draft)
            let preview = try model.previewRaster(for: draft)
            XCTAssertEqual(try model.previewRaster(for: draft), preview)
            XCTAssertEqual(renders, 1)
            XCTAssertTrue(queue.entries.isEmpty, "Previewing never prepares or prints copies")
            XCTAssertEqual(storage.writes, 0)
            XCTAssertTrue(model.prepare())
            XCTAssertEqual(renders, 1, "Prepare reuses verified bits rather than drawing the same preview again")
            XCTAssertEqual(queue.entries.map(\.raster), Array(repeating: preview, count: 3))
            XCTAssertTrue(queue.entries.allSatisfy { $0.state == .pending })
            XCTAssertFalse(queue.isPrinting)
            XCTAssertEqual(storage.writes, 1)
        }
    }

    func testCustomPreviewCacheIncludesCompleteArtworkButExcludesCopyCount() throws {
        let original = try InventoryLabelSize(product: NiimbotLabelProduct(code: "120425109", width: 40,
            height: 12, rotation: 90, paperType: 1,
            inputAreas: [.init(x: 1, y: 1, width: 38, height: 10)]))
        let corrected = try InventoryLabelSize(product: NiimbotLabelProduct(code: "120425109", width: 40,
            height: 12, rotation: 90, paperType: 1,
            inputAreas: [.init(x: 2, y: 1, width: 37, height: 10)]))
        XCTAssertEqual(original.product?.code, corrected.product?.code)
        XCTAssertNotEqual(original.geometry, corrected.geometry)
        let storage = CustomLabelQueueStorage(), queue = queue(storage)
        var rendered: [CustomPriceTagDraft] = []
        let model = CustomPriceTagModel(queue: queue, paperSize: original, render: { draft in
            rendered.append(draft)
            return self.raster(draft.paperSize)
        })
        model.price = "5"; model.copies = "2"
        _ = try model.previewRaster(for: XCTUnwrap(model.draft))
        _ = try model.previewRaster(for: XCTUnwrap(model.draft))
        XCTAssertEqual(rendered.count, 1)
        model.paperSize = corrected
        _ = try model.previewRaster(for: XCTUnwrap(model.draft))
        model.pricePosition = .left
        _ = try model.previewRaster(for: XCTUnwrap(model.draft))
        model.price = "6"
        _ = try model.previewRaster(for: XCTUnwrap(model.draft))
        XCTAssertEqual(rendered.count, 4)
        model.copies = "3"
        _ = try model.previewRaster(for: XCTUnwrap(model.draft))
        XCTAssertEqual(rendered.count, 4, "Copies do not change the artwork or invalidate its preview")
        model.isBulk = true
        _ = try model.previewRaster(for: XCTUnwrap(model.draft))
        XCTAssertEqual(rendered.count, 5, "Price, complete geometry, position and bulk category change the artwork")
        model.price = "99"
        let bulkPreview = try model.previewRaster(for: XCTUnwrap(model.draft))
        XCTAssertEqual(rendered.count, 5, "Unused individual input does not change a bulk draft")
        XCTAssertTrue(model.prepare())
        XCTAssertEqual(rendered.count, 5)
        XCTAssertTrue(queue.entries.allSatisfy { $0.paperSize == corrected && $0.raster == bulkPreview })
        XCTAssertTrue(queue.entries.allSatisfy { $0.customBulk == true })
        XCTAssertFalse(queue.isPrinting)
    }

    func testChangingOnlyCopiesReusesPreviewButPreparesTheNewRequestedQuantity() throws {
        let storage = CustomLabelQueueStorage(), queue = queue(storage)
        var renders = 0
        let model = CustomPriceTagModel(queue: queue, render: { draft in
            renders += 1
            return self.raster(draft.paperSize)
        })
        model.price = "5"; model.copies = "2"
        let first = try XCTUnwrap(model.draft)
        let preview = try model.previewRaster(for: first)
        let invalid = CustomPriceTagDraft(priceCents: first.priceCents, copies: 0, paperSize: first.paperSize,
                                         isBulk: first.isBulk, pricePosition: first.pricePosition)
        XCTAssertThrowsError(try model.previewRaster(for: invalid), "Artwork reuse must not bypass copy validation")
        XCTAssertEqual(renders, 1)
        model.copies = ""
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.artworkDraft, first.artworkDraft, "Clearing a copy field keeps its preview artwork")
        XCTAssertEqual(try model.previewRaster(for: XCTUnwrap(model.artworkDraft)), preview)
        XCTAssertEqual(renders, 1)
        model.copies = "4"
        let changed = try XCTUnwrap(model.draft)
        XCTAssertNotEqual(first, changed, "The requested print quantity must remain part of the full draft")
        XCTAssertEqual(try model.previewRaster(for: changed), preview)
        XCTAssertEqual(renders, 1)
        XCTAssertTrue(model.prepare())
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(queue.entries.map(\.copyNumber), [1, 2, 3, 4])
        XCTAssertEqual(queue.entries.map(\.raster), Array(repeating: preview, count: 4))
        XCTAssertEqual(storage.writes, 1)
        model.copies = "3"
        XCTAssertFalse(model.hasPreparedQueue, "A new count must not silently reuse a queued quantity")
        XCTAssertFalse(model.prepare(), "Already pending labels require explicit recovery or clearing")
        XCTAssertEqual(queue.entries.count, 4)
        XCTAssertEqual(storage.writes, 1)
    }

    func testCustomPreparationReplacesCompletedInventoryReceiptsWithoutChangingPrintedTagHistory() throws {
        for bulk in [false, true] {
            let approvals = approvalStore(), id = UUID()
            try approvals.approve([.init(id: id, approvedTag: .individual(1_000), currentMarket: 10)])
            let revision = try XCTUnwrap(approvals.record(for: id)).priceRevisionID
            var receipt = try inventory(id: id, revision: revision)
            receipt.state = .completed
            let storage = CustomLabelQueueStorage(bytes: try document(receipt))
            let queue = queue(storage, approvals: approvals)
            let history = approvals.records
            XCTAssertEqual(queue.entries, [receipt])
            let model = CustomPriceTagModel(queue: queue, render: { self.raster($0.paperSize) })
            model.isBulk = bulk; model.price = bulk ? "" : "5"; model.copies = "2"

            XCTAssertTrue(model.prepare(), "A fully confirmed old job must not require a review/clear detour")
            XCTAssertEqual(queue.entries.count, 2)
            XCTAssertTrue(queue.entries.allSatisfy { $0.source == .custom && $0.state == .pending })
            XCTAssertFalse(queue.entries.contains { $0.id == receipt.id })
            XCTAssertEqual(approvals.records, history, "Replacing receipts cannot rewrite inventory tag values/history")
            XCTAssertEqual(storage.writes, 1)
            let saved = queue.entries
            XCTAssertTrue(model.prepare())
            XCTAssertEqual(queue.entries, saved, "A repeated Print preparation cannot enqueue duplicate copies")
            XCTAssertEqual(storage.writes, 1)
            XCTAssertFalse(queue.isPrinting)
        }
    }

    func testCustomPreparationPreservesPendingFailedAndUncertainInventoryWork() throws {
        for state in [LabelQueueState.pending, .failed, .uncertain] {
            var outstanding = try inventory()
            outstanding.state = state
            outstanding.lastIssue = state == .pending ? nil : .writeFailed
            let bytes = try document(outstanding)
            let storage = CustomLabelQueueStorage(bytes: bytes), queue = queue(storage)
            var renders = 0
            let model = CustomPriceTagModel(queue: queue, render: { draft in
                renders += 1
                return self.raster(draft.paperSize)
            })
            model.price = "5"; model.copies = "2"

            XCTAssertFalse(model.prepare(), "Only an all-completed queue may be replaced: \(state)")
            XCTAssertEqual(queue.entries, [outstanding])
            XCTAssertEqual(storage.bytes, bytes)
            XCTAssertEqual(storage.writes, 0)
            XCTAssertEqual(renders, 0, "Blocked work must not start a needless render or upload")
            XCTAssertFalse(queue.isPrinting)
        }
    }

    func testInvalidPreviewRasterIsNotCachedOrWrittenIntoTheQueue() throws {
        let storage = CustomLabelQueueStorage(), queue = queue(storage)
        var attempts = 0
        let model = CustomPriceTagModel(queue: queue, render: { draft in
            attempts += 1
            if attempts == 1 { return LabelRaster(width: 0, height: 0, data: Data()) }
            return self.raster(draft.paperSize)
        })
        model.price = "5"; model.copies = "2"
        XCTAssertThrowsError(try model.previewRaster(for: XCTUnwrap(model.draft)))
        XCTAssertTrue(queue.entries.isEmpty)
        XCTAssertEqual(storage.writes, 0)
        XCTAssertTrue(model.prepare(), "A failed preview cannot poison the later explicit preparation")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(queue.entries.count, 2)
        XCTAssertTrue(queue.entries.allSatisfy { $0.state == .pending })
    }

    func testBulkCategoryPersistsAndPrintsWithoutApprovalStorageOrAutomaticStart() async throws {
        let storage = CustomLabelQueueStorage(), approvals = approvalStore(unavailable: true)
        let queue = queue(storage, approvals: approvals), printer = CustomLabelQueuePrinter()
        let entries = try [custom(price: 0, copy: 1, isBulk: true), custom(price: 0, copy: 2, isBulk: true)]
        try queue.replace(with: entries)
        XCTAssertFalse(approvals.isLoaded)
        XCTAssertEqual(printer.sent, 0)
        let restored = self.queue(storage, approvals: approvals)
        XCTAssertEqual(restored.entries, entries)
        XCTAssertTrue(restored.entries.allSatisfy { $0.customBulk == true && $0.priceText == StickerPrice.twoForOne.displayText })
        XCTAssertNil(TagPricingContext.printingIssue(for: entries[0], store: approvals))
        await restored.start(using: printer)
        XCTAssertEqual(printer.sent, 2)
        XCTAssertEqual(restored.completedCount, 2)
        XCTAssertTrue(approvals.records.isEmpty)
        let completed = self.queue(storage, approvals: approvals)
        XCTAssertTrue(completed.entries.allSatisfy { $0.customBulk == true && $0.state == .completed })
        await completed.start(using: printer)
        XCTAssertEqual(printer.sent, 2, "Reopening confirmed bulk tags never reprints them")
    }

    func testLegacyCustomZeroWithoutBulkFlagRemainsAnIndividualZeroPrice() throws {
        let original = try custom(price: 0)
        let bytes = try document(original) {
            $0.removeValue(forKey: "customBulk")
            $0.removeValue(forKey: "blankPrice")
        }
        let storage = CustomLabelQueueStorage(bytes: bytes), queue = queue(storage)
        let restored = try XCTUnwrap(queue.entries.first)
        XCTAssertTrue(queue.isLoaded)
        XCTAssertNil(restored.customBulk)
        XCTAssertEqual(restored.source, .custom)
        XCTAssertEqual(restored.priceCents, 0)
        XCTAssertEqual(restored.priceText, ShowBudgetMoney.decimal(0).money)
        XCTAssertNotEqual(restored.priceText, StickerPrice.twoForOne.displayText)
        XCTAssertTrue(TagPricingContext.printingIssue(for: restored, store: approvalStore())?.contains("write-in") == true)
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(storage.writes, 0)
        let explicitFalse = try decodedEntry(document(original) {
            $0["customBulk"] = false
            $0["blankPrice"] = false
        })
        XCTAssertNoThrow(try explicitFalse.validate())
        XCTAssertEqual(explicitFalse.priceText, restored.priceText)
    }

    func testBulkFlagCannotDisguiseAnIndividualPriceOrInventoryIdentity() throws {
        let bulk = try custom(price: 0, isBulk: true)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["inventoryBulk"] = true },
            { $0["priceCents"] = 50 },
            { $0["priceCents"] = 100 },
            { $0["source"] = "inventory"; $0["inventoryID"] = UUID().uuidString },
            { $0.removeValue(forKey: "source"); $0["inventoryID"] = UUID().uuidString },
            { $0["inventoryID"] = UUID().uuidString },
            { $0["pricingRevisionID"] = UUID().uuidString },
            { $0["style"] = InventoryLabelStyle.cardDetails.rawValue }
        ]
        for change in mutations {
            let bytes = try document(bulk, change: change)
            XCTAssertThrowsError(try decodedEntry(bytes).validate())
            let storage = CustomLabelQueueStorage(bytes: bytes), queue = queue(storage)
            XCTAssertFalse(queue.isLoaded)
            XCTAssertFalse(queue.canStart)
            XCTAssertEqual(storage.bytes, bytes)
            XCTAssertEqual(storage.writes, 0)
        }
        let malformedFlag = try document(bulk) { $0["customBulk"] = "true" }
        XCTAssertFalse(queue(CustomLabelQueueStorage(bytes: malformedFlag)).isLoaded)
        XCTAssertNil(try inventory().customBulk)
    }

    func testBulkCompletionCannotAcknowledgeAZeroPricedInventoryApproval() async throws {
        let approvals = approvalStore(), id = UUID()
        try approvals.approve([.init(id: id, approvedTag: .individual(0), currentMarket: 0)])
        let before = approvals.records
        let storage = CustomLabelQueueStorage(), queue = queue(storage, approvals: approvals)
        try queue.replace(with: [custom(price: 0, isBulk: true)])
        await queue.start(using: CustomLabelQueuePrinter())
        XCTAssertEqual(queue.completedCount, 1)
        XCTAssertEqual(approvals.records, before)
        XCTAssertTrue(try XCTUnwrap(approvals.record(for: id)).needsLabels,
                      "Standalone bulk stickers have no lot identity and never change inventory labeling history")
        XCTAssertTrue(queue.entries.allSatisfy { $0.inventoryID == nil && $0.pricingRevisionID == nil })
    }

    func testLegacyMissingSourceKeepsItsInventoryIdentityAndCentsWithoutRewritingStorage() throws {
        let original = try inventory()
        XCTAssertEqual(original.source, .inventory)
        let bytes = try document(original) {
            $0.removeValue(forKey: "source")
            $0.removeValue(forKey: "pricingRevisionID")
            $0["priceCents"] = 1_450
        }
        let storage = CustomLabelQueueStorage(bytes: bytes), queue = queue(storage)
        let saved = try XCTUnwrap(queue.entries.first)
        XCTAssertTrue(queue.isLoaded)
        XCTAssertNil(saved.source)
        XCTAssertEqual(saved.inventoryID, original.inventoryID)
        XCTAssertEqual(saved.priceCents, 1_450)
        XCTAssertNoThrow(try saved.validate())
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(storage.writes, 0)
        XCTAssertNotNil(TagPricingContext.printingIssue(for: saved, store: approvalStore(unavailable: true)),
                        "Missing source/revision cannot bypass inventory approval availability")
    }

    func testUnknownOrMalformedSourceAndLegacyWithoutInventoryIdentityFailClosed() throws {
        let original = try inventory()
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["source"] = "future-kind" },
            { $0["source"] = 123 },
            { $0["source"] = "inventory"; $0.removeValue(forKey: "inventoryID") },
            { $0.removeValue(forKey: "source"); $0.removeValue(forKey: "inventoryID") },
            { $0["source"] = NSNull(); $0.removeValue(forKey: "inventoryID") }
        ]
        for change in mutations {
            let bytes = try document(original, change: change)
            let storage = CustomLabelQueueStorage(bytes: bytes), queue = queue(storage)
            XCTAssertFalse(queue.isLoaded)
            XCTAssertFalse(queue.canStart)
            XCTAssertEqual(storage.bytes, bytes)
            XCTAssertEqual(storage.writes, 0)
        }
    }

    func testCustomContradictoryIdentityRevisionStyleOrCentsCannotUseApprovalExemption() throws {
        let original = try custom(), approvals = approvalStore(unavailable: true)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["inventoryID"] = UUID().uuidString },
            { $0["pricingRevisionID"] = UUID().uuidString },
            { $0["style"] = InventoryLabelStyle.cardDetails.rawValue },
            { $0["priceCents"] = 550 }
        ]
        for change in mutations {
            let bytes = try document(original, change: change)
            let decoded = try decodedEntry(bytes)
            XCTAssertThrowsError(try decoded.validate())
            XCTAssertNotNil(TagPricingContext.printingIssue(for: decoded, store: approvals))
            let storage = CustomLabelQueueStorage(bytes: bytes), queue = queue(storage)
            XCTAssertFalse(queue.isLoaded)
            XCTAssertEqual(storage.bytes, bytes)
            XCTAssertEqual(storage.writes, 0)
        }
    }

    func testCustomCompletionNeverAcknowledgesAnInventoryApprovalEvenWithInjectedMatchingIdentifiers() throws {
        let approvals = approvalStore(), id = UUID()
        try approvals.approve([.init(id: id, approvedTag: .individual(500), currentMarket: 5)])
        let record = try XCTUnwrap(approvals.record(for: id)), original = try custom()
        let malformed = try decodedEntry(document(original) {
            $0["inventoryID"] = id.uuidString
            $0["pricingRevisionID"] = record.priceRevisionID.uuidString
            $0["state"] = LabelQueueState.completed.rawValue
        })
        XCTAssertThrowsError(try malformed.validate())
        try approvals.observeCompletedQueue([malformed])
        XCTAssertEqual(approvals.record(for: id), record)
        XCTAssertTrue(try XCTUnwrap(approvals.record(for: id)).needsLabels)
    }

    func testInventoryStalePriceAndRevisionStillBlockPrinterTransport() async throws {
        let approvals = approvalStore(), id = UUID()
        try approvals.approve([.init(id: id, approvedTag: .individual(1_000), currentMarket: 10)])
        let firstRevision = try XCTUnwrap(approvals.record(for: id)).priceRevisionID
        let entry = try inventory(id: id, revision: firstRevision)
        try approvals.approve([.init(id: id, approvedTag: .individual(1_200), currentMarket: 12)])
        XCTAssertNotNil(TagPricingContext.printingIssue(for: entry, store: approvals))
        try approvals.approve([.init(id: id, approvedTag: .individual(1_000), currentMarket: 10)])
        XCTAssertNotEqual(approvals.record(for: id)?.priceRevisionID, firstRevision)
        XCTAssertNotNil(TagPricingContext.printingIssue(for: entry, store: approvals))
        let storage = CustomLabelQueueStorage(), queue = queue(storage, approvals: approvals)
        try queue.replace(with: [entry])
        let printer = CustomLabelQueuePrinter()
        await queue.start(using: printer)
        XCTAssertEqual(printer.sent, 0)
        XCTAssertEqual(queue.entries.first?.state, .failed)
        XCTAssertTrue(try XCTUnwrap(approvals.record(for: id)).needsLabels)
    }
}

@MainActor private final class CustomLabelQueueStorage {
    var bytes: Data?
    var writes = 0
    init(bytes: Data? = nil) { self.bytes = bytes }
}

@MainActor private final class CustomLabelQueuePrinter: LabelPrinterSending {
    var sent = 0
    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome { sent += 1; return .completed }
    func cancelPrinting() {}
}
