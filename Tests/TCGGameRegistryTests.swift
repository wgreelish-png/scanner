import XCTest
@testable import CardShowScanner

final class TCGGameRegistryTests: XCTestCase {
    func testAllPublishedProductCategoriesHaveStableNamesAndMappings() {
        XCTAssertEqual(TCGGameRegistry.entries.count, 64)
        XCTAssertEqual(Set(TCGGameRegistry.entries.map(\.id)).count, 64)
        XCTAssertEqual(Set(TCGGameRegistry.entries.map(\.name)).count, 64)
        for entry in TCGGameRegistry.entries {
            XCTAssertTrue(TCGGameRegistry.isProductCategory(entry.id))
            XCTAssertEqual(TCGGameRegistry.categoryID(for: entry.name), entry.id)
            XCTAssertEqual(TCGGameRegistry.name(for: entry.id), entry.name)
            for alias in entry.aliases { XCTAssertEqual(TCGGameRegistry.categoryID(for: alias), entry.id) }
        }
        for id in [-1, 0, 4, 999_999] {
            XCTAssertFalse(TCGGameRegistry.isProductCategory(id))
            XCTAssertNil(TCGGameRegistry.name(for: id))
        }
    }

    func testExistingSavedGameNamesAndProviderAliasesKeepTheirCategoryIdentity() {
        for name in ["Pokémon", "Pokemon", " pokemon ", "POKÉMON", "Pokemon TCG"] {
            XCTAssertEqual(TCGGameRegistry.categoryID(for: name), 3)
            XCTAssertEqual(TCGGameRegistry.scannerKey(for: name), "tcgp:3")
        }
        for name in ["Yu-Gi-Oh!", "YuGiOh", "Yu-Gi-Oh"] {
            XCTAssertEqual(TCGGameRegistry.categoryID(for: name), 2)
        }
        for name in ["Magic: The Gathering", "Magic", "MTG"] {
            XCTAssertEqual(TCGGameRegistry.categoryID(for: name), 1)
        }
        XCTAssertEqual(TCGGameRegistry.name(for: 3), "Pokémon")
        XCTAssertEqual(TCGGameRegistry.name(for: 2), "Yu-Gi-Oh!")
        XCTAssertEqual(TCGGameRegistry.categoryID(for: "Pokémon Japan"), 85)
        XCTAssertEqual(TCGGameRegistry.name(for: 85), "Pokemon Japan")
        XCTAssertEqual(TCGGameRegistry.defaultLanguage(for: "Pokemon Japan"), "Japanese")
        XCTAssertEqual(TCGGameRegistry.defaultLanguage(for: "Pokémon Japan"), "Japanese")
        XCTAssertEqual(TCGGameRegistry.defaultLanguage(for: "Pokémon"), "English")
        XCTAssertEqual(TCGGameRegistry.scannerKey(for: "One Piece Card Game"), "tcgp:68")
        XCTAssertEqual(TCGGameRegistry.scannerKey(for: "Disney Lorcana"), "tcgp:71")
        XCTAssertEqual(TCGGameRegistry.scannerKey(for: "Riftbound"), "tcgp:89")
        XCTAssertNil(TCGGameRegistry.categoryID(for: "An unknown game"))
    }

    func testAccessoriesRemainProductCategoriesButCanNeverBecomeScannerChoices() {
        let accessories: Set<Int> = [31, 32, 35, 49, 50, 56]
        XCTAssertEqual(TCGGameRegistry.gameKeys.count, 58)
        for entry in TCGGameRegistry.entries {
            let key = "tcgp:\(entry.id)"
            if accessories.contains(entry.id) {
                XCTAssertTrue(TCGGameRegistry.isProductCategory(entry.id))
                XCTAssertFalse(TCGGameRegistry.isScannerKey(key))
                XCTAssertNil(TCGGameRegistry.scannerKey(for: entry.name))
                XCTAssertNil(TCGGameRegistry.gameKeys[entry.name])
            } else {
                XCTAssertTrue(TCGGameRegistry.isScannerKey(key))
                XCTAssertEqual(TCGGameRegistry.scannerKey(for: entry.name), key)
                XCTAssertEqual(TCGGameRegistry.gameKeys[entry.name], key)
            }
        }
    }

    func testScannerKeysRequireTheExactKnownCanonicalNumericForm() {
        for value in ["tcgp:0", "tcgp:003", "tcgp:+3", "tcgp:-3", "tcgp:999", "TCGP:3",
                      "tcgp:3/", " tcgp:3", "tcgp:3 ", "tcgp:3\n", "tcgp:٣", "tcgp:", "3"] {
            XCTAssertFalse(TCGGameRegistry.isScannerKey(value), value)
        }
        XCTAssertEqual(TCGGameRegistry.scannerNames(forKeys: ["tcgp:71", "tcgp:2", "tcgp:1", "tcgp:3", "tcgp:3"]),
                       ["Pokémon", "Magic: The Gathering", "Yu-Gi-Oh!", "Disney Lorcana"])
    }
}
