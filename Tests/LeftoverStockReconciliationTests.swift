import XCTest
@testable import CardShowScanner

final class LeftoverStockReconciliationTests: XCTestCase {
    private func card(_ product: String = "p:42", sku: String? = "4200", game: String = "Pokémon",
                      printing: String = "Holofoil", language: String = "English", condition: String = "Near Mint") -> CardCandidate {
        CardCandidate(identity: .init(game: game, productID: product, skuID: sku, printing: printing,
            language: language, condition: condition), name: "Fixture card", set: "Fixture set", number: "042",
            marketPrice: 12, confidence: 100, printings: [printing])
    }

    private func baseline(_ rows: [(CardCandidate, Int)]) -> LeftoverStockBaseline {
        .init(location: .init(id: 259401, name: "Card Show"), fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
              rows: rows.enumerated().map { .init(inventoryID: $0.offset + 1, card: $0.element.0, quantity: $0.element.1) })
    }

    private func count(_ card: CardCandidate, quantity: Int = 1, id: UUID = UUID()) -> LeftoverStockCountRow {
        .init(id: id, card: card, quantity: quantity)
    }

    func testFrozenSnapshotRoundTripAndPhysicalDuplicatesAggregateWithoutEditingInput() throws {
        let first = card(), second = card("p:43", sku: "4300")
        let snapshot = CardShowInventorySnapshot(location: .init(id: 259401, name: "Card Show"),
            rows: [.init(inventoryID: 11, card: first, quantity: 3), .init(inventoryID: 12, card: first, quantity: 2),
                   .init(inventoryID: 13, card: second, quantity: 4)], fetchedAt: .now)
        let source = LeftoverStockBaseline(snapshot: snapshot)
        let restored = try JSONDecoder().decode(LeftoverStockBaseline.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(source, restored)
        let counts = [count(first), count(first, quantity: 2)]
        let result = LeftoverStockReconciliation.compare(baseline: restored, counts: counts)
        XCTAssertTrue(result.canExport); XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.baselineQuantity, 9); XCTAssertEqual(result.countedQuantity, 3)
        XCTAssertEqual(result.notCountedQuantity, 6); XCTAssertEqual(result.unchangedQuantity, 3)
        XCTAssertEqual(result.rows[0].baselineQuantity, 5); XCTAssertEqual(result.rows[0].countedQuantity, 3)
        XCTAssertEqual(result.rows[0].countRowIDs, counts.map(\.id))
        XCTAssertEqual(result.rows[1].status, .notCounted); XCTAssertEqual(result.rows[1].countedQuantity, 0)
        XCTAssertEqual(snapshot.rows.map(\.quantity), [3, 2, 4]); XCTAssertEqual(counts.map(\.quantity), [1, 2])
    }

    func testExactIdentityIncludesGameConditionLanguageAndPrinting() {
        let source = baseline([(card(), 2), (card(sku: "4201", condition: "Lightly Played"), 3),
                               (card(sku: "4202", language: "Japanese"), 4),
                               (card(sku: "4203", printing: "Reverse Holofoil"), 5),
                               (card(sku: "4204", game: "Magic: The Gathering"), 6)])
        let result = LeftoverStockReconciliation.compare(baseline: source,
            counts: [count(card()), count(card(sku: "4201", condition: "Lightly Played"))])
        XCTAssertTrue(result.canExport); XCTAssertEqual(result.rows.count, 5)
        XCTAssertEqual(result.rows.map(\.countedQuantity), [1, 1, 0, 0, 0])
        XCTAssertEqual(result.notCountedQuantity, 18)
    }

