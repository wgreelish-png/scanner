import XCTest
import UIKit
@testable import CardShowScanner

@MainActor final class InventoryLabelTests: XCTestCase {
    func testLabelPaperPreferenceRemembersEverySupportedSizeAcrossReopen() throws {
        let suite = "LabelPaperPreferences." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LabelPaperPreferences(defaults: defaults)

        XCTAssertEqual(preferences.size, .small30x14)
        XCTAssertNil(defaults.object(forKey: "niimbotLabelSize"), "Opening a new preference does not claim a detected roll")
        for size in InventoryLabelSize.allCases {
            preferences.select(size)
            XCTAssertEqual(preferences.size, size)
            XCTAssertEqual(defaults.string(forKey: "niimbotLabelSize"), size.rawValue)
            XCTAssertEqual(LabelPaperPreferences(defaults: defaults).size, size,
                           "A new inventory or custom-label screen must retain the last physical paper choice")
        }
    }

    func testUnknownSavedPaperSizeUsesDefaultWithoutOverwritingUntilExplicitSelection() throws {
        let suite = "UnknownLabelPaperPreferences." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("transparent", forKey: "niimbotPaperMode")

        for raw in ["unsupported-paper", "", "30x14"] {
            defaults.set(raw, forKey: "niimbotLabelSize")
            let preferences = LabelPaperPreferences(defaults: defaults)
            XCTAssertEqual(preferences.size, .small30x14)
            XCTAssertEqual(defaults.string(forKey: "niimbotLabelSize"), raw,
                           "Opening the screen must keep an unknown saved choice available for recovery")
            XCTAssertEqual(LabelPaperPreferences(defaults: defaults).size, .small30x14)
            preferences.select(.medium40x12)
            XCTAssertEqual(defaults.string(forKey: "niimbotLabelSize"), InventoryLabelSize.medium40x12.rawValue)
            XCTAssertEqual(LabelPaperPreferences(defaults: defaults).size, .medium40x12)
            XCTAssertEqual(defaults.string(forKey: "niimbotPaperMode"), "transparent",
                           "Physical dimensions and Gap/Transparent sensing remain separate settings")
        }
    }

