import XCTest
@testable import CardShowScanner

final class ShowInventorySortTests: XCTestCase {
    private func item(_ index: Int, name: String = "Same card", set: String = "Set A", number: String = "1",
                      price: Decimal? = 10, quantity: Int = 1, date: TimeInterval = 100,
                      game: String = "Pokémon") -> ShowInventoryItem {
        let card = CardCandidate(identity: .init(game: game, productID: "p:42", printing: "Normal"),
            name: name, set: set, number: number, marketPrice: price, confidence: 100, printings: ["Normal"])
        return ShowInventoryItem(id: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index))!,
            card: card, quantity: quantity, acquiredAt: Date(timeIntervalSince1970: date))
    }

    func testMarketSortUsesPerCardDecimalPriceAndKeepsUnknownLastInBothDirections() {
        let missing = item(1, price: nil), zero = item(2, price: 0, quantity: 100)
        let high = item(3, price: Decimal(string: "10.000002"))
        let low = item(4, price: Decimal(string: "10.000001"), quantity: 50)
        let source = [missing, high, zero, low]
        XCTAssertEqual(ShowInventorySort.marketAscending.sorted(source).map(\.id), [zero, low, high, missing].map(\.id))
        XCTAssertEqual(ShowInventorySort.marketDescending.sorted(source).map(\.id), [high, low, zero, missing].map(\.id))
        XCTAssertEqual(source, [missing, high, zero, low])
    }

    func testNamesAndSetNumbersUseNaturalOrder() {
        let first = item(1, name: "Card 2", number: "10")
        let second = item(2, name: "Card 10", number: "2")
        let otherSet = item(3, name: "Card 1", set: "Set B")
        let source = [second, otherSet, first]
        XCTAssertEqual(ShowInventorySort.nameAscending.sorted(source).map(\.id), [otherSet, first, second].map(\.id))
        XCTAssertEqual(ShowInventorySort.nameDescending.sorted(source).map(\.id), [second, first, otherSet].map(\.id))
        XCTAssertEqual(ShowInventorySort.setAndNumber.sorted(source).map(\.id), [second, first, otherSet].map(\.id))
    }

    func testQuantityAndAcquisitionDateOrders() {
        let first = item(1, quantity: 2, date: 10)
        let second = item(2, quantity: 1, date: 30)
        let third = item(3, quantity: 4, date: 20)
        let source = [first, second, third]
        XCTAssertEqual(ShowInventorySort.quantityDescending.sorted(source).map(\.id), [third, first, second].map(\.id))
        XCTAssertEqual(ShowInventorySort.newestFirst.sorted(source).map(\.id), [second, third, first].map(\.id))
        XCTAssertEqual(ShowInventorySort.oldestFirst.sorted(source).map(\.id), [first, third, second].map(\.id))
    }

    func testEqualCardsRemainSeparateWithDeterministicIdentityTiesWithoutChangingSource() {
        let first = item(1), second = item(2)
        let source = [second, first]
        for sort in ShowInventorySort.allCases {
            let result = sort.sorted(source)
            XCTAssertEqual(result.map(\.id), [first.id, second.id])
            XCTAssertEqual(result.map(\.quantity), [1, 1])
        }
        XCTAssertEqual(source, [second, first])
    }

    func testUnsupportedSavedPreferenceFallsBackToTheExistingNameOrder() {
        XCTAssertEqual(ShowInventorySort(preference: "unknown-future-option"), .nameAscending)
        XCTAssertEqual(ShowInventorySort(preference: ShowInventorySort.marketDescending.rawValue), .marketDescending)
    }

    func testGameFilterCanonicalizesRegistryAliasesWithoutCombiningJapaneseOrCustomGames() {
        let pokemon = item(1, game: "Pokemon TCG"), japanese = item(2, game: "Pokémon Japan")
        let yugioh = item(3, game: "YuGiOh"), magic = item(4, game: "MTG")
        XCTAssertEqual(InventoryGameFilter.canonicalGame("  Poke\u{301}mon  "), "Pokémon")
        XCTAssertEqual(InventoryGameFilter.canonicalGame("yu-gi-oh"), "Yu-Gi-Oh!")
        XCTAssertEqual(InventoryGameFilter.canonicalGame("Magic"), "Magic: The Gathering")
        XCTAssertEqual(InventoryGameFilter.canonicalGame("  Local TCG  "), "Local TCG")
        XCTAssertEqual(InventoryGameFilter.canonicalGame(" \n "), "Unknown Game")
        XCTAssertTrue(InventoryGameFilter.matches(pokemon, game: "POKEMON"))
        XCTAssertFalse(InventoryGameFilter.matches(japanese, game: "Pokémon"))
        XCTAssertTrue(InventoryGameFilter.matches(japanese, game: "Pokemon Japan"))
        XCTAssertTrue(InventoryGameFilter.matches(yugioh, game: "Yu-Gi-Oh!"))
        XCTAssertTrue(InventoryGameFilter.matches(magic, game: "Magic: The Gathering"))
        XCTAssertTrue(InventoryGameFilter.matches(item(5, game: "local tcg"), game: "Local TCG"))
        XCTAssertTrue(InventoryGameFilter.matches(item(6, game: ""), game: "Unknown Game"))
        XCTAssertEqual(InventoryGameFilter.title(for: ""), "All Games")
    }

    func testGameFilteringPreservesOrderZeroStockAndEveryInventorySnapshotUntilTheCallerSelectsAvailableStock() {
        var imported = item(1, price: nil, quantity: 3, game: "Pokemon")
        imported.sourceInventoryID = 47; imported.sourceLocationID = 8; imported.remainingCostCents = 777
        var local = item(2, quantity: 2, game: "Pokémon")
        local.acquiredByTransactionID = UUID()
        let soldOut = item(3, quantity: 0, game: "Pokemon TCG")
        let other = item(4, quantity: 9, game: "Yu-Gi-Oh!")
        let source = [other, soldOut, imported, local], original = source
        let filtered = InventoryGameFilter.filtered(source, game: "Pokémon")
        XCTAssertEqual(filtered, [soldOut, imported, local])
        XCTAssertEqual(filtered.filter { $0.quantity > 0 }, [imported, local])
        XCTAssertEqual(InventoryGameFilter.filtered(source, game: " \t"), original)
        XCTAssertEqual(source, original)
        XCTAssertEqual(filtered[1].originTitle, "TCGTracking")
        XCTAssertEqual(filtered[2].originTitle, "Acquired locally")
    }

    func testGameOptionsUseOnlyPositiveStockDeduplicateAliasesAndKeepAnAbsentSelection() {
        let source = [item(1, game: "Pokemon"), item(2, game: "Pokémon"),
                      item(3, game: "YuGiOh"), item(4, game: "Pokémon Japan"),
                      item(5, quantity: 0, game: "Magic"), item(6, game: ""), item(7, game: "Local TCG")]
        let games = InventoryGameFilter.games(in: source)
        XCTAssertEqual(Set(games), Set(["Pokémon", "Yu-Gi-Oh!", "Pokemon Japan", "Unknown Game", "Local TCG"]))
        XCTAssertEqual(games.count, 5)
        XCTAssertFalse(games.contains(""), "All Games is the explicit empty selection rather than a stock category")
        XCTAssertEqual(games, games.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(InventoryGameFilter.games(in: source, including: ""), games)
        let retained = InventoryGameFilter.games(in: source, including: "Lorcana")
        XCTAssertEqual(Set(retained), Set(games + ["Disney Lorcana"]))
        let customSelection = InventoryGameFilter.games(in: source, including: "local tcg")
        XCTAssertTrue(customSelection.contains("local tcg"))
        XCTAssertFalse(customSelection.contains("Local TCG"), "A custom picker option must retain the exact saved selection spelling")
        XCTAssertEqual(customSelection.count, games.count)
        XCTAssertEqual(InventoryGameFilter.games(in: [], including: "MTG"), ["Magic: The Gathering"])
        XCTAssertTrue(InventoryGameFilter.games(in: [], including: "").isEmpty)
    }

    @MainActor func testGamePreferencePersistsOnlyItsSelectionAndPreservesPaperPriceOrderAndInventorySettings() throws {
        let suite = "InventoryGamePreferencesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "isolated.inventoryGameFilter"
        defaults.set("large50x14", forKey: "niimbotLabelSize")
        defaults.set("left", forKey: "niimbotLabelPricePosition")
        defaults.set("priceDescending", forKey: "labelPrintOrder")
        defaults.set(Data([1, 2, 3]), forKey: "inventory.fixture")
        let preferences = InventoryGamePreferences(defaults: defaults, key: key)
        XCTAssertEqual(preferences.selectedGame, "")
        XCTAssertNil(defaults.object(forKey: key))
        preferences.selectedGame = "  Pokemon TCG  "
        XCTAssertEqual(preferences.selectedGame, "Pokémon")
        XCTAssertEqual(InventoryGamePreferences(defaults: defaults, key: key).selectedGame, "Pokémon")
        preferences.selectedGame = "  Local TCG  "
        XCTAssertEqual(InventoryGamePreferences(defaults: defaults, key: key).selectedGame, "Local TCG")
        preferences.selectedGame = ""
        XCTAssertEqual(InventoryGamePreferences(defaults: defaults, key: key).selectedGame, "")
        XCTAssertEqual(defaults.string(forKey: "niimbotLabelSize"), "large50x14")
        XCTAssertEqual(defaults.string(forKey: "niimbotLabelPricePosition"), "left")
        XCTAssertEqual(defaults.string(forKey: "labelPrintOrder"), "priceDescending")
        XCTAssertEqual(defaults.data(forKey: "inventory.fixture"), Data([1, 2, 3]))
        XCTAssertNil(defaults.object(forKey: "inventoryGameFilter"), "Injected test preferences never write the app's normal selection")
    }
}
