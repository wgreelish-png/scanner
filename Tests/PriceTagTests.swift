import XCTest
import UIKit
@testable import CardShowScanner

@MainActor final class PriceTagTests: XCTestCase {
    private func item(price: Decimal? = Decimal(string: "8.28"), quantity: Int = 12,
                      name: String = "Synthetic card", number: String = "42/100", condition: String = "Near Mint") -> ShowInventoryItem {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Normal", condition: condition),
            name: name, set: "Synthetic set", number: number, marketPrice: price, confidence: 100, printings: ["Normal"])
        return ShowInventoryItem(card: card, quantity: quantity)
    }

    private func pixels(_ bitmap: PriceTagBitmap) throws -> [UInt8] {
        let data = try XCTUnwrap(bitmap.previewCGImage.dataProvider?.data)
        return [UInt8](data as Data)
    }

    func testDraftKeepsLocalInventoryIdentityAndDefaultsToOneLabelPerCopyPrice() {
        let stock = item(quantity: 1_000)
        let draft = PriceTagDraft(item: stock)
        XCTAssertEqual(draft.id, stock.id)
        XCTAssertEqual(draft.inventoryID, stock.id)
        XCTAssertEqual(draft.cardName, stock.card.name)
        XCTAssertEqual(draft.cardNumber, stock.card.number)
        XCTAssertEqual(draft.condition, "NM")
        XCTAssertEqual(draft.askingPriceText, "8")
        XCTAssertEqual(draft.askingPriceCents, 800)
        XCTAssertEqual(draft.copies, 1)
        XCTAssertNil(draft.validationMessage)
    }

    func testDefaultRoundingMatchesShowSaleMathAndDistinguishesUnknownFromKnownZero() {
        for amount in ["0", "0.49", "0.50", "6.77", "8.28", "99.50"] {
            let stock = item(price: Decimal(string: amount))
            let draft = PriceTagDraft(item: stock)
            let sale = ShowSaleMath.suggestedTotal([.init(inventoryID: stock.id, card: stock.card, quantity: 1)])
            XCTAssertEqual(draft.askingPriceCents, sale, amount)
        }
        let unknown = PriceTagDraft(item: item(price: nil))
        XCTAssertEqual(unknown.askingPriceText, "")
        XCTAssertNil(unknown.askingPriceCents)
        XCTAssertNotNil(unknown.validationMessage)
        let zero = PriceTagDraft(item: item(price: 0))
        XCTAssertEqual(zero.askingPriceText, "0")
        XCTAssertEqual(zero.priceText, "$0")
        XCTAssertNil(zero.validationMessage)
        XCTAssertEqual(PriceTagDraft(item: item(price: -1)).askingPriceText, "")
        XCTAssertEqual(PriceTagDraft(item: item(price: Decimal.nan)).askingPriceText, "")
    }

    func testEditedPricePreservesExactCentsAndUsesUnambiguousUSDText() {
        var draft = PriceTagDraft(item: item())
        let examples: [(String, Int64, String)] = [
            ("2", 200, "$2"), ("2.00", 200, "$2"), ("2.50", 250, "$2.50"),
            ("0.01", 1, "$0.01"), ("0008.1", 810, "$8.10"),
            ("999999999.99", ShowBudgetMoney.maximumCents, "$999999999.99")
        ]
        for (input, cents, printed) in examples {
            draft.askingPriceText = input
            XCTAssertEqual(draft.askingPriceCents, cents)
            XCTAssertEqual(draft.priceText, printed)
            XCTAssertNil(draft.validationMessage)
        }
        for invalid in ["", " ", "-1", "+1", "$2", "1,000", "1e2", "0.001", "1000000000", "NaN"] {
            draft.askingPriceText = invalid
            XCTAssertNil(draft.askingPriceCents, invalid)
            XCTAssertNil(draft.priceText, invalid)
            XCTAssertThrowsError(try PriceTagRenderer.render(draft)) {
                XCTAssertEqual($0 as? PriceTagRenderFailure, .invalidPrice)
            }
        }
    }

    func testLabelCountIsExplicitAndBoundedWithoutChangingStockOrMarketQuote() throws {
        let stock = item(quantity: 500)
        let original = stock
        var draft = PriceTagDraft(item: stock)
        draft.askingPriceText = "2.50"
        draft.copies = PriceTagDraft.maximumCopies
        XCTAssertNil(draft.validationMessage)
        _ = try PriceTagRenderer.render(draft)
        XCTAssertEqual(stock, original)
        XCTAssertEqual(stock.quantity, 500)
        XCTAssertEqual(stock.card.marketPrice, Decimal(string: "8.28"))
        for copies in [0, -1, PriceTagDraft.maximumCopies + 1, Int.max] {
            draft.copies = copies
            XCTAssertNotNil(draft.validationMessage)
            XCTAssertThrowsError(try PriceTagRenderer.render(draft)) {
                XCTAssertEqual($0 as? PriceTagRenderFailure, .invalidCopies)
            }
        }
    }

    func testConditionAbbreviationsDoNotInventNearMintForUnknownValues() {
        let expected = ["Near Mint": "NM", "NM": "NM", "near-mint": "NM", "Lightly Played": "LP",
                        "LP": "LP", "Moderately Played": "MP", "Heavily Played": "HP", "Damaged": "DMG", "DMG": "DMG"]
        for (input, output) in expected { XCTAssertEqual(PriceTagDraft.shortCondition(input), output) }
        XCTAssertEqual(PriceTagDraft.shortCondition("PSA 10"), "PSA 10")
        XCTAssertEqual(PriceTagDraft.shortCondition(""), "Unknown")
        XCTAssertEqual(PriceTagDraft.shortCondition("\nLightly\tPlayed\n"), "LP")
    }

    func testPackingUsesFourBytesPerFeedColumnAndTheDocumentedHeadRowOrder() throws {
        let width = PriceTagRenderer.minimumWidth
        var source = [UInt8](repeating: 255, count: width * 32)
        for (x, y) in [0, 7, 8, 15, 16, 23, 24, 31].enumerated() { source[y * width + x] = 0 }
        for y in 0..<32 { source[y * width + 8] = 0 }
        source[9] = 127
        source[10] = 128
        let bitmap = try PriceTagRenderer.bitmap(grayscalePixels: source, width: width)
        let packed = [UInt8](bitmap.packedColumns)
        let expected: [[UInt8]] = [
            [0, 0, 0, 0x80], [0, 0, 0, 0x01], [0, 0, 0x80, 0], [0, 0, 0x01, 0],
            [0, 0x80, 0, 0], [0, 0x01, 0, 0], [0x80, 0, 0, 0], [0x01, 0, 0, 0],
            [0xff, 0xff, 0xff, 0xff], [0, 0, 0, 0x80], [0, 0, 0, 0]
        ]
        XCTAssertEqual(packed.count, width * 4)
        for (x, bytes) in expected.enumerated() { XCTAssertEqual(Array(packed[(x * 4)..<(x * 4 + 4)]), bytes) }
    }

    func testPreviewContainsTheExactBinaryPixelsSentToThePrinter() throws {
        let bitmap = try PriceTagRenderer.render(PriceTagDraft(item: item()))
        let raster = try pixels(bitmap)
        let packed = [UInt8](bitmap.packedColumns)
        XCTAssertEqual(bitmap.previewCGImage.width, bitmap.width)
        XCTAssertEqual(bitmap.previewCGImage.height, 32)
        XCTAssertEqual(bitmap.previewCGImage.bitsPerPixel, 8)
        XCTAssertEqual(bitmap.previewImage.scale, 1)
        XCTAssertEqual(bitmap.previewImage.imageOrientation, .up)
        XCTAssertEqual(Set(raster), Set([UInt8(0), UInt8(255)]))
        for y in 0..<32 {
            for x in 0..<bitmap.width {
                let printsBlack = packed[x * 4 + 3 - y / 8] & UInt8(1 << (7 - y % 8)) != 0
                XCTAssertEqual(printsBlack, raster[y * bitmap.width + x] == 0)
                if y < 2 || y >= 30 { XCTAssertFalse(printsBlack, "Keep two head rows clear at each tape edge") }
            }
        }
        XCTAssertTrue(raster[(2 * bitmap.width)..<(13 * bitmap.width)].contains(0), "Card metadata must render on the first line")
        XCTAssertTrue(raster[(13 * bitmap.width)..<(30 * bitmap.width)].contains(0), "The asking price must render on the second line")
    }

    func testLongUnicodeMetadataStaysWithinTheFeedLimitAndPreservesTheEntirePriceRaster() throws {
        var compact = PriceTagDraft(item: item(name: "Card", number: "", condition: "Damaged"))
        compact.askingPriceText = "999999999.99"
        var long = PriceTagDraft(item: item(name: String(repeating: "超長いカード e\u{301} 🃏 ", count: 100),
            number: String(repeating: "123/456", count: 30), condition: "Damaged"))
        long.askingPriceText = compact.askingPriceText
        let reference = try PriceTagRenderer.render(compact)
        let expanded = try PriceTagRenderer.render(long)
        XCTAssertTrue((PriceTagRenderer.minimumWidth...PriceTagRenderer.maximumWidth).contains(reference.width))
        XCTAssertEqual(expanded.width, PriceTagRenderer.maximumWidth)
        let referencePixels = try pixels(reference), expandedPixels = try pixels(expanded)
        // Metadata truncation must not change or cut any dot of the price or
        // condition, even for the maximum supported manually entered amount.
        for y in 13..<30 {
            XCTAssertEqual(Array(referencePixels[(y * reference.width)..<((y + 1) * reference.width)]),
                Array(expandedPixels[(y * expanded.width)..<(y * expanded.width + reference.width)]))
        }
    }

    func testMalformedRasterIsRejectedAndTestLabelIsAUsablePreview() throws {
        for width in [0, PriceTagRenderer.minimumWidth - 1, PriceTagRenderer.maximumWidth + 1] {
            XCTAssertThrowsError(try PriceTagRenderer.bitmap(grayscalePixels: [], width: width))
        }
        XCTAssertThrowsError(try PriceTagRenderer.bitmap(grayscalePixels: [255], width: PriceTagRenderer.minimumWidth))
        let label = try PriceTagRenderer.testLabel()
        XCTAssertEqual(label.packedColumns.count, label.width * 4)
        XCTAssertTrue(try pixels(label).contains(0))
    }
}
