import Foundation
import Observation

/// Filtering is presentation only; saved lots, quantities and game identities
/// remain intact, including games outside the recognition-pack registry.
enum InventoryGameFilter {
    static func canonicalGame(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Unknown Game" }
        if let category = TCGGameRegistry.categoryID(for: value),
           let name = TCGGameRegistry.name(for: category) { return name }
        return value
    }

    static func matches(_ item: ShowInventoryItem, game: String) -> Bool {
        guard !game.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        return normalized(canonicalGame(item.card.identity.game)) == normalized(canonicalGame(game))
    }

    static func filtered(_ inventory: [ShowInventoryItem], game: String) -> [ShowInventoryItem] {
        inventory.filter { matches($0, game: game) }
    }

    static func games(in inventory: [ShowInventoryItem], including selectedGame: String = "") -> [String] {
        var games: [String: String] = [:]
        for item in inventory where item.quantity > 0 {
            let game = canonicalGame(item.card.identity.game)
            let key = normalized(game)
            if games[key] == nil { games[key] = game }
        }
        if !selectedGame.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let selected = canonicalGame(selectedGame)
            // Preserve the exact saved picker value when a custom name differs
            // only in case or accents from the spelling in available stock.
            games[normalized(selected)] = selected
        }
        return games.values.sorted { left, right in
            let order = left.localizedStandardCompare(right)
            return order == .orderedSame ? left < right : order == .orderedAscending
        }
    }

    static func title(for selectedGame: String) -> String {
        selectedGame.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "All Games" : canonicalGame(selectedGame)
    }

    private static func normalized(_ game: String) -> String {
        game.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Show Inventory and Price Tags share only this display preference. Saving a
/// filter never modifies inventory or any scanner, pricing or printer setting.
@MainActor @Observable final class InventoryGamePreferences {
    static let shared: InventoryGamePreferences = {
        let arguments = ProcessInfo.processInfo.arguments
        let prefix = "--show-transactions-fixture-id="
        let token = arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        let fixture = arguments.contains("--show-transactions-ui-fixture")
            ? token.flatMap { UUID(uuidString: $0)?.uuidString } : nil
        return InventoryGamePreferences(key: "inventoryGameFilter" + (fixture.map { ".fixture." + $0 } ?? ""))
    }()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    private var selection: String

    var selectedGame: String {
        get { selection }
        set {
            let next = Self.selection(newValue)
            guard next != selection || defaults.string(forKey: key) != next else { return }
            selection = next
            defaults.set(next, forKey: key)
        }
    }

    init(defaults: UserDefaults = .standard, key: String = "inventoryGameFilter") {
        self.defaults = defaults
        self.key = key
        selection = Self.selection(defaults.string(forKey: key) ?? "")
    }

    private static func selection(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : InventoryGameFilter.canonicalGame(raw)
    }
}

/// Display order only. Sorting never changes acquisition lots or receipt order.
enum ShowInventorySort: String, CaseIterable, Identifiable, Sendable {
    case nameAscending, nameDescending, marketDescending, marketAscending
    case quantityDescending, newestFirst, oldestFirst, setAndNumber

    var id: Self { self }

    init(preference: String) { self = Self(rawValue: preference) ?? .nameAscending }

    var title: String {
        switch self {
        case .nameAscending: return "Name: A–Z"
        case .nameDescending: return "Name: Z–A"
        case .marketDescending: return "Market: High to Low"
        case .marketAscending: return "Market: Low to High"
        case .quantityDescending: return "Quantity: Most First"
        case .newestFirst: return "Newest Added"
        case .oldestFirst: return "Oldest Added"
        case .setAndNumber: return "Set & Card Number"
        }
    }

    func sorted(_ items: [ShowInventoryItem]) -> [ShowInventoryItem] {
        items.sorted { left, right in
            let order: ComparisonResult
            switch self {
            case .nameAscending: order = Self.text(left.card.name, right.card.name)
            case .nameDescending: order = Self.text(right.card.name, left.card.name)
            case .marketAscending, .marketDescending:
                switch (left.card.marketPrice, right.card.marketPrice) {
                case (nil, nil): order = .orderedSame
                case (nil, _): order = .orderedDescending
                case (_, nil): order = .orderedAscending
                case let (price?, other?):
                    order = self == .marketAscending ? Self.compare(price, other) : Self.compare(other, price)
                }
            case .quantityDescending: order = Self.compare(right.quantity, left.quantity)
            case .newestFirst: order = Self.compare(right.acquiredAt, left.acquiredAt)
            case .oldestFirst: order = Self.compare(left.acquiredAt, right.acquiredAt)
            case .setAndNumber:
                let set = Self.text(left.card.set, right.card.set)
                order = set == .orderedSame ? Self.text(left.card.number, right.card.number) : set
            }
            if order != .orderedSame { return order == .orderedAscending }
            for (first, second) in [(left.card.name, right.card.name), (left.card.set, right.card.set),
                                    (left.card.number, right.card.number)] {
                let tie = Self.text(first, second)
                if tie != .orderedSame { return tie == .orderedAscending }
            }
            if left.acquiredAt != right.acquiredAt { return left.acquiredAt < right.acquiredAt }
            return left.id.uuidString < right.id.uuidString
        }
    }

    private static func text(_ left: String, _ right: String) -> ComparisonResult {
        left.localizedStandardCompare(right)
    }

    private static func compare<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult {
        left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
    }
}
