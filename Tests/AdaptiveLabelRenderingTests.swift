import XCTest
import UIKit
@testable import CardShowScanner

@MainActor final class AdaptiveLabelRenderingTests: XCTestCase {
    private func black(_ raster: LabelRaster, x: Int, y: Int) -> Bool {
        let head = raster.width - 1 - y
        return raster.data[x * 12 + head / 8] & (0x80 >> (head % 8)) != 0
    }

    private func assertInkInside(_ raster: LabelRaster, _ area: NiimbotLabelArea,
                                 file: StaticString = #filePath, line: UInt = #line) {
        var ink = 0, outside: String?
        for x in 0..<raster.height {
            for y in 0..<raster.width where black(raster, x: x, y: y) {
                ink += 1
                if Double(x) < area.x || Double(x + 1) > area.maxX || Double(y) < area.y || Double(y + 1) > area.maxY {
                    outside = "Ink outside printable region at \(x),\(y)"
                }
            }
        }
        XCTAssertGreaterThan(ink, 0, "The generated label cannot be blank", file: file, line: line)
        XCTAssertNil(outside, outside ?? "", file: file, line: line)
    }

    private func pixels(_ image: UIImage) throws -> Data {
        let cgImage = try XCTUnwrap(image.cgImage)
        return try XCTUnwrap(cgImage.dataProvider?.data) as Data
    }

    private func physical(_ local: CGRect, geometry: LabelPrintGeometry) -> CGRect {
        let area = geometry.printableArea
        if geometry.contentRotation == 180 {
            return CGRect(x: CGFloat(area.x + area.width) - local.maxX,
                          y: CGFloat(area.y + area.height) - local.maxY,
                          width: local.width, height: local.height)
        }
        return local.offsetBy(dx: CGFloat(area.x), dy: CGFloat(area.y))
    }

    private func ink(_ raster: LabelRaster, in area: CGRect) -> Int {
        var count = 0
        for x in Int(ceil(area.minX))..<Int(floor(area.maxX)) {
            for y in Int(ceil(area.minY))..<Int(floor(area.maxY)) where black(raster, x: x, y: y) { count += 1 }
        }
        return count
    }

    func testEveryCatalogProductGeneratesOneDesignInsideItsMeasuredPrintableRegion() throws {
        let catalog = NiimbotLabelCatalog.shared
        XCTAssertEqual(catalog.count, 130)
        let vector = try XCTUnwrap(NSDataAsset(name: "PokeDenWordmark")?.data)
        XCTAssertEqual(String(data: vector.prefix(4), encoding: .ascii), "%PDF",
                       "Every product uses the shared vector wordmark rather than per-product PNG artwork")
        for product in catalog.allProducts {
            let paper = try InventoryLabelSize(product: product)
            let raster = try InventoryLabelRenderer.renderRaster(CustomPriceTagDraft(priceCents: 2_800, copies: 1, paperSize: paper))
            XCTAssertEqual(raster.width, 96, product.code)
            XCTAssertEqual(raster.height, product.geometry.feedDots, product.code)
            XCTAssertEqual(raster.data.count, 12 * product.geometry.feedDots, product.code)
            assertInkInside(raster, product.geometry.printableArea)
        }
    }

    func testShortNarrowLongAndCableStockFitZeroMaximumAndBulkPricesOnEitherSide() throws {
        let products = NiimbotLabelCatalog.shared.allProducts
        let samples = [
            try XCTUnwrap(products.first { $0.geometry.feedDots == 176 }),
            try XCTUnwrap(products.first { min($0.width, $0.height) == 10 }),
            try XCTUnwrap(products.first { $0.geometry.feedDots == 600 }),
            try XCTUnwrap(products.first { $0.isCable }),
            try XCTUnwrap(products.first { $0.isMultiRegion })
        ]
        let maximum = ShowBudgetMoney.maximumCents / 100 * 100
        let variants: [(Int64, Bool)] = [(0, false), (maximum, false), (0, true)]
        for product in samples {
            let paper = try InventoryLabelSize(product: product)
            for position in LabelPricePosition.allCases {
                for (price, bulk) in variants {
                    let draft = CustomPriceTagDraft(priceCents: price, copies: 1, paperSize: paper,
                                                   isBulk: bulk, pricePosition: position)
                    let bitmap = try InventoryLabelRenderer.render(draft)
                    assertInkInside(bitmap.raster, product.geometry.printableArea)
                    XCTAssertEqual(bitmap.previewImage.size, CGSize(width: CGFloat(paper.feedDots), height: 96))
                    XCTAssertEqual(try pixels(bitmap.previewImage),
                                   try pixels(InventoryLabelRenderer.image(raster: bitmap.raster, paper: paper)))
                    XCTAssertTrue(try pixels(bitmap.previewImage).allSatisfy { $0 == 0 || $0 == 255 })
                }
            }
        }
    }

