import Foundation

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
