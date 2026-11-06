import XCTest
@testable import CardShowScanner

@MainActor final class CustomPriceTagTests: XCTestCase {
    private func raster(_ draft: CustomPriceTagDraft) -> LabelRaster {
        LabelRaster(width: draft.paperSize.headDots, height: draft.paperSize.feedDots,
            data: Data(repeating: 0x80, count: 12 * draft.paperSize.feedDots))
    }

    private func inventoryDraft() -> InventoryLabelDraft {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Normal"),
            name: "Layout fixture", set: "Set", number: "42", marketPrice: 5, confidence: 100, printings: ["Normal"])
        return InventoryLabelDraft(item: ShowInventoryItem(card: card, quantity: 3, remainingCostCents: 700))
    }

    func testPricePositionPreferencePersistsBothChoicesAcrossReopenWithoutChangingPaperOrMedia() throws {
        let suite = "LabelPricePositionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LabelPaperPreferences(defaults: defaults)
        XCTAssertEqual(preferences.pricePosition, .right)
        XCTAssertNil(defaults.object(forKey: "niimbotLabelPricePosition"), "Opening an existing app retains its original layout without writing a new choice")
        defaults.set("transparent", forKey: "niimbotPaperMode")
        preferences.select(.small30x15)
        XCTAssertEqual(LabelPricePosition.left.title, "Price Left")
        XCTAssertEqual(LabelPricePosition.right.title, "Price Right")
        for position in LabelPricePosition.allCases {
            preferences.selectPricePosition(position)
            XCTAssertEqual(preferences.pricePosition, position)
            XCTAssertEqual(defaults.string(forKey: "niimbotLabelPricePosition"), position.rawValue)
            let reopened = LabelPaperPreferences(defaults: defaults)
            XCTAssertEqual(reopened.pricePosition, position, "The next print screen and a reopened app must retain the selected side")
            XCTAssertEqual(reopened.size, .small30x15)
            XCTAssertEqual(defaults.string(forKey: "niimbotPaperMode"), "transparent")
        }
    }

    func testUnknownPricePositionPreferenceUsesRightWithoutRewritingUntilExplicitSelection() throws {
        let suite = "UnknownLabelPricePositionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for raw in ["unsupported-position", "", "LEFT"] {
            defaults.set(raw, forKey: "niimbotLabelPricePosition")
            let preferences = LabelPaperPreferences(defaults: defaults)
            XCTAssertEqual(preferences.pricePosition, .right)
            XCTAssertEqual(defaults.string(forKey: "niimbotLabelPricePosition"), raw)
            XCTAssertEqual(LabelPaperPreferences(defaults: defaults).pricePosition, .right)
            preferences.selectPricePosition(.left)
            XCTAssertEqual(LabelPaperPreferences(defaults: defaults).pricePosition, .left)
            XCTAssertEqual(defaults.string(forKey: "niimbotLabelPricePosition"), "left")
        }
    }

    func testInjectedPricePositionPreferencesStayIsolatedFromAnotherSuite() throws {
        let firstSuite = "FirstLabelPositionTests." + UUID().uuidString
        let secondSuite = "SecondLabelPositionTests." + UUID().uuidString
        let first = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let second = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer {
            first.removePersistentDomain(forName: firstSuite)
            second.removePersistentDomain(forName: secondSuite)
        }
        let firstPreferences = LabelPaperPreferences(defaults: first)
        firstPreferences.selectPricePosition(.left)
        XCTAssertEqual(LabelPaperPreferences(defaults: first).pricePosition, .left)
        XCTAssertEqual(LabelPaperPreferences(defaults: second).pricePosition, .right)
        XCTAssertNil(second.object(forKey: "niimbotLabelPricePosition"))
    }

    func testInventoryDraftCodablePreservesEachPositionAndDefaultsOnlyTheMissingLegacyField() throws {
        var draft = inventoryDraft()
        draft.askingPriceText = "17"
        draft.copies = 3
        draft.style = .cardDetails
        draft.paperSize = .large50x14
        draft.isManualOverride = true
        for position in LabelPricePosition.allCases {
            draft.pricePosition = position
            let data = try JSONEncoder().encode(draft)
            XCTAssertEqual(try JSONDecoder().decode(InventoryLabelDraft.self, from: data), draft)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        object.removeValue(forKey: "pricePosition")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        var expected = draft
        expected.pricePosition = .right
        XCTAssertEqual(try JSONDecoder().decode(InventoryLabelDraft.self, from: legacyData), expected,
                       "Every legacy price, quantity, category, cost and metadata field must remain exact")

        for key in ["copies", "style", "paperSize", "isBulk", "isManualOverride"] {
            var missingRequired = object
            missingRequired.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(InventoryLabelDraft.self,
                from: JSONSerialization.data(withJSONObject: missingRequired)), "Existing required field: " + key)
        }
        let invalidPositions: [Any] = ["upside-down", NSNull(), 123]
        for invalid in invalidPositions {
            var malformed = object
            malformed["pricePosition"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(InventoryLabelDraft.self,
                from: JSONSerialization.data(withJSONObject: malformed)))
        }
        var withoutMarket = object
        withoutMarket.removeValue(forKey: "marketValue")
        expected.marketValue = nil
        XCTAssertEqual(try JSONDecoder().decode(InventoryLabelDraft.self,
            from: JSONSerialization.data(withJSONObject: withoutMarket)), expected,
                       "The existing optional market field stays optional")
    }

    func testChangingPricePositionInvalidatesPreparedCustomOrBulkDraftWithoutChangingQueuedArtifacts() throws {
        for isBulk in [false, true] {
            var bytes: Data?
            var writes = 0
            var rendered: [CustomPriceTagDraft] = []
            let queue = LabelPrintQueue(read: { _ in bytes }, write: { data, _ in bytes = data; writes += 1 })
            let model = CustomPriceTagModel(queue: queue, pricePosition: .right, render: { draft in
                rendered.append(draft)
                return LabelRaster(width: draft.paperSize.headDots, height: draft.paperSize.feedDots,
                    data: Data(repeating: draft.pricePosition == .left ? 0x40 : 0x80, count: 12 * draft.paperSize.feedDots))
            })
            model.isBulk = isBulk
            model.price = isBulk ? "" : "5"
            model.copies = "2"
            XCTAssertEqual(model.draft?.pricePosition, .right)
            XCTAssertTrue(model.prepare())
            let queued = queue.entries, savedBytes = bytes
            XCTAssertTrue(model.hasPreparedQueue)
            model.pricePosition = .left
            XCTAssertEqual(model.draft?.pricePosition, .left)
            XCTAssertFalse(model.hasPreparedQueue)
            XCTAssertFalse(model.prepare(), "Changing the next label cannot replace an existing saved queue")
            XCTAssertEqual(queue.entries, queued)
            XCTAssertEqual(bytes, savedBytes)
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(rendered.count, 1)
            model.pricePosition = .right
            XCTAssertTrue(model.hasPreparedQueue)
            XCTAssertTrue(model.prepare())
            XCTAssertEqual(writes, 1)

            model.pricePosition = .left
            try queue.clear()
            XCTAssertTrue(model.prepare())
            XCTAssertEqual(rendered.map(\.pricePosition), [.right, .left])
            XCTAssertTrue(queue.entries.allSatisfy { $0.raster.data.first == 0x40 && $0.priceCents == (isBulk ? 0 : 500) })
            XCTAssertTrue(queued.allSatisfy { $0.raster.data.first == 0x80 })
            XCTAssertFalse(queue.isPrinting)
        }
    }

    func testManualDraftAcceptsZeroAndWholeDollarsWithoutInventoryOrMarket() throws {
        for price in [Int64(0), 100, 500, 11_000] {
            let draft = CustomPriceTagDraft(priceCents: price, copies: 3, paperSize: .small30x14)
            XCTAssertNoThrow(try draft.validate())
            XCTAssertEqual(draft.priceText, price == 0 ? "" : StickerPrice.individual(price).displayText)
            XCTAssertEqual(draft.isBlankPrice, price == 0)
        }
        for price in [Int64(-100), 50, 599] {
            XCTAssertThrowsError(try CustomPriceTagDraft(priceCents: price, copies: 1, paperSize: .small30x14).validate())
        }
        for copies in [0, 101] {
            XCTAssertThrowsError(try CustomPriceTagDraft(priceCents: 500, copies: copies, paperSize: .small30x14).validate())
        }
    }

    func testExplicitCustomZeroPreparesWriteInLabelsWhileEmptyInputAndDealRemainDistinct() throws {
        var bytes: Data?
        let queue = LabelPrintQueue(read: { _ in bytes }, write: { data, _ in bytes = data })
        let model = CustomPriceTagModel(queue: queue, render: raster)
        XCTAssertNil(model.draft, "Opening an empty custom form does not silently select a write-in label")
        model.price = "0"
        let blank = try XCTUnwrap(model.draft)
        XCTAssertTrue(blank.isBlankPrice)
        XCTAssertEqual(blank.priceText, "")
        XCTAssertEqual(blank.priceDescription, "Blank price · write in")
        XCTAssertTrue(model.prepare())
        let entry = try XCTUnwrap(queue.entries.first)
        XCTAssertEqual(entry.blankPrice, true)
        XCTAssertNil(entry.stickerTag)
        XCTAssertNil(entry.pricingRevisionID)
        XCTAssertEqual(entry.priceText, "Blank price · write in")
        XCTAssertFalse(queue.isPrinting)

        try queue.clear()
        model.isBulk = true
        XCTAssertFalse(try XCTUnwrap(model.draft).isBlankPrice)
        XCTAssertEqual(model.draft?.priceText, StickerPrice.twoForOne.displayText)
        XCTAssertTrue(model.prepare())
        XCTAssertEqual(queue.entries.first?.stickerTag, .twoForOne)
        XCTAssertNotEqual(queue.entries.first?.blankPrice, true)
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