    func testAdaptivePriceSideTranslatesTheLogoWithoutMirroringItsLetters() throws {
        let product = try XCTUnwrap(NiimbotLabelCatalog.shared.product(code: "120425109"))
        let paper = try InventoryLabelSize(product: product), area = product.geometry.printableArea
        let right = try InventoryLabelRenderer.renderRaster(CustomPriceTagDraft(priceCents: 2_800, copies: 1,
            paperSize: paper, pricePosition: .right))
        let left = try InventoryLabelRenderer.renderRaster(CustomPriceTagDraft(priceCents: 2_800, copies: 1,
            paperSize: paper, pricePosition: .left))
        let rightLayout = InventoryLabelRenderer.adaptiveBrandedPriceLayout(width: CGFloat(area.width), height: CGFloat(area.height),
            price: "$28", pricePosition: .right)
        let leftLayout = InventoryLabelRenderer.adaptiveBrandedPriceLayout(width: CGFloat(area.width), height: CGFloat(area.height),
            price: "$28", pricePosition: .left)
        XCTAssertEqual(rightLayout.logoArea.size, leftLayout.logoArea.size)
        XCTAssertEqual(rightLayout.priceArea.size, leftLayout.priceArea.size)
        let delta = Int((leftLayout.logoArea.minX - rightLayout.logoArea.minX).rounded())
        var logoInk = 0, mismatches = 0
        for x in Int(ceil(CGFloat(area.x) + rightLayout.logoArea.minX))..<Int(floor(CGFloat(area.x) + rightLayout.logoArea.maxX)) {
            for y in Int(ceil(CGFloat(area.y) + rightLayout.logoArea.minY))..<Int(floor(CGFloat(area.y) + rightLayout.logoArea.maxY)) {
                if black(right, x: x, y: y) { logoInk += 1 }
                if black(right, x: x, y: y) != black(left, x: x + delta, y: y) { mismatches += 1 }
            }
        }
        XCTAssertGreaterThan(logoInk, 20)
        XCTAssertEqual(mismatches, 0, "Changing price side moves the exact wordmark pixels instead of reflecting them")
        assertInkInside(left, area)
        assertInkInside(right, area)
    }

    func testReverseFeedStockKeepsThePhysicalRasterAndShowsAnUprightPreview() throws {
        let product = try NiimbotLabelProduct(code: "9900001", width: 30, height: 12, rotation: 270, paperType: 1,
            inputAreas: [.init(x: 1, y: 1, width: 18, height: 9)])
        let paper = try InventoryLabelSize(product: product)
        let draft = CustomPriceTagDraft(priceCents: 2_800, copies: 1, paperSize: paper, pricePosition: .left)
        let bitmap = try InventoryLabelRenderer.render(draft)
        let raw = try pixels(InventoryLabelRenderer.image(raster: bitmap.raster))
        let upright = try pixels(bitmap.previewImage)
        XCTAssertEqual(product.geometry.contentRotation, 180)
        XCTAssertNotEqual(raw, upright)
        XCTAssertEqual(upright, Data(raw.reversed()), "Presentation rotates the decoded printer bits without rewriting the queued raster")
        XCTAssertEqual(try InventoryLabelRenderer.renderRaster(draft), bitmap.raster)
        assertInkInside(bitmap.raster, product.geometry.printableArea)
    }

    func testDetectedPapersLeaveZeroAndUnavailablePricePanelsEmptyWithoutLosingTheBrand() throws {
        let products = NiimbotLabelCatalog.shared.allProducts
        let samples = [
            try XCTUnwrap(products.first { $0.code == "120425109" }),
            try XCTUnwrap(products.first { min($0.width, $0.height) == 10 }),
            try XCTUnwrap(products.first { $0.geometry.feedDots == 176 }),
            try XCTUnwrap(products.first { $0.geometry.feedDots == 600 }),
            try XCTUnwrap(products.first { $0.paperType == 5 }),
            try XCTUnwrap(products.first { $0.rotation == 0 }),
            try XCTUnwrap(products.first { $0.rotation == 270 })
        ]
        for product in samples {
            let paper = try InventoryLabelSize(product: product), geometry = product.geometry
            for side in LabelPricePosition.allCases {
                let layout = InventoryLabelRenderer.adaptiveBrandedPriceLayout(width: CGFloat(geometry.printableArea.width),
                    height: CGFloat(geometry.printableArea.height), price: "", pricePosition: side)
                let custom = CustomPriceTagDraft(priceCents: 0, copies: 1, paperSize: paper, pricePosition: side)
                let bitmap = try InventoryLabelRenderer.render(custom)
                XCTAssertEqual(custom.priceText, "")
                XCTAssertEqual(ink(bitmap.raster, in: physical(layout.priceArea, geometry: geometry)), 0,
                    "A zero price must leave room to write an amount without a currency symbol or zero")
                XCTAssertGreaterThan(ink(bitmap.raster, in: physical(layout.logoArea, geometry: geometry)), 0)
                assertInkInside(bitmap.raster, geometry.printableArea)
                let card = CardCandidate(identity: .init(game: "Pokémon", productID: "blank-fixture", printing: "Normal"),
                    name: "Write-in card", set: "Fixture", number: "42", marketPrice: nil, confidence: 100, printings: ["Normal"])
                var draft = InventoryLabelDraft(item: ShowInventoryItem(card: card, quantity: 1))
                draft.paperSize = paper; draft.pricePosition = side
                XCTAssertEqual(try InventoryLabelRenderer.renderRaster(draft), bitmap.raster,
                    "Missing inventory prices use the same write-in design as an explicit zero")
                XCTAssertEqual(try pixels(bitmap.previewImage),
                               try pixels(InventoryLabelRenderer.image(raster: bitmap.raster, paper: paper)))
            }
        }
    }

