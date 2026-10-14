import Foundation
import SwiftData

@Model final class CardList {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \InventoryCard.list) var cards: [InventoryCard] = []
    init(name: String) { id = UUID(); self.name = name; createdAt = .now }
    var quantity: Int { cards.reduce(0) { $0 + $1.quantity } }
    var knownValue: Decimal { cards.reduce(Decimal.zero) { $0 + ($1.snapshot.marketPrice ?? 0) * Decimal($1.quantity) } }
    var unpricedQuantity: Int { cards.filter { $0.snapshot.marketPrice == nil }.reduce(0) { $0 + $1.quantity } }
}

@Model final class InventoryCard {
    @Attribute(.unique) var id: UUID
    var data: Data
    var quantity: Int
    var addedAt: Date
    var list: CardList?
    init(card: CardCandidate, quantity: Int = 1) throws {
        id = UUID(); data = try JSONEncoder().encode(card); self.quantity = quantity; addedAt = .now
    }
    var snapshot: CardCandidate {
        // Data is written only by the app's versioned Codable model.
        (try? JSONDecoder().decode(CardCandidate.self, from: data)) ?? CardCandidate(
            identity: CardIdentity(game: "Unknown", productID: id.uuidString, printing: "Unknown"),
            name: "Unreadable card — edit to recover", set: "", number: "", confidence: 0, printings: [])
    }
    func update(_ card: CardCandidate) throws { data = try JSONEncoder().encode(card) }
}

@Model final class ScanSession {
    var id: UUID
    var startedAt: Date
    var listName: String
    var addedQuantity: Int
    var knownValueText: String
    var unpricedQuantity: Int
    init(listName: String) {
        id = UUID(); startedAt = .now; self.listName = listName
        addedQuantity = 0; knownValueText = "0"; unpricedQuantity = 0
    }
    var knownValue: Decimal { Decimal(string: knownValueText) ?? 0 }
    func record(_ card: CardCandidate) {
        addedQuantity += 1
        if let price = card.marketPrice { knownValueText = CSVExportService.number(knownValue + price) }
        else { unpricedQuantity += 1 }
    }
}

@MainActor enum CardListService {
    static func add(_ card: CardCandidate, to list: CardList, context: ModelContext) throws {
        if let existing = list.cards.first(where: { $0.snapshot.identity == card.identity }) {
            DiagnosticLog.shared.record("inventory.merge")
            existing.quantity += 1
            // A fresh quote may update the same exact inventory variant.
            if card.marketPrice != nil { try existing.update(card) }
        } else {
            DiagnosticLog.shared.record("inventory.insert")
            let item = try InventoryCard(card: card)
            context.insert(item); list.cards.append(item)
        }
    }
    static func duplicate(_ list: CardList, context: ModelContext) throws {
        let copy = CardList(name: list.name + " Copy"); context.insert(copy)
        for card in list.cards {
            let item = try InventoryCard(card: card.snapshot, quantity: card.quantity)
            context.insert(item); copy.cards.append(item)
        }
        try context.save()
        DiagnosticLog.shared.record("list.duplicated")
    }
    static func save(_ context: ModelContext) throws {
        do { try context.save(); DiagnosticLog.shared.record("persistence.saved") }
        catch { DiagnosticLog.shared.failure("persistence.failed", error); context.rollback(); throw error }
    }
}