    private func stock(price: Decimal? = 10.49, quantity: Int = 3, name: String = "Charmander", number: String = "044") -> ShowInventoryItem {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:512035", printing: "Holofoil", condition: "Near Mint"),
            name: name, set: "SV Promo", number: number, marketPrice: price, confidence: 100, printings: ["Holofoil"])
        return ShowInventoryItem(card: card, quantity: quantity, remainingCostCents: 700)
    }

    private func savedTag(_ tag: StickerPrice, for item: ShowInventoryItem,
                          manual: Bool = false) -> TagApprovalRecord {
        TagApprovalRecord(id: item.id, approvedTag: tag, priceRevisionID: UUID(), marketAtLastApproval: 10,
            isManualOverride: manual, approvedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastPrintedTag: nil, lastPrintedAt: nil)
    }

    func testDefaultsUseOneCopyAndWholeDollarSavedMarketWithoutMutatingStockOrActualCost() throws {
        let item = stock(), original = item
        var draft = InventoryLabelDraft(item: item)
        XCTAssertEqual(draft.id, item.id)
        XCTAssertEqual(draft.copies, 1)
        XCTAssertEqual(draft.priceCents, 1_000)
        XCTAssertEqual(draft.condition, "NM")
        XCTAssertEqual(draft.style, .priceOnly)
        draft.askingPriceText = "32"; draft.copies = 2; draft.style = .priceOnly
        try draft.validate()
        XCTAssertEqual(draft.priceCents, 3_200)
        XCTAssertEqual(item, original)
        XCTAssertEqual(item.quantity, 3)
        XCTAssertEqual(item.remainingCostCents, 700)
        XCTAssertEqual(item.card.marketPrice, 10.49)
    }

    func testMissingAndInvalidMarketsRemainUnavailableInsteadOfBecomingBulkOrZero() throws {
        for price in [nil, Decimal(-1), Decimal.nan] {
            let draft = InventoryLabelDraft(item: stock(price: price))
            XCTAssertFalse(draft.isBulk)
            XCTAssertNil(draft.priceCents)
            XCTAssertNil(draft.tag)
            XCTAssertThrowsError(try draft.validate())
        }
    }

    func testKnownMarketsBelowSeventyFiveCentsUseBulkWithoutAnIndividualLabelPrice() throws {
        for price in [Decimal.zero, Decimal(string: "0.49")!, Decimal(string: "0.50")!, Decimal(string: "0.74")!] {
            let draft = InventoryLabelDraft(item: stock(price: price))
            XCTAssertTrue(draft.isBulk)
            XCTAssertNil(draft.priceCents)
            XCTAssertEqual(draft.tag, .twoForOne)
            XCTAssertEqual(draft.priceText, "2 for $1")
            XCTAssertThrowsError(try draft.validate()) {
                XCTAssertEqual($0 as? InventoryLabelFailure, .bulkCategory)
            }
            XCTAssertThrowsError(try InventoryLabelRenderer.render(draft)) {
                XCTAssertEqual($0 as? InventoryLabelFailure, .bulkCategory)
            }
        }
    }

    func testIndividualDefaultsUseOneDollarBelowOneAndFloorWholeDollarsAboveIt() throws {
        for (price, cents) in [(Decimal(string: "0.75")!, Int64(100)), (Decimal(string: "0.99")!, 100),
                               (Decimal(string: "10.50")!, 1_000), (Decimal(string: "99.99")!, 9_900),
                               (Decimal(100), 10_000), (Decimal(string: "104.99")!, 10_000), (Decimal(105), 10_500)] {
            let draft = InventoryLabelDraft(item: stock(price: price))
            XCTAssertFalse(draft.isBulk)
            XCTAssertEqual(draft.priceCents, cents)
            XCTAssertEqual(draft.tag, .individual(cents))
            XCTAssertNoThrow(try draft.validate())
        }
    }

    func testStoredIndividualTagsIncludingZeroSurviveMarketMovementOrUnavailableQuotes() throws {
        let markets: [Decimal?] = [0, Decimal(string: "0.50"), 11, 145, nil, -1]
        for market in markets {
            for cents in [Int64(0), 700, 1_100] {
                let item = stock(price: market), original = item
                let saved = savedTag(.individual(cents), for: item)
                let draft = InventoryLabelDraft(item: item, approval: saved)
                XCTAssertEqual(draft.tag, .individual(cents))
                XCTAssertEqual(draft.priceCents, cents)
                XCTAssertFalse(draft.isBulk)
                XCTAssertFalse(draft.isManualOverride, "Stored final prices do not need a manual-override flag to survive")
                XCTAssertNoThrow(try draft.validate())
                XCTAssertEqual(item, original)
                XCTAssertEqual(draft.marketValue, market)
            }
        }
    }

    func testStoredBulkCategorySurvivesHigherMarketValuesWithoutBecomingAnIndividualTag() throws {
        let markets: [Decimal?] = [Decimal(string: "0.50"), 10, 150, nil]
        for market in markets {
            for manual in [false, true] {
                let item = stock(price: market), original = item
                let saved = savedTag(.twoForOne, for: item, manual: manual)
                let draft = InventoryLabelDraft(item: item, approval: saved)
                XCTAssertTrue(draft.isBulk)
                XCTAssertEqual(draft.tag, .twoForOne)
                XCTAssertNil(draft.priceCents)
                XCTAssertEqual(draft.priceText, StickerPrice.twoForOne.displayText)
                XCTAssertEqual(draft.isManualOverride, manual)
                XCTAssertThrowsError(try draft.validate()) {
                    XCTAssertEqual($0 as? InventoryLabelFailure, .bulkCategory)
                }
                XCTAssertEqual(item, original)
            }
        }
    }

    func testManualCentsPriceIsPreservedForReviewButCannotProduceAnIndividualLabel() throws {
        var draft = InventoryLabelDraft(item: stock())
        draft.askingPriceText = "32.50"
        XCTAssertEqual(draft.priceCents, 3_250)
        XCTAssertNil(draft.tag)
        XCTAssertThrowsError(try draft.validate()) {
            XCTAssertEqual($0 as? InventoryLabelFailure, .wholeDollarRequired)
        }
        XCTAssertThrowsError(try InventoryLabelRenderer.render(draft)) {
            XCTAssertEqual($0 as? InventoryLabelFailure, .wholeDollarRequired)
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

    func testBattleCageLabelRemovesTheExactPhotographedDuplicateWithoutChangingSavedMetadata() throws {
        let item = stock(name: "Battle Cage - 116/094", number: "116/094")
        let original = item
        var draft = InventoryLabelDraft(item: item)
        var expected = InventoryLabelDraft(item: stock(name: "Battle Cage", number: "116/094"))
        draft.style = .cardDetails
        expected.style = .cardDetails
        let title = InventoryLabelRenderer.titleComponents(name: draft.cardName, number: draft.cardNumber)
        XCTAssertEqual(title.name, "Battle Cage")
        XCTAssertEqual(title.number, "116/094")
        for paper in InventoryLabelSize.allCases {
            draft.paperSize = paper
            expected.paperSize = paper
            XCTAssertEqual(try InventoryLabelRenderer.renderRaster(draft),
                           try InventoryLabelRenderer.renderRaster(expected),
                           "The printed title must be Battle Cage · #116/094 with the code only once")
        }
        XCTAssertEqual(item, original)
        XCTAssertEqual(draft.cardName, "Battle Cage - 116/094")
        XCTAssertEqual(draft.cardNumber, "116/094")
        let unchanged = InventoryLabelRenderer.titleComponents(name: "Amaura", number: "27/131")
        XCTAssertEqual(unchanged.name, "Amaura")
        XCTAssertEqual(unchanged.number, "27/131")
    }

    func testLabelTitleDeduplicatesExactCodeTokensCaseVariantsWrappersAndHashSeparators() {
        for (name, number, expectedName, expectedNumber) in [
            ("Battle Cage - 116/094", "116/094", "Battle Cage", "116/094"),
            ("Battle Cage (116/094)", "116/094", "Battle Cage", "116/094"),
            ("Battle Cage (# 116/094)", "#116/094", "Battle Cage", "116/094"),
            ("Battle Cage [116/094]", "116/094", "Battle Cage", "116/094"),
            ("Battle Cage #116/094", " # 116/094 ", "Battle Cage", "116/094"),
            ("Battle Cage - ab12-en003", "AB12-EN003", "Battle Cage", "AB12-EN003"),
            ("AB12-EN003 · Battle Cage", "AB12-EN003", "Battle Cage", "AB12-EN003"),
            ("Battle AB12-EN003 Cage", "AB12-EN003", "Battle Cage", "AB12-EN003"),
            ("Battle Cage (ab12-en003) - #AB12-EN003", "AB12-EN003", "Battle Cage", "AB12-EN003"),
            ("Battle Cage (Normal 116/094)", "116/094", "Battle Cage (Normal)", "116/094"),
            ("Battle Cage - 116/094 - Normal", "116/094", "Battle Cage - Normal", "116/094"),
            ("Charmander (#044)", "044", "Charmander", "044"),
            ("Charmander - 044", "044", "Charmander", "044"),
            ("AB12-EN003", "AB12-EN003", "", "AB12-EN003")
        ] {
            let title = InventoryLabelRenderer.titleComponents(name: name, number: number)
            XCTAssertEqual(title.name, expectedName, name)
            XCTAssertEqual(title.number, expectedNumber, number)
        }
    }

    func testLabelTitleKeepsIncidentalSubstringsDifferentCodesAndMeaningfulNameNumbers() {
        for (name, number) in [
            ("Battle Cage - 116/0940", "116/094"),
            ("Battle Cage - 1116/094", "116/094"),
            ("Battle Cage - X116/094", "116/094"),
            ("Battle Cage - 116/094-JP", "116/094"),
            ("Battle Cage - 116/094.5", "116/094"),
            ("Battle Cage - 116/094_1", "116/094"),
            ("Battle Cage - 116/095", "116/094"),
            ("Battle Cage (116/0940)", "116/094"),
            ("Porygon2", "2"),
            ("Number 39: Utopia", "39"),
            ("Number 39", "39"),
            ("The 2025 Champion", "2025"),
            ("Promo Dragon", "Promo"),
            ("Battle Cage - 116/094", "")
        ] {
            let title = InventoryLabelRenderer.titleComponents(name: name, number: number)
            XCTAssertEqual(title.name, name, "Only an exact, separately identified code may be removed: " + name)
            XCTAssertEqual(title.number, number)
        }
    }

    func testPriceOnlyRasterIsIndependentOfDuplicateTitleMetadata() throws {
        var duplicated = InventoryLabelDraft(item: stock(name: "Battle Cage - 116/094", number: "116/094"))
        var other = InventoryLabelDraft(item: stock(name: "Amaura", number: "27/131"))
        duplicated.style = .priceOnly
        other.style = .priceOnly
        for paper in InventoryLabelSize.allCases {
            duplicated.paperSize = paper
            other.paperSize = paper
            XCTAssertEqual(try InventoryLabelRenderer.renderRaster(duplicated),
                           try InventoryLabelRenderer.renderRaster(other))
        }
    }

    private func black(_ raster: LabelRaster, x: Int, y: Int) -> Bool {
        let head = raster.width - 1 - y
        return raster.data[x * 12 + head / 8] & (0x80 >> (head % 8)) != 0
    }

    func testBrandedPriceLayoutKeepsWhitePaperMarginsRoundedFrameDividerAndWordmarkAcrossEveryRoll() throws {
        let data = try XCTUnwrap(NSDataAsset(name: "PokeDenWordmark")?.data,
                                "The label must draw its outlined wordmark directly from the vector source")
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, 1)
        for paper in InventoryLabelSize.allCases {
            let draft = CustomPriceTagDraft(priceCents: 1_500, copies: 1, paperSize: paper)
            let raster = try InventoryLabelRenderer.renderRaster(draft)
            XCTAssertEqual(raster.width, 96)
            XCTAssertEqual(raster.height, paper.feedDots)
            for x in 0..<paper.feedDots {
                XCTAssertFalse(black(raster, x: x, y: 0))
                XCTAssertFalse(black(raster, x: x, y: 95))
            }
            for y in 0..<96 {
                XCTAssertFalse(black(raster, x: 0, y: y))
                XCTAssertFalse(black(raster, x: paper.feedDots - 1, y: y))
            }
            // A rounded frame leaves its corner clear but has a continuous top
            // edge. The only tall interior rule must divide logo and price.
            XCTAssertFalse(black(raster, x: 4, y: 4))
            XCTAssertTrue(black(raster, x: paper.feedDots / 3, y: 3))
            let dividerColumns = (20..<(paper.feedDots - 20)).filter { x in
                (12..<84).filter { black(raster, x: x, y: $0) }.count >= 68
            }
            let divider = try XCTUnwrap(dividerColumns.first)
            XCTAssertEqual(dividerColumns.count, 2, "A two-dot rule survives thermal printing without a gray fringe")
            XCTAssertFalse(black(raster, x: divider, y: 10), "The divider stays separate from the rounded frame")
            XCTAssertGreaterThan(divider, paper.feedDots / 2)
            XCTAssertLessThan(divider, paper.feedDots * 3 / 5)
            let logoInk = (12..<(divider - 8)).reduce(0) { count, x in
                count + (18..<78).filter { black(raster, x: x, y: $0) }.count
            }
            let priceInk = ((divider + 8)..<(paper.feedDots - 10)).reduce(0) { count, x in
                count + (12..<84).filter { black(raster, x: x, y: $0) }.count
            }
            XCTAssertGreaterThan(logoInk, 150)
            XCTAssertGreaterThan(priceInk, 100)
        }
    }

    func testBrandedWholePricesAndBulkKeepTheSameLogoAndNeverClipToTheFrame() throws {
        for paper in InventoryLabelSize.allCases {
            let baseline = try InventoryLabelRenderer.renderRaster(CustomPriceTagDraft(priceCents: 100, copies: 1, paperSize: paper))
            let divider = Int(floor(CGFloat(paper.feedDots) * 0.56))
            let baselineLogo = (8..<(divider - 4)).flatMap { x in (8..<88).map { black(baseline, x: x, y: $0) } }
            for price in [Int64(100), 1_500, 12_500, 125_000, ShowBudgetMoney.maximumCents / 100 * 100] {
                let draft = CustomPriceTagDraft(priceCents: price, copies: 1, paperSize: paper)
                let raster = try InventoryLabelRenderer.renderRaster(draft)
                let bitmap = try InventoryLabelRenderer.render(draft)
                XCTAssertEqual(raster, bitmap.raster)
                let logo = (8..<(divider - 4)).flatMap { x in (8..<88).map { black(raster, x: x, y: $0) } }
                XCTAssertEqual(logo, baselineLogo)
                for x in (divider + 2)..<(paper.feedDots - 8) {
                    XCTAssertFalse(black(raster, x: x, y: 7), "A complete amount must fit inside the frame")
                    XCTAssertFalse(black(raster, x: x, y: 88), "A complete amount must fit inside the frame")
                }
            }
            let bulk = try InventoryLabelRenderer.renderRaster(CustomPriceTagDraft(priceCents: 0, copies: 1, paperSize: paper, isBulk: true))
            let bulkLogo = (8..<(divider - 4)).flatMap { x in (8..<88).map { black(bulk, x: x, y: $0) } }
            XCTAssertEqual(bulkLogo, baselineLogo)
            let bulkInk = ((divider + 8)..<(paper.feedDots - 10)).reduce(0) { count, x in
                count + (18..<78).filter { black(bulk, x: x, y: $0) }.count
            }
            XCTAssertGreaterThan(bulkInk, 100, "The supplied bulk variant must fit entirely inside the price panel")
            XCTAssertNotEqual(bulk, baseline, "Bulk must use its explicit deal design, not an individual-price guess")
        }
    }

    func testSupersampledCoveragePacksOnlyFinalPrinterDotsWithoutDitherOrResolutionChanges() throws {
        let width = 240, height = 96, scale = 4
        let sampleWidth = width * scale
        var samples = [UInt8](repeating: 255, count: width * height * scale * scale)
        let marks = [(10, 16), (11, 9), (12, 8), (13, 7)]
        for (x, darkSamples) in marks {
            for sample in 0..<darkSamples {
                samples[(20 * scale + sample / scale) * sampleWidth + x * scale + sample % scale] = 0
            }
        }
        for x in [14, 15] {
            for sample in 0..<16 {
                samples[(20 * scale + sample / scale) * sampleWidth + x * scale + sample % scale] = x == 14 ? 127 : 128
            }
        }
        let bitmap = try InventoryLabelRenderer.bitmap(grayscale: samples, landscapeWidth: width,
                                                       landscapeHeight: height, samplesPerDot: scale)
        XCTAssertEqual(bitmap.raster.width, 96)
        XCTAssertEqual(bitmap.raster.height, 240)
        XCTAssertEqual(bitmap.raster.data.count, 240 * 12)
        for x in [10, 11, 12, 14] { XCTAssertTrue(black(bitmap.raster, x: x, y: 20)) }
        for x in [13, 15] { XCTAssertFalse(black(bitmap.raster, x: x, y: 20)) }
        XCTAssertEqual(bitmap.raster.data.reduce(0) { $0 + $1.nonzeroBitCount }, 4,
                       "Coverage produces one bit per physical dot, without spreading dots into a dither pattern")
        let image = try XCTUnwrap(bitmap.previewImage.cgImage)
        let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertTrue(pixels.allSatisfy { $0 == 0 || $0 == 255 }, "The preview must decode the same 1-bit printer data")
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
                XCTAssertEqual(try InventoryLabelRenderer.renderRaster(draft), bitmap.raster,
                               "Queue preparation must preserve the exact same bits without decoding a preview")
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
        let maximumWholeTierCents = ShowBudgetMoney.maximumCents / 500 * 500
        for style in InventoryLabelStyle.allCases {
            var draft = InventoryLabelDraft(item: stock(name: String(repeating: "超長いカード e\u{301} 🃏 ", count: 100), number: "99/102"))
            draft.style = style
            draft.askingPriceText = InventoryLabelDraft.inputText(maximumWholeTierCents)
            let bitmap = try InventoryLabelRenderer.render(draft)
            XCTAssertEqual(bitmap.raster.data.count, 240 * 12)
            XCTAssertLessThanOrEqual(draft.cardName.count, 500)
            XCTAssertEqual(draft.priceCents, maximumWholeTierCents)
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
