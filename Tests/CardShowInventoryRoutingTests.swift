import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class CardShowInventoryRoutingTests: XCTestCase {
    private func setup() throws -> (ModelContainer, CardList, ScanSession) {
        let container = try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", skuID: "100", printing: "Normal"),
            name: "Source card", set: "Fixture set", number: "42", marketPrice: 10, confidence: 0, printings: ["Normal"])
        let source = try CardShowInventoryService.apply(.init(location: .init(id: 9001, name: "Card Show"),
            rows: [.init(inventoryID: 7001, card: card, quantity: 3)], fetchedAt: .now), context: context)
        let local = CardList(name: "Current scan"); context.insert(local)
        let active = ScanSession(listName: local.name)
        active.listID = local.id; active.game = "Pokémon"; active.statusRaw = "active"
        context.insert(active); try context.save()
        return (container, source, active)
    }

    func testContinuingImportedListCannotFinishAnotherActiveScan() throws {
        let (container, source, active) = try setup()
        XCTAssertThrowsError(try SessionService.continueList(source, game: "Pokémon",
            context: container.mainContext, finishingOtherSession: true)) {
            XCTAssertEqual($0 as? CardShowInventoryFailure, .readOnlyList)
        }
        XCTAssertTrue(active.isActive); XCTAssertNil(active.completedAt)
        XCTAssertEqual(source.quantity, 3)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<ScanSession>()).count, 1)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testLegacySessionRouteCannotResumeOrAppendToImportedInventory() throws {
        let (container, source, active) = try setup()
        let context = container.mainContext
        let old = ScanSession(listName: source.name)
        old.listID = source.id; old.game = "Pokémon"; old.statusRaw = "completed"
        old.savedOffersData = Data("[]".utf8); context.insert(old); try context.save()
        XCTAssertThrowsError(try SessionService.resume(old, context: context, finishingOtherSession: true)) {
            XCTAssertEqual($0 as? CardShowInventoryFailure, .readOnlyList)
        }
        XCTAssertTrue(active.isActive); XCTAssertEqual(old.statusRaw, "completed")
        XCTAssertThrowsError(try SessionService.add(source.cards[0].snapshot, session: old, list: source, context: context)) {
            XCTAssertEqual($0 as? CardShowInventoryFailure, .readOnlyList)
        }
        XCTAssertEqual(old.savedOffersData, Data("[]".utf8)); XCTAssertEqual(source.quantity, 3)
        XCTAssertFalse(context.hasChanges)
    }
}
