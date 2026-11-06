import XCTest
@testable import CardShowScanner

@MainActor final class WriteInLabelTests: XCTestCase {
    private func item(market: Decimal? = nil, copies: Int = 1) -> ShowInventoryItem {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "write-in", printing: "Normal"),
            name: "Write-in fixture", set: "Set", number: "42", marketPrice: market,
            confidence: 100, printings: ["Normal"])
        return ShowInventoryItem(card: card, quantity: copies, remainingCostCents: 100)
    }

    private func raster(_ paper: InventoryLabelSize = .small30x14) -> LabelRaster {
        LabelRaster(width: paper.headDots, height: paper.feedDots,
            data: Data(repeating: 0x80, count: paper.feedDots * 12))
    }

    private func entry(_ draft: InventoryLabelDraft, revision: UUID? = nil) throws -> LabelQueueEntry {
        try LabelQueueEntry(draft: draft, raster: raster(draft.paperSize), copyNumber: 1, pricingRevisionID: revision)
    }

    private func store(_ storage: WriteInLabelStorage? = nil) -> TagApprovalStore {
        let storage = storage ?? WriteInLabelStorage()
        return TagApprovalStore(read: { _ in storage.bytes }, write: { data, _ in storage.bytes = data; storage.writes += 1 })
    }

    func testUnavailableAndZeroWithoutSavedStickersBecomePrintableWriteInLabels() throws {
        for market: Decimal? in [nil, 0] {
            var draft = InventoryLabelDraft(item: item(market: market, copies: 2))
            draft.copies = 2
            XCTAssertTrue(draft.isBlankPrice)
            XCTAssertFalse(draft.isBulk, "An unavailable or zero price cannot be silently printed as a 2-for-$1 offer")
            XCTAssertEqual(draft.priceText, "")
            XCTAssertEqual(draft.priceDescription, InventoryLabelDraft.blankPriceDescription)
            XCTAssertNoThrow(try draft.validate())
            for mode in InventoryLabelBatchMode.allCases {
                XCTAssertTrue(InventoryLabelBatch.shouldPrint(draft, approval: nil, mode: mode))
            }
            let queued = try entry(draft, revision: UUID())
            XCTAssertEqual(queued.blankPrice, true)
            XCTAssertEqual(queued.priceCents, 0)
            XCTAssertNil(queued.stickerTag)
            XCTAssertNil(queued.pricingRevisionID, "A blank amount never attests to a priced sticker revision")
            XCTAssertNil(queued.inventoryBulk)
            XCTAssertNoThrow(try queued.validate())
        }
    }

    func testSavedPositivePriceOrExplicitDealWinsOverMissingAndZeroQuotesWithoutRepricing() throws {
        let storage = WriteInLabelStorage(), approvals = store(storage)
        for market: Decimal? in [nil, 0] {
            for tag in [StickerPrice.individual(700), .twoForOne, .individual(0)] {
                let card = item(market: market)
                try approvals.approve([.init(id: card.id, approvedTag: tag, currentMarket: market)])
                let records = approvals.records, bytes = storage.bytes, writes = storage.writes
                let draft = InventoryLabelBatch.draft(for: card, mode: .all, store: approvals)
                XCTAssertEqual(draft.tag, tag)
                XCTAssertEqual(draft.isBlankPrice, tag == .individual(0))
                XCTAssertEqual(draft.priceText, tag == .individual(0) ? "" : tag.displayText)
                XCTAssertEqual(draft.isBulk, tag == .twoForOne)
                XCTAssertEqual(approvals.records, records)
                XCTAssertEqual(storage.bytes, bytes)
                XCTAssertEqual(storage.writes, writes)
            }
        }
    }

    func testMixedBatchCountsEveryKnownDealZeroAndUnavailableCopyWithoutApprovingBlanks() throws {
        let storage = WriteInLabelStorage(), approvals = store(storage)
        let inventory = [item(market: 9, copies: 2), item(market: 0.5), item(market: 0), item()]
        let before = inventory
        let drafts = InventoryLabelBatch.drafts(mode: .all, inventory: inventory, store: approvals)
        XCTAssertEqual(drafts.count, 4)
        XCTAssertEqual(drafts.reduce(0) { $0 + $1.copies }, 5)
        XCTAssertEqual(drafts.filter(\.isBlankPrice).count, 2)
        XCTAssertEqual(drafts.filter(\.isBulk).count, 1)
        XCTAssertTrue(drafts.allSatisfy { InventoryLabelBatch.shouldPrint($0, approval: nil, mode: .all) })
        XCTAssertTrue(approvals.records.isEmpty)
        XCTAssertEqual(storage.writes, 0)
        XCTAssertEqual(inventory, before)
    }

    func testBlankPricesDoNotRelaxTextCopyOrMalformedAmountValidation() throws {
        var draft = InventoryLabelDraft(item: item())
        for amount in ["", " ", "0", "0.00"] {
            draft.askingPriceText = amount
            XCTAssertTrue(draft.isBlankPrice)
            XCTAssertNoThrow(try draft.validate())
            for count in [0, 101] {
                draft.copies = count
                XCTAssertThrowsError(try draft.validate()) { XCTAssertEqual($0 as? InventoryLabelFailure, .invalidCopies) }
            }
            draft.copies = 1
        }
        for amount in ["not a price", "-1", "0.01", "1.50"] {
            draft.askingPriceText = amount
            XCTAssertFalse(draft.isBlankPrice)
            XCTAssertThrowsError(try draft.validate())
        }
        draft.askingPriceText = String(repeating: "0", count: 41)
        XCTAssertThrowsError(try draft.validate()) { XCTAssertEqual($0 as? InventoryLabelFailure, .invalidText) }
    }

    func testBlankCompletionCannotAcknowledgeAnApprovedZeroOrPositiveSticker() throws {
        let storage = WriteInLabelStorage(), approvals = store(storage)
        for cents: Int64 in [0, 700] {
            let card = item(market: cents == 0 ? 0 : 7)
            try approvals.approve([.init(id: card.id, approvedTag: .individual(cents), currentMarket: card.card.marketPrice)])
            let revision = try XCTUnwrap(approvals.record(for: card.id)).priceRevisionID
            var draft = InventoryLabelDraft(item: card)
            draft.askingPriceText = cents == 0 ? "0" : ""
            var blank = try entry(draft, revision: revision)
            let records = approvals.records, bytes = storage.bytes, writes = storage.writes
            XCTAssertNil(TagPricingContext.printingIssue(for: blank, store: approvals))
            blank.state = .completed
            try approvals.observeCompletedQueue([blank])
            XCTAssertEqual(approvals.records, records)
            XCTAssertEqual(storage.bytes, bytes)
            XCTAssertEqual(storage.writes, writes)
            XCTAssertTrue(try XCTUnwrap(approvals.record(for: card.id)).needsLabels)
        }
    }

    func testBlankInventoryQueuePrintsWithoutApprovalStorageAndRestoresItsExactSnapshot() async throws {
        let approvals = TagApprovalStore(read: { _ in throw TagApprovalStoreFailure.loadFailed },
            write: { _, _ in XCTFail("Write-in labels cannot invent price approval storage") })
        let storage = WriteInLabelStorage(), printer = WriteInLabelPrinter()
        let queue = LabelPrintQueue(read: { _ in storage.bytes },
            write: { data, _ in storage.bytes = data; storage.writes += 1 },
            onChanged: { entries in
                do { try approvals.observeCompletedQueue(entries) }
                catch { XCTFail("Blank receipts carry no approval history: \(error)") }
            }, approvalIssue: { TagPricingContext.printingIssue(for: $0, store: approvals) })
        let entries = try [entry(InventoryLabelDraft(item: item())), entry(InventoryLabelDraft(item: item(market: 0)))]
        try queue.replace(with: entries)
        let before = storage.bytes, writes = storage.writes
        let restored = LabelPrintQueue(read: { _ in storage.bytes },
            write: { _, _ in XCTFail("Restoring blank artwork cannot rewrite it") })
        XCTAssertTrue(restored.isLoaded)
        XCTAssertEqual(restored.entries, entries)
        XCTAssertEqual(storage.bytes, before)
        XCTAssertEqual(storage.writes, writes)
        XCTAssertEqual(printer.sent, 0)
        await queue.start(using: printer)
        XCTAssertEqual(printer.sent, 2)
        XCTAssertEqual(queue.completedCount, 2)
        XCTAssertTrue(approvals.records.isEmpty)
    }

    func testBlankSnapshotMetadataCannotMasqueradeAsAPriceDealOrLegacySource() throws {
        let blank = try entry(InventoryLabelDraft(item: item()))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(blank)) as? [String: Any])
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["priceCents"] = 100 }, { $0["inventoryBulk"] = true }, { $0["customBulk"] = true },
            { $0["pricingRevisionID"] = UUID().uuidString }, { $0.removeValue(forKey: "source") },
            { $0["blankPrice"] = "true" }
        ]
        for mutate in mutations {
            var row = original; mutate(&row)
            let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [row]])
            let queue = LabelPrintQueue(read: { _ in bytes }, write: { _, _ in XCTFail("Invalid snapshots cannot be overwritten") })
            XCTAssertFalse(queue.isLoaded)
            XCTAssertFalse(queue.canStart)
        }
    }

    func testLegacyZeroSnapshotKeepsItsHistoricalProofButRequiresWriteInPreparationBeforePrinting() async throws {
        let approvals = store(), card = item(market: 0)
        try approvals.approve([.init(id: card.id, approvedTag: .individual(0), currentMarket: 0)])
        let revision = try XCTUnwrap(approvals.record(for: card.id)).priceRevisionID
        let blank = try entry(InventoryLabelDraft(item: card))
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(blank)) as? [String: Any])
        row.removeValue(forKey: "blankPrice")
        row["pricingRevisionID"] = revision.uuidString
        var legacy = try JSONDecoder().decode(LabelQueueEntry.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertNoThrow(try legacy.validate())
        XCTAssertEqual(legacy.stickerTag, .individual(0))
        XCTAssertEqual(legacy.priceText, ShowBudgetMoney.decimal(0).money)
        XCTAssertEqual(legacy.raster, blank.raster)
        XCTAssertTrue(TagPricingContext.printingIssue(for: legacy, store: approvals)?.contains("write-in") == true,
            "Legacy artwork stays immutable, but the old $0 glyph cannot be printed under the new rule")
        let queue = LabelPrintQueue(read: { _ in nil }, write: { _, _ in },
            approvalIssue: { TagPricingContext.printingIssue(for: $0, store: approvals) })
        try queue.replace(with: [legacy])
        let printer = WriteInLabelPrinter(), records = approvals.records
        await queue.start(using: printer)
        XCTAssertEqual(printer.sent, 0, "The saved $0 snapshot is rejected before any printer send")
        XCTAssertTrue(queue.error?.contains("write-in") == true)
        XCTAssertEqual(queue.entries.first?.raster, legacy.raster)
        XCTAssertEqual(queue.entries.first?.stickerTag, .individual(0))
        XCTAssertEqual(approvals.records, records)
        legacy.state = .completed
        try approvals.observeCompletedQueue([legacy])
        XCTAssertEqual(approvals.record(for: card.id)?.lastPrintedTag, .individual(0))
        XCTAssertFalse(try XCTUnwrap(approvals.record(for: card.id)).needsLabels)
    }
}

@MainActor private final class WriteInLabelStorage {
    var bytes: Data?
    var writes = 0
}

@MainActor private final class WriteInLabelPrinter: LabelPrinterSending {
    var sent = 0
    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome { sent += 1; return .completed }
    func cancelPrinting() {}
}
