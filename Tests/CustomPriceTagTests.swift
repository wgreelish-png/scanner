import XCTest
@testable import CardShowScanner

@MainActor final class CustomPriceTagTests: XCTestCase {
    private func raster(_ draft: CustomPriceTagDraft) -> LabelRaster {
        LabelRaster(width: draft.paperSize.headDots, height: draft.paperSize.feedDots,
            data: Data(repeating: 0x80, count: 12 * draft.paperSize.feedDots))
    }

    func testManualDraftAcceptsZeroAndWholeDollarsWithoutInventoryOrMarket() throws {
        for price in [Int64(0), 100, 500, 11_000] {
            let draft = CustomPriceTagDraft(priceCents: price, copies: 3, paperSize: .small30x14)
            XCTAssertNoThrow(try draft.validate())
            XCTAssertEqual(draft.priceText, StickerPrice.individual(price).displayText)
        }
        for price in [Int64(-100), 50, 599] {
            XCTAssertThrowsError(try CustomPriceTagDraft(priceCents: price, copies: 1, paperSize: .small30x14).validate())
        }
        for copies in [0, 101] {
            XCTAssertThrowsError(try CustomPriceTagDraft(priceCents: 500, copies: copies, paperSize: .small30x14).validate())
        }
    }

    func testPreparationIsIdempotentAndRestoresExactStandaloneCopiesWithoutPrinting() throws {
        var bytes: Data?
        var writes = 0
        let queue = LabelPrintQueue(read: { _ in bytes }, write: { data, _ in bytes = data; writes += 1 })
        let model = CustomPriceTagModel(queue: queue, render: raster)
        model.price = "5"; model.copies = "3"; model.paperSize = .medium40x12
        XCTAssertTrue(model.prepare())
        let original = queue.entries
        XCTAssertEqual(original.count, 3)
        XCTAssertTrue(original.allSatisfy { $0.source == .custom && $0.inventoryID == nil && $0.pricingRevisionID == nil })
        XCTAssertEqual(original.map(\.copyNumber), [1, 2, 3])
        XCTAssertTrue(original.allSatisfy { $0.priceCents == 500 && $0.paperSize == .medium40x12 && $0.state == .pending })
        XCTAssertFalse(queue.isPrinting)
        XCTAssertTrue(model.prepare())
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(queue.entries, original)
        let reopened = LabelPrintQueue(read: { _ in bytes }, write: { _, _ in XCTFail("Opening never writes or prints") })
        XCTAssertEqual(reopened.entries, original)
        XCTAssertFalse(reopened.isPrinting)
        model.price = "7"
        XCTAssertFalse(model.prepare(), "A changed draft cannot overwrite saved queue progress")
        XCTAssertEqual(queue.entries, original)
    }

    func testFailedSaveRetainsInputsAndAllowsExplicitRetryAfterReload() {
        var bytes: Data?, fail = true
        let queue = LabelPrintQueue(read: { _ in bytes }, write: { data, _ in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            bytes = data
        })
        let model = CustomPriceTagModel(queue: queue, render: raster)
        model.price = "9"; model.copies = "2"
        XCTAssertFalse(model.prepare())
        XCTAssertEqual(model.price, "9")
        XCTAssertEqual(model.copies, "2")
        XCTAssertFalse(model.hasPreparedQueue)
        XCTAssertTrue(queue.entries.isEmpty)
        fail = false
        queue.reload()
        XCTAssertTrue(model.prepare())
        XCTAssertEqual(queue.entries.count, 2)
        XCTAssertNil(model.error)
    }

    func testInvalidInputDoesNotRenderOrSave() {
        let queue = LabelPrintQueue(read: { _ in nil }, write: { _, _ in XCTFail("Invalid input cannot save") })
        let model = CustomPriceTagModel(queue: queue, render: { _ in
            XCTFail("Invalid input cannot render")
            throw InventoryLabelFailure.invalidPrice
        })
        for (price, copies) in [("", "1"), ("5.50", "1"), ("5", "101"), ("5", "-1")] {
            model.price = price; model.copies = copies
            XCTAssertNil(model.draft)
            XCTAssertFalse(model.prepare())
        }
        XCTAssertTrue(queue.entries.isEmpty)
    }

    func testStandaloneRasterUsesTheSamePriceOnlyOutputForEveryPaper() throws {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Normal"),
            name: "Different metadata", set: "Set", number: "42", marketPrice: 5, confidence: 100, printings: ["Normal"])
        for paper in InventoryLabelSize.allCases {
            var inventory = InventoryLabelDraft(item: ShowInventoryItem(card: card, quantity: 1))
            inventory.askingPriceText = "5"; inventory.style = .priceOnly; inventory.paperSize = paper
            let custom = CustomPriceTagDraft(priceCents: 500, copies: 1, paperSize: paper)
            let rendered = try InventoryLabelRenderer.render(custom)
            XCTAssertEqual(rendered.raster, try InventoryLabelRenderer.render(inventory).raster)
            XCTAssertEqual(rendered.raster.width, paper.headDots)
            XCTAssertEqual(rendered.raster.height, paper.feedDots)
        }
    }
}