    func testDetectedCardDetailsKeepAWriteInPriceSpaceAndTheCardMetadata() throws {
        for rotation in [0, 90, 270] {
            let portrait = rotation == 0
            let product = try NiimbotLabelProduct(code: "9900003", width: portrait ? 12 : 30,
                height: portrait ? 30 : 12, rotation: rotation, paperType: 5,
                inputAreas: [.init(x: 1, y: 1, width: portrait ? 10 : 28, height: portrait ? 28 : 10)])
            let paper = try InventoryLabelSize(product: product), geometry = product.geometry
            let card = CardCandidate(identity: .init(game: "Pokémon", productID: "blank-details", printing: "Normal", condition: "Near Mint"),
                name: "Write-in card", set: "Fixture", number: "42", marketPrice: nil, confidence: 100, printings: ["Normal"])
            var draft = InventoryLabelDraft(item: ShowInventoryItem(card: card, quantity: 1))
            draft.paperSize = paper; draft.style = .cardDetails
            let bitmap = try InventoryLabelRenderer.render(draft)
            let width = CGFloat(geometry.printableArea.width), height = CGFloat(geometry.printableArea.height)
            let padding = max(2, min(6, height * 0.07))
            let writeInArea = CGRect(x: padding, y: height * 0.36, width: width * 0.6 - padding, height: height * 0.56)
            XCTAssertEqual(ink(bitmap.raster, in: physical(writeInArea, geometry: geometry)), 0)
            XCTAssertGreaterThan(ink(bitmap.raster, in: physical(CGRect(x: padding, y: padding,
                width: width - padding * 2, height: height * 0.28), geometry: geometry)), 0)
            XCTAssertGreaterThan(ink(bitmap.raster, in: physical(CGRect(x: width * 0.7, y: height * 0.36,
                width: width * 0.3 - padding, height: height * 0.56), geometry: geometry)), 0)
            assertInkInside(bitmap.raster, geometry.printableArea)
            draft.askingPriceText = "0"
            XCTAssertEqual(try InventoryLabelRenderer.renderRaster(draft), bitmap.raster)
        }
    }

    func testPortraitSourceAreasAndCardDetailsUseTheSameBoundedGeneratedCanvas() throws {
        let product = try NiimbotLabelProduct(code: "9900002", width: 12, height: 25, rotation: 0, paperType: 5,
            inputAreas: [.init(x: 2, y: 3, width: 8, height: 18)])
        let paper = try InventoryLabelSize(product: product)
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "fixture", printing: "Normal", condition: "Near Mint"),
            name: String(repeating: "長いカード ", count: 30), set: "Fixture", number: "116/094", marketPrice: 28,
            confidence: 100, printings: ["Normal"])
        var draft = InventoryLabelDraft(item: ShowInventoryItem(card: card, quantity: 1, remainingCostCents: 100))
        draft.style = .cardDetails; draft.paperSize = paper
        draft.askingPriceText = InventoryLabelDraft.inputText(ShowBudgetMoney.maximumCents / 100 * 100)
        let bitmap = try InventoryLabelRenderer.render(draft)
        XCTAssertEqual(bitmap.raster.height, 200)
        XCTAssertEqual(product.geometry.printableArea, .init(x: 24, y: 16, width: 144, height: 64))
        assertInkInside(bitmap.raster, product.geometry.printableArea)
        XCTAssertEqual(try pixels(bitmap.previewImage), try pixels(InventoryLabelRenderer.image(raster: bitmap.raster, paper: paper)))
    }

    func testArbitraryMeasuredFeedLengthStillPacksOneBitPerHeadDotWithBoundedMemory() throws {
        let width = 200, height = 96
        var pixels = [UInt8](repeating: 255, count: width * height)
        pixels[12 * width + 18] = 0
        let bitmap = try InventoryLabelRenderer.bitmap(grayscale: pixels, landscapeWidth: width, landscapeHeight: height)
        XCTAssertEqual(bitmap.raster.height, 200)
        XCTAssertEqual(bitmap.raster.data.count, 2_400)
        XCTAssertTrue(black(bitmap.raster, x: 18, y: 12))
        XCTAssertEqual(bitmap.raster.data.reduce(0) { $0 + $1.nonzeroBitCount }, 1)
        XCTAssertThrowsError(try InventoryLabelRenderer.bitmap(grayscale: [], landscapeWidth: 0, landscapeHeight: 96))
        XCTAssertThrowsError(try InventoryLabelRenderer.bitmap(grayscale: [], landscapeWidth: 801, landscapeHeight: 96))
        XCTAssertThrowsError(try InventoryLabelRenderer.bitmap(grayscale: [], landscapeWidth: Int.max, landscapeHeight: 96))
    }
}