    func testNilSKUResolvesOnlyUniqueNormalizedCompleteSourceIdentity() {
        let source = baseline([(card(sku: "0004200"), 4)])
        let scanned = card(sku: nil, game: "Pokemon", printing: "  HOLOFOIL ", language: " english ", condition: "near   mint")
        let result = LeftoverStockReconciliation.compare(baseline: source, counts: [count(scanned)])
        XCTAssertTrue(result.canExport); XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows.first?.skuID, "0004200"); XCTAssertEqual(result.rows.first?.countedQuantity, 1)
    }

    func testSameNameNeverResolvesWrongProductOrUnverifiedNewCard() {
        let result = LeftoverStockReconciliation.compare(baseline: baseline([(card(), 4)]),
            counts: [count(card("p:other", sku: nil))])
        XCTAssertFalse(result.canExport)
        XCTAssertTrue(result.issues.contains { $0.kind == .unresolvedCard })
        XCTAssertEqual(result.rows.first?.countedQuantity, 0)
    }

    func testConflictingSKUAndMultipleSKUsForOneIdentityBlockExport() {
        let conflicting = LeftoverStockReconciliation.compare(baseline: baseline([(card(), 2)]),
            counts: [count(card(condition: "Lightly Played"))])
        XCTAssertTrue(conflicting.issues.contains { $0.kind == .conflictingSKU })
        let ambiguous = LeftoverStockReconciliation.compare(baseline: baseline([(card(), 2), (card(sku: "4201"), 3)]),
            counts: [count(card(sku: nil))])
        XCTAssertTrue(ambiguous.issues.contains { $0.kind == .ambiguousIdentity })
        XCTAssertThrowsError(try LeftoverStockReconciliation.replacementCSV(comparison: ambiguous, countComplete: true))
        let newAmbiguity = LeftoverStockReconciliation.compare(baseline: baseline([]),
            counts: [count(card(sku: "4200")), count(card(sku: "4201"))])
        XCTAssertTrue(newAmbiguity.issues.contains { $0.kind == .ambiguousIdentity })
    }

    func testValidNewSKUCountsAsExtraAndSourceZeroGroupsRemainInComparison() {
        let result = LeftoverStockReconciliation.compare(baseline: baseline([(card(), 0)]),
            counts: [count(card("p:43", sku: "4300"), quantity: 3)])
        XCTAssertTrue(result.canExport); XCTAssertEqual(result.extraQuantity, 3)
        XCTAssertEqual(result.rows.map(\.baselineQuantity), [0, 0])
        XCTAssertEqual(result.rows.map(\.status), [.unchanged, .extra])
    }

    func testDuplicatePhysicalRowsInvalidSKUAndQuantityBoundsFailClosed() {
        let row = count(card())
        let duplicate = LeftoverStockReconciliation.compare(baseline: baseline([(card(), 2)]), counts: [row, row])
        XCTAssertTrue(duplicate.issues.contains { $0.kind == .duplicateRow })
        XCTAssertEqual(duplicate.countedQuantity, 1)
        for sku in ["0", "000", "1e3", "+42", " 42", "123456789012345678901"] {
            let result = LeftoverStockReconciliation.compare(baseline: baseline([]), counts: [count(card(sku: sku))])
            XCTAssertTrue(result.issues.contains { $0.kind == .invalidSKU }, sku)
        }
        let overflow = LeftoverStockReconciliation.compare(baseline: baseline([(card(), 1_000_000), (card(), 1)]),
            counts: [count(card(), quantity: 1_000_000), count(card()), count(card(), quantity: Int.max)])
        XCTAssertTrue(overflow.issues.contains { $0.kind == .invalidQuantity })
        XCTAssertFalse(overflow.canExport)
    }

    func testReplacementCSVUsesVerifiedHeadersPositiveCountsAndHumanEscapingOnly() throws {
        var value = card(sku: "0004200")
        value.name = "=Fixture, \"quoted\""; value.set = "  +Fixture set"
        let result = LeftoverStockReconciliation.compare(baseline: baseline([(value, 3), (card("p:43", sku: "4300"), 2)]),
            counts: [count(value, quantity: 2)])
        let csv = try LeftoverStockReconciliation.replacementCSV(comparison: result, countComplete: true)
        XCTAssertTrue(csv.hasPrefix("tcgplayer_sku,name,set_name,collector_number,condition,foil,language,quantity,location\r\n"))
        XCTAssertTrue(csv.contains("\"0004200\"")); XCTAssertTrue(csv.contains("\"'=Fixture, \"\"quoted\"\"\""))
        XCTAssertTrue(csv.contains("\"'  +Fixture set\"")); XCTAssertTrue(csv.contains("\"Holofoil\""))
        XCTAssertFalse(csv.contains("4300")); XCTAssertFalse(csv.contains("Market")); XCTAssertFalse(csv.contains("p:42"))
        XCTAssertEqual(csv.components(separatedBy: "\r\n").count, 3)
        let report = LeftoverStockReconciliation.comparisonCSV(comparison: result)
        XCTAssertTrue(report.contains("\"-1\"")); XCTAssertFalse(report.contains("\"'-1\""))
        XCTAssertTrue(report.contains("\"4300\"")); XCTAssertTrue(report.contains("\"Not counted\""))
    }

    func testAllZeroReplacementRequiresExplicitCompletionAndProducesHeaderOnly() throws {
        let result = LeftoverStockReconciliation.compare(baseline: baseline([(card(), 5)]), counts: [])
        XCTAssertEqual(result.rows.first?.countedQuantity, 0); XCTAssertEqual(result.notCountedQuantity, 5)
        XCTAssertThrowsError(try LeftoverStockReconciliation.replacementCSV(comparison: result, countComplete: false))
        let csv = try LeftoverStockReconciliation.replacementCSV(comparison: result, countComplete: true)
        XCTAssertEqual(csv, "tcgplayer_sku,name,set_name,collector_number,condition,foil,language,quantity,location\r\n")
    }

    func testCompletionFingerprintSurvivesOrderAndPriceChangesButTracksExportedIdentityAndQuantity() {
        let a = count(card()), b = count(card("p:43", sku: "4300"))
        let original = LeftoverStockReconciliation.countFingerprint([a, b])
        XCTAssertEqual(original, LeftoverStockReconciliation.countFingerprint([b, a]))
        var repriced = a.card; repriced.marketPrice = nil
        XCTAssertEqual(original, LeftoverStockReconciliation.countFingerprint([count(repriced, id: a.id), b]))
        XCTAssertNotEqual(original, LeftoverStockReconciliation.countFingerprint([count(a.card, quantity: 2, id: a.id), b]))
        var corrected = a.card; corrected.identity.condition = "Lightly Played"
        XCTAssertNotEqual(original, LeftoverStockReconciliation.countFingerprint([count(corrected, id: a.id), b]))
        corrected = a.card; corrected.name = "Corrected display name"
        XCTAssertNotEqual(original, LeftoverStockReconciliation.countFingerprint([count(corrected, id: a.id), b]))
    }
}
