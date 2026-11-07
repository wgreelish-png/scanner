import XCTest
@testable import CardShowScanner

final class NiimbotLabelCatalogTests: XCTestCase {
    func testRollDetectionDiagnosticsIdentifyThirtyByTwelveStockWithoutNeedingValidCounters() throws {
        let product = try XCTUnwrap(NiimbotLabelCatalog.shared.product(code: "010424790"))
        let info = NiimbotRollInfo(productCode: product.code, totalLabels: 0, usedLabels: 999, labelType: 1)
        XCTAssertNil(info.estimate, "Size detection must remain independent of optional remaining-label counters")
        XCTAssertEqual(NiimbotRollDetection.diagnosticFields(info), [
            "roll_detection_result": "matched", "roll_product_code": "010424790",
            "label_width_mm": "30.0", "label_height_mm": "12.0",
            "label_feed_dots": "240", "label_head_dots": "96"
        ])
    }

    func testRollDetectionDiagnosticsDistinguishUnknownStockMediaMismatchAndUnavailableReads() {
        let unknown = NiimbotRollInfo(productCode: "00000000", totalLabels: 70, usedLabels: 0, labelType: 1)
        XCTAssertEqual(NiimbotRollDetection.diagnosticFields(unknown), [
            "roll_detection_result": "unknown_product", "roll_product_code": "00000000"
        ])
        let mismatched = NiimbotRollInfo(productCode: "120425109", totalLabels: 70, usedLabels: 0, labelType: 5)
        XCTAssertEqual(NiimbotRollDetection.diagnosticFields(mismatched), [
            "roll_detection_result": "media_mismatch", "roll_product_code": "120425109"
        ], "A known code with incompatible media cannot claim a detected paper size")
        XCTAssertEqual(NiimbotRollDetection.diagnosticFields(nil), ["roll_detection_result": "unavailable"])
        for invalidCode in ["PRIVATE_ROLL_SERIAL", "120425109\nPRIVATE", String(repeating: "7", count: 33)] {
            let invalid = NiimbotRollInfo(productCode: invalidCode, totalLabels: 70, usedLabels: 0, labelType: 1)
            XCTAssertEqual(NiimbotRollDetection.diagnosticFields(invalid), ["roll_detection_result": "unknown_product"])
        }
    }

    private func product(width: Double = 40, height: Double = 12, rotation: Int = 90,
                         areas: [NiimbotLabelArea] = [], flags: UInt8 = 0) throws -> NiimbotLabelProduct {
        try NiimbotLabelProduct(code: "00123456", width: width, height: height,
            rotation: rotation, paperType: 1, flags: flags, inputAreas: areas)
    }

    func testBundledCatalogPreservesAllCodesRegionsAndSpecialStockFlags() throws {
        let catalog = NiimbotLabelCatalog.shared, products = catalog.allProducts
        XCTAssertEqual(catalog.count, 130)
        XCTAssertEqual(products.filter { $0.code.hasPrefix("0") }.count, 92)
        XCTAssertEqual(products.reduce(0) { $0 + $1.inputAreas.count }, 150)
        XCTAssertEqual(products.filter(\.isCable).count, 7)
        XCTAssertEqual(products.filter(\.isMultiRegion).count, 5)
        XCTAssertEqual(products.filter { $0.paperType == 5 }.count, 13)
        XCTAssertEqual(products.filter { $0.rotation == 270 }.map(\.code), ["06112017"])
        XCTAssertNil(catalog.product(code: "6172315"), "Product codes never lose their leading zero")
        for product in products {
            let geometry = product.geometry, area = geometry.printableArea
            XCTAssertTrue((1...800).contains(geometry.feedDots), product.code)
            XCTAssertEqual(geometry.headDots, 96)
            XCTAssertGreaterThan(area.width, 0); XCTAssertGreaterThan(area.height, 0)
            XCTAssertGreaterThanOrEqual(area.x, 0); XCTAssertGreaterThanOrEqual(area.y, 0)
            XCTAssertLessThanOrEqual(area.maxX, Double(geometry.feedDots))
            XCTAssertLessThanOrEqual(area.maxY, 96)
            XCTAssertEqual(area.x.rounded(), area.x); XCTAssertEqual(area.y.rounded(), area.y)
            XCTAssertEqual(area.width.rounded(), area.width); XCTAssertEqual(area.height.rounded(), area.height)
        }
    }

    func testKnownFortyByTwelveRollUsesItsActualPrintableAreaWithoutRoundingSourceMetadata() throws {
        let roll = try XCTUnwrap(NiimbotLabelCatalog.shared.product(code: "120425109"))
        XCTAssertEqual(roll.width, 40); XCTAssertEqual(roll.height, 12); XCTAssertEqual(roll.rotation, 90)
        XCTAssertEqual(roll.inputAreas[0].x, 1.691331924)
        XCTAssertEqual(roll.inputAreas[0].width, 36.7019027508)
        XCTAssertEqual(roll.geometry.feedDots, 320)
        XCTAssertEqual(roll.geometry.printableArea, NiimbotLabelArea(x: 14, y: 5, width: 293, height: 86))
        XCTAssertEqual(roll.geometry.contentRotation, 0)
        XCTAssertFalse(roll.geometry.usesFallbackArea)
    }

