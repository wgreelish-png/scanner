import Foundation

struct TCGGameDefinition: Equatable, Identifiable, Sendable {
    let id: Int
    let name: String
    let aliases: [String]

    init(id: Int, name: String, aliases: [String] = []) {
        self.id = id; self.name = name; self.aliases = aliases
    }
}

/// Product categories and stable names are separate from the set of recognition
/// packs currently published by NSP. Existing saved game names stay canonical.
enum TCGGameRegistry {
    static let entries: [TCGGameDefinition] = [
        .init(id: 1, name: "Magic: The Gathering", aliases: ["Magic","MTG"]),
        .init(id: 2, name: "Yu-Gi-Oh!", aliases: ["YuGiOh","Yu-Gi-Oh","Yu-Gi-Oh! Trading Card Game"]),
        .init(id: 3, name: "Pokémon", aliases: ["Pokemon","Pokemon TCG","Pokémon TCG"]),
        .init(id: 7, name: "Epic"),
        .init(id: 13, name: "WoW"),
        .init(id: 16, name: "Cardfight Vanguard"),
        .init(id: 17, name: "Force of Will"),
        .init(id: 18, name: "Dice Masters"),
        .init(id: 19, name: "Future Card BuddyFight"),
        .init(id: 20, name: "Weiss Schwarz"),
        .init(id: 23, name: "Dragon Ball Z TCG"),
        .init(id: 24, name: "Final Fantasy TCG"),
        .init(id: 25, name: "UniVersus"),
        .init(id: 26, name: "Star Wars: Destiny"),
        .init(id: 27, name: "Dragon Ball Super: Masters"),
        .init(id: 28, name: "Dragoborne"),
        .init(id: 30, name: "MetaX TCG"),
        .init(id: 31, name: "Card Sleeves"),
        .init(id: 32, name: "Deck Boxes"),
        .init(id: 35, name: "Playmats"),
        .init(id: 36, name: "Zombie World Order TCG"),
        .init(id: 37, name: "The Caster Chronicles"),
        .init(id: 38, name: "My Little Pony CCG"),
        .init(id: 47, name: "Exodus TCG"),
        .init(id: 48, name: "Lightseekers TCG"),
        .init(id: 49, name: "Protective Pages"),
        .init(id: 50, name: "Storage Albums"),
        .init(id: 53, name: "Munchkin CCG"),
        .init(id: 54, name: "Warhammer Age of Sigmar Champions TCG"),
        .init(id: 55, name: "Architect TCG"),
        .init(id: 56, name: "Bulk Lots"),
        .init(id: 57, name: "Transformers TCG"),
        .init(id: 58, name: "Bakugan TCG"),
        .init(id: 59, name: "KeyForge"),
        .init(id: 60, name: "Chrono Clash System"),
        .init(id: 61, name: "Argent Saga TCG"),
        .init(id: 62, name: "Flesh and Blood TCG"),
        .init(id: 63, name: "Digimon Card Game"),
        .init(id: 64, name: "Alternate Souls"),
        .init(id: 65, name: "Gate Ruler"),
        .init(id: 66, name: "MetaZoo"),
        .init(id: 67, name: "WIXOSS"),
        .init(id: 68, name: "One Piece Card Game", aliases: ["One Piece"]),
        .init(id: 71, name: "Disney Lorcana", aliases: ["Lorcana"]),
        .init(id: 72, name: "Battle Spirits Saga"),
        .init(id: 73, name: "Shadowverse: Evolve"),
        .init(id: 74, name: "Grand Archive TCG"),
        .init(id: 75, name: "Akora TCG"),
        .init(id: 76, name: "Kryptik TCG"),
        .init(id: 77, name: "Sorcery: Contested Realm"),
        .init(id: 78, name: "Alpha Clash"),
        .init(id: 79, name: "Star Wars: Unlimited"),
        .init(id: 80, name: "Dragon Ball Super: Fusion World"),
        .init(id: 81, name: "Union Arena"),
        .init(id: 83, name: "Elestrals"),
        .init(id: 84, name: "Neopets Battledome"),
        .init(id: 85, name: "Pokemon Japan", aliases: ["Pokémon Japan"]),
        .init(id: 86, name: "Gundam Card Game", aliases: ["Gundam"]),
        .init(id: 87, name: "hololive OFFICIAL CARD GAME"),
        .init(id: 88, name: "Godzilla Card Game"),
        .init(id: 89, name: "Riftbound: League of Legends Trading Card Game", aliases: ["Riftbound"]),
        .init(id: 90, name: "CookieRun: Braverse TCG"),
        .init(id: 91, name: "Palworld OFFICIAL CARD GAME"),
        .init(id: 92, name: "Cyberpunk TCG"),
    ]

    private static let accessoryIDs: Set<Int> = [31, 32, 35, 49, 50, 56]
    private static let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    private static let scannerIDs = Set(entries.filter { !accessoryIDs.contains($0.id) }.map(\.id))
    private static let categoriesByName: [String: Int] = {
        var result: [String: Int] = [:]
        for entry in entries {
            for name in [entry.name] + entry.aliases { result[normalized(name)] = entry.id }
        }
        return result
    }()

    static let gameKeys: [String: String] = Dictionary(uniqueKeysWithValues:
        entries.filter { scannerIDs.contains($0.id) }.map { ($0.name, "tcgp:\($0.id)") })

    static func scannerKey(for name: String) -> String? {
        guard let category = categoryID(for: name), scannerIDs.contains(category) else { return nil }
        return "tcgp:\(category)"
    }

    static func isScannerKey(_ key: String) -> Bool {
        guard key.hasPrefix("tcgp:"), let id = Int(key.dropFirst(5)),
              key == "tcgp:\(id)" else { return false }
        return scannerIDs.contains(id)
    }

    static func categoryID(for name: String) -> Int? { categoriesByName[normalized(name)] }
    static func isProductCategory(_ id: Int) -> Bool { entriesByID[id] != nil }
    static func name(for id: Int) -> String? { entriesByID[id]?.name }
    static func defaultLanguage(for game: String) -> String { categoryID(for: game) == 85 ? "Japanese" : "English" }

    static func scannerNames(forKeys keys: [String]) -> [String] {
        let definitions = Set(keys).compactMap { key -> TCGGameDefinition? in
            guard isScannerKey(key), let id = Int(key.dropFirst(5)) else { return nil }
            return entriesByID[id]
        }
        let ranks = [3: 0, 1: 1, 2: 2]
        return definitions.sorted { left, right in
            let first = ranks[left.id] ?? 3, second = ranks[right.id] ?? 3
            if first != second { return first < second }
            let names = left.name.localizedStandardCompare(right.name)
            return names == .orderedSame ? left.id < right.id : names == .orderedAscending
        }.map(\.name)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}

