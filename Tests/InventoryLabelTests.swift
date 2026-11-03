import XCTest
import UIKit
@testable import CardShowScanner

@MainActor final class InventoryLabelTests: XCTestCase {
    private func stock(price: Decimal? = 10.49, quantity: Int = 3, name: String = "Charmander", number: String = "044") -> ShowInventoryItem {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:512035", printing: "Holofoil", condition: "Near Mint"),
            name: name, set: "SV Promo", number: number, marketPrice: price, confidence: 100, printings: ["Holofoil"])
        return ShowInventoryItem(card: card, quantity: quantity, remainingCostCents: 700)
    }

    func testDefaultsUseOneCopyAndRoundedSavedMarketWithoutMutatingStockOrActualCost() throws {
        let item = stock(), original = item
        var draft = InventoryLabelDraft(item: item)
        XCTAssertEqual(draft.id, item.id)
        XCTAssertEqual(draft.copies, 1)
        XCTAssertEqual(draft.priceCents, 1_000)
        XCTAssertEqual(draft.condition, "NM")
        XCTAssertEqual(draft.style, .cardDetails)
        draft.askingPriceText = "32.50"; draft.copies = 2; draft.style = .priceOnly
        try draft.validate()
        XCTAssertEqual(draft.priceCents, 3_250)
        XCTAssertEqual(item, original)
        XCTAssertEqual(item.quantity, 3)
        XCTAssertEqual(item.remainingCostCents, 700)
        XCTAssertEqual(item.card.marketPrice, 10.49)
    }

    func testMissingInvalidAndKnownZeroPricesStayDistinctAndRoundingUsesNearestDollar() throws {
        for price in [nil, Decimal(-1), Decimal.nan] {
            let draft = InventoryLabelDraft(item: stock(price: price))
            XCTAssertNil(draft.priceCents)
            XCTAssertThrowsError(try draft.validate())
        }
        for (price, cents) in [(Decimal.zero, Int64(0)), (Decimal(string: "0.49")!, 0),
                               (Decimal(string: "0.50")!, 100), (Decimal(string: "10.50")!, 1_100)] {
            let draft = InventoryLabelDraft(item: stock(price: price))
            XCTAssertEqual(draft.priceCents, cents)
            XCTAssertNoThrow(try draft.validate())
        }
    }

    func testCopyBoundsAndInvalidUserPriceAreRejectedInsteadOfClamped() throws {
        var draft = InventoryLabelDraft(item: stock())
        for copies in [0, -1, 101, Int.max] {
            draft.copies = copies
            XCTAssertThrowsError(try draft.validate())
            XCTAssertEqual(draft.copies, copies)
        }
        draft.copies = 100
        XCTAssertNoThrow(try draft.validate())
        for value in ["", "-1", "1.001", "abc"] {
            draft.askingPriceText = value
            XCTAssertNil(draft.priceCents)
            XCTAssertThrowsError(try draft.validate())
        }
    }

    func testConditionAbbreviationsAndSingleLineMetadataRemainHumanReadable() {
        for (value, expected) in [("Near Mint", "NM"), ("Lightly Played", "LP"), ("Moderately Played", "MP"),
                                  ("Heavily Played", "HP"), ("Damaged", "DMG"), ("PSA 9", "PSA 9"), ("", "Unknown")] {
            XCTAssertEqual(InventoryLabelDraft.shortCondition(value), expected)
        }
        XCTAssertEqual(InventoryLabelDraft.singleLine("  Darkrai\n &\t Cresselia  ", maximumCharacters: 100), "Darkrai & Cresselia")
        XCTAssertEqual(InventoryLabelDraft.singleLine("abcdef", maximumCharacters: 3), "abc")
    }

    func testBothLayoutsEveryPaperSizeProduceExactNonblankPrinterRastersAndActualPreviews() throws {
        for style in InventoryLabelStyle.allCases {
            for size in InventoryLabelSize.allCases {
                var draft = InventoryLabelDraft(item: stock())
                draft.style = style; draft.paperSize = size
                let bitmap = try InventoryLabelRenderer.render(draft)
                XCTAssertEqual(bitmap.raster.width, 96)
                XCTAssertEqual(bitmap.raster.height, size.feedDots)
                XCTAssertEqual(bitmap.raster.data.count, size.feedDots * 12)
                XCTAssertTrue(bitmap.raster.data.contains { $0 != 0 })
                XCTAssertEqual(bitmap.previewImage.size.width, CGFloat(size.feedDots))
                XCTAssertEqual(bitmap.previewImage.size.height, 96)
                let decoded = try InventoryLabelRenderer.image(raster: bitmap.raster)
                XCTAssertEqual(decoded.pngData(), bitmap.previewImage.pngData())
            }
        }
    }

    func testRasterRotationPackingAndPreviewRecoverEachExactBlackDot() throws {
        let width = 240, height = 96
        let points = [(0, 0), (7, 8), (17, 38), (width - 1, height - 1)]
        var pixels = [UInt8](repeating: 255, count: width * height)
        for (x, y) in points { pixels[y * width + x] = 0 }
        let bitmap = try InventoryLabelRenderer.bitmap(grayscale: pixels, landscapeWidth: width, landscapeHeight: height)
        let packed = Array(bitmap.raster.data)
        for (x, y) in points {
            let head = 95 - y
            XCTAssertNotEqual(packed[x * 12 + head / 8] & (0x80 >> (head % 8)), 0)
        }
        XCTAssertEqual(packed.reduce(0) { $0 + $1.nonzeroBitCount }, points.count)
        let image = try XCTUnwrap(bitmap.previewImage.cgImage)
        let raw = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertEqual(Array(raw), pixels)
    }

    func testLongUnicodeNamesAndMaximumPriceRemainBoundedAcrossBothStyles() throws {
        for style in InventoryLabelStyle.allCases {
            var draft = InventoryLabelDraft(item: stock(name: String(repeating: "超長いカード e\u{301} 🃏 ", count: 100), number: "99/102"))
            draft.style = style
            draft.askingPriceText = InventoryLabelDraft.inputText(ShowBudgetMoney.maximumCents)
            let bitmap = try InventoryLabelRenderer.render(draft)
            XCTAssertEqual(bitmap.raster.data.count, 240 * 12)
            XCTAssertLessThanOrEqual(draft.cardName.count, 500)
            XCTAssertEqual(draft.priceCents, ShowBudgetMoney.maximumCents)
        }
    }

    func testInvalidAndBlankRasterCannotEnterThePrinterQueue() throws {
        for raster in [LabelRaster(width: 95, height: 240, data: Data(repeating: 1, count: 2_880)),
                       LabelRaster(width: 96, height: 0, data: Data()),
                       LabelRaster(width: 96, height: 801, data: Data(repeating: 1, count: 9_612)),
                       LabelRaster(width: 96, height: 240, data: Data(repeating: 0, count: 2_880)),
                       LabelRaster(width: 96, height: 240, data: Data(repeating: 1, count: 20))] {
            XCTAssertThrowsError(try raster.validate())
        }
    }
}