    func testPortraitSourceMapsBackToItsOriginalPhysicalAxesAfterTheExistingPacker() throws {
        let roll = try product(width: 12, height: 40, rotation: 0,
            areas: [NiimbotLabelArea(x: 1, y: 3, width: 9, height: 35)])
        let area = roll.geometry.printableArea
        XCTAssertEqual(roll.geometry.feedDots, 320)
        XCTAssertEqual(area, NiimbotLabelArea(x: 24, y: 16, width: 280, height: 72))
        // The packer reverses landscape Y into head X. These physical edges
        // must recover the original 1 mm head / 3 mm feed coordinates.
        XCTAssertEqual(96 - area.maxY, 8)
        XCTAssertEqual(area.x, 24)
    }

    func testNinetyAndTwoSeventyDegreeStocksUseDifferentPhysicalPlacement() throws {
        let source = NiimbotLabelArea(x: 2, y: 1, width: 20, height: 8)
        let ninety = try product(areas: [source]).geometry
        let reversed = try product(rotation: 270, areas: [source]).geometry
        XCTAssertEqual(ninety.printableArea, NiimbotLabelArea(x: 16, y: 8, width: 160, height: 64))
        XCTAssertEqual(96 - ninety.printableArea.maxY, 24)
        XCTAssertEqual(reversed.printableArea, NiimbotLabelArea(x: 144, y: 24, width: 160, height: 64))
        XCTAssertEqual(96 - reversed.printableArea.maxY, 8, "270° maps the source Y directly into physical head X")
        XCTAssertEqual(reversed.printableArea.x, (40 - 2 - 20) * 8)
        XCTAssertEqual(reversed.contentRotation, 180)
    }

    func testPhysicalStockAndTwelveMillimetreHeadBoundsBothConstrainTheDesign() throws {
        let wider = try product(width: 30, height: 14).geometry
        XCTAssertEqual(wider.feedDots, 240)
        XCTAssertEqual(wider.printableArea, NiimbotLabelArea(x: 0, y: 0, width: 240, height: 96))
        let narrower = try product(width: 25, height: 10).geometry
        XCTAssertEqual(narrower.feedDots, 200)
        XCTAssertEqual(narrower.printableArea, NiimbotLabelArea(x: 0, y: 8, width: 200, height: 80))
    }

    func testSourceBoundsAnomaliesAreRetainedButCannotPlaceInkOutsideTheLabel() throws {
        let overEdge = try XCTUnwrap(NiimbotLabelCatalog.shared.product(code: "010424810"))
        XCTAssertGreaterThan(overEdge.inputAreas[0].maxX, overEdge.width)
        XCTAssertEqual(overEdge.geometry.printableArea.maxX, Double(overEdge.geometry.feedDots))
        let negative = try XCTUnwrap(NiimbotLabelCatalog.shared.product(code: "01142225"))
        XCTAssertLessThan(negative.inputAreas[0].y, 0)
        XCTAssertGreaterThanOrEqual(negative.geometry.printableArea.y, 0)
    }

    func testSpecialtyStockKeepsAllRegionsButDrawsOneDesignInTheLargestUsableRegion() throws {
        let first = NiimbotLabelArea(x: 1, y: 1, width: 10, height: 8)
        let second = NiimbotLabelArea(x: 15, y: 1, width: 20, height: 8)
        let roll = try product(areas: [first, second], flags: 3)
        XCTAssertTrue(roll.isCable); XCTAssertTrue(roll.isMultiRegion)
        XCTAssertEqual(roll.inputAreas, [first, second])
        XCTAssertEqual(roll.geometry.printableArea, NiimbotLabelArea(x: 120, y: 8, width: 160, height: 64))
        let equal = try product(areas: [first, NiimbotLabelArea(x: 25, y: 1, width: 10, height: 8)])
        XCTAssertEqual(equal.geometry.printableArea.x, 8, "Equal regions retain their source order")
    }

    func testMissingVendorAreasAreExplicitFallbackGeometryRatherThanInventedSourceAreas() throws {
        for code in ["06262015", "06172332"] {
            let roll = try XCTUnwrap(NiimbotLabelCatalog.shared.product(code: code))
            XCTAssertTrue(roll.inputAreas.isEmpty)
            XCTAssertTrue(roll.geometry.usesFallbackArea)
            XCTAssertEqual(roll.geometry.printableArea.maxY, 96)
        }
    }

