import XCTest
@testable import CardShowScanner

@MainActor final class CatalogLabelSelectionTests: XCTestCase {
    private func paper(code: String = "123456789", width: Double = 40,
                       areaX: Double = 1) throws -> InventoryLabelSize {
        let product = try NiimbotLabelProduct(code: code, width: width, height: 12,
            rotation: 90, paperType: 1,
            inputAreas: [NiimbotLabelArea(x: areaX, y: 1, width: width - areaX - 1, height: 10)])
        return try InventoryLabelSize(product: product)
    }

    func testBatchRasterCacheSeparatesGeometryRevisionsPricesAndPriceSides() throws {
        let original = try paper(), corrected = try paper(areaX: 2)
        XCTAssertEqual(original.product?.code, corrected.product?.code)
        XCTAssertEqual(original.feedDots, corrected.feedDots)
        XCTAssertEqual(original.headDots, corrected.headDots)
        let first = LabelPriceRasterKey(paperSize: original, pricePosition: .left, priceText: "$5")
        let cache = [first: "prepared artwork"]
        XCTAssertEqual(cache[LabelPriceRasterKey(paperSize: original, pricePosition: .left, priceText: "$5")],
                       "prepared artwork", "Identical labels can reuse the generated raster")
        XCTAssertNil(cache[LabelPriceRasterKey(paperSize: corrected, pricePosition: .left, priceText: "$5")],
                     "The same product code with a corrected printable region needs new artwork")
        XCTAssertNil(cache[LabelPriceRasterKey(paperSize: original, pricePosition: .right, priceText: "$5")])
        XCTAssertNil(cache[LabelPriceRasterKey(paperSize: original, pricePosition: .left, priceText: "$6")])
    }

    func testNewDetectedRollUpdatesCustomPreparationWithoutRewritingSavedLabelsOrPreferences() throws {
        let suite = "CatalogLabelSelectionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LabelPaperPreferences(defaults: defaults)
        preferences.select(.small30x15)
        preferences.selectPricePosition(.left)
        let first = try paper(), next = try paper(code: "987654321", width: 22)
        preferences.updateDetectedProduct(first.product)

        var savedBytes: Data?
        var renderedDrafts: [CustomPriceTagDraft] = []
        let queue = LabelPrintQueue(read: { _ in savedBytes }, write: { data, _ in savedBytes = data })
        let model = CustomPriceTagModel(queue: queue, paperSize: preferences.size,
                                       pricePosition: preferences.pricePosition) { draft in
            renderedDrafts.append(draft)
            return LabelRaster(width: draft.paperSize.headDots, height: draft.paperSize.feedDots,
                data: Data(repeating: 0x80, count: 12 * draft.paperSize.feedDots))
        }
        model.price = "7"; model.copies = "2"
        XCTAssertTrue(model.prepare())
        XCTAssertTrue(model.hasPreparedQueue)
        let originalQueue = queue.entries, originalBytes = savedBytes
        XCTAssertTrue(originalQueue.allSatisfy { $0.paperSize == first })

        preferences.updateDetectedProduct(next.product)
        // The views synchronize these values on preference changes and again
        // immediately before their explicit Prepare action.
        model.paperSize = preferences.size
        model.pricePosition = preferences.pricePosition
        XCTAssertEqual(model.paperSize, next)
        XCTAssertFalse(model.hasPreparedQueue)
        XCTAssertEqual(queue.entries, originalQueue)
        XCTAssertEqual(savedBytes, originalBytes, "Detecting stock cannot resize already prepared labels")
        XCTAssertFalse(model.prepare(), "The existing queue must be reviewed or cleared before replacement")
        XCTAssertEqual(queue.entries, originalQueue)

        try queue.clear()
        XCTAssertTrue(model.prepare())
        XCTAssertTrue(queue.entries.allSatisfy { $0.paperSize == next && $0.raster.height == 176 })
        XCTAssertEqual(renderedDrafts.map(\.pricePosition), [.left, .left])
        XCTAssertEqual(defaults.string(forKey: "niimbotLabelSize"), InventoryLabelSize.small30x15.rawValue)
        XCTAssertEqual(defaults.string(forKey: "niimbotLabelPricePosition"), LabelPricePosition.left.rawValue)

        preferences.updateDetectedProduct(nil)
        XCTAssertEqual(preferences.size, .small30x15, "Unknown or disconnected stock restores the saved manual fallback")
        XCTAssertEqual(preferences.pricePosition, .left)
        XCTAssertTrue(queue.entries.allSatisfy { $0.paperSize == next }, "Clearing detection cannot rewrite the new queue")
    }
}