    func testInvalidOrUnsupportedProductMeasurementsCannotBecomePrintGeometry() throws {
        XCTAssertThrowsError(try product(width: .nan))
        XCTAssertThrowsError(try product(width: 101))
        XCTAssertThrowsError(try product(height: 16))
        XCTAssertThrowsError(try product(rotation: 45))
        XCTAssertThrowsError(try product(flags: 4))
        XCTAssertThrowsError(try product(areas: [NiimbotLabelArea(x: 80, y: 0, width: 1, height: 1)]))
        XCTAssertThrowsError(try product(areas: [NiimbotLabelArea(x: 0, y: 0, width: 0, height: 1)]))
        XCTAssertThrowsError(try NiimbotLabelProduct(code: "not-a-code", width: 40, height: 12,
            rotation: 90, paperType: 1, inputAreas: []))
        XCTAssertThrowsError(try NiimbotLabelProduct(code: "00123456", width: 40, height: 12,
            rotation: 90, paperType: 2, inputAreas: []))
    }

    func testCatalogRejectsWrongSchemasAndMalformedTuplesInsteadOfGuessingMeasurements() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "NiimbotProducts", withExtension: "json"))
        let data = try Data(contentsOf: url)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        document["version"] = 2
        XCTAssertThrowsError(try NiimbotLabelCatalog(data: JSONSerialization.data(withJSONObject: document)))
        document["version"] = 1; document["units"] = "px"
        XCTAssertThrowsError(try NiimbotLabelCatalog(data: JSONSerialization.data(withJSONObject: document)))
        document["units"] = "mm"; document["products"] = ["00123456": [40, 12, 90, 1, 0, [[1, 2, 3]]]]
        XCTAssertThrowsError(try NiimbotLabelCatalog(data: JSONSerialization.data(withJSONObject: document)))
        document["products"] = ["00123456": [40, 12, 90, 1, 0, [], 99]]
        XCTAssertThrowsError(try NiimbotLabelCatalog(data: JSONSerialization.data(withJSONObject: document)))
        document["products"] = [:]
        XCTAssertThrowsError(try NiimbotLabelCatalog(data: JSONSerialization.data(withJSONObject: document)))
    }

    func testManualPaperEncodingStaysCompatibleWithEveryExistingSavedQueue() throws {
        for paper in InventoryLabelSize.allCases {
            let encoded = try JSONEncoder().encode(paper)
            XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"\(paper.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(InventoryLabelSize.self, from: encoded), paper)
            XCTAssertNil(paper.product); XCTAssertNil(paper.geometry)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(InventoryLabelSize.self, from: Data("\"unknown\"".utf8)))
    }

    func testDetectedPaperSnapshotRoundTripsWithoutDependingOnTheBundledCatalog() throws {
        let paper = try InventoryLabelSize(product: product(width: 37, height: 12,
            areas: [NiimbotLabelArea(x: 2, y: 1, width: 30, height: 10)]))
        let encoded = try JSONEncoder().encode(paper)
        XCTAssertEqual(try JSONDecoder().decode(InventoryLabelSize.self, from: encoded), paper)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let product = try XCTUnwrap(snapshot["product"] as? [String: Any])
        XCTAssertNil(product["geometry"], "Only source measurements are encoded; derived geometry is validated again")
        XCTAssertEqual(paper.feedDots, 296)
        XCTAssertNil(NiimbotLabelCatalog.shared.product(code: "00123456"))
        var invalidProduct = product; invalidProduct["width"] = 200
        let invalid = try JSONSerialization.data(withJSONObject: ["product": invalidProduct])
        XCTAssertThrowsError(try JSONDecoder().decode(InventoryLabelSize.self, from: invalid))
    }

    @MainActor func testDetectionNeverOverwritesTheRememberedManualSizeOrPriceSide() throws {
        let suite = "CatalogPaperTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LabelPaperPreferences(defaults: defaults)
        preferences.select(.large50x14); preferences.selectPricePosition(.left)
        let detected = try product(width: 37, height: 12)
        preferences.updateDetectedProduct(detected)
        XCTAssertEqual(preferences.size.product, detected)
        XCTAssertEqual(preferences.size.feedDots, 296)
        XCTAssertEqual(preferences.availableSizes.count, 5)
        preferences.select(.medium40x12)
        XCTAssertEqual(defaults.string(forKey: "niimbotLabelSize"), "large50x14")
        XCTAssertEqual(preferences.manualSize, .large50x14)
        XCTAssertEqual(preferences.pricePosition, .left)
        preferences.updateDetectedProduct(nil)
        XCTAssertEqual(preferences.size, .large50x14)
        XCTAssertEqual(preferences.availableSizes, InventoryLabelSize.allCases)
        let reopened = LabelPaperPreferences(defaults: defaults)
        XCTAssertEqual(reopened.size, .large50x14); XCTAssertNil(reopened.detectedProduct)
        XCTAssertEqual(reopened.pricePosition, .left)
    }
}
