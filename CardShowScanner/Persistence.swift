import Foundation
import SwiftData

@Model final class CardList {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    // Nil is an unmarked list; explicit outcomes are versioned app-owned JSON.
    var transactionOutcomeData: Data? = nil
    // Versioned source metadata exists only on the one-way Card Show mirror.
    var inventorySourceData: Data? = nil
    @Relationship(deleteRule: .cascade, inverse: \InventoryCard.list) var cards: [InventoryCard] = []
    init(name: String) { id = UUID(); self.name = name; createdAt = .now }
    var orderedCards: [InventoryCard] {
        cards.sorted { $0.addedAt == $1.addedAt ? $0.id.uuidString < $1.id.uuidString : $0.addedAt < $1.addedAt }
    }
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
    var cashOverrideText: String? = nil
    var tradeOverrideText: String? = nil
    var maximumOverrideText: String? = nil
    var sourceInventoryID: Int? = nil
    var offerLine: OfferLine {
        OfferLine(price: snapshot.marketPrice, quantity: quantity,
            cashOverride: cashOverrideText.flatMap { Decimal(string: $0) },
            tradeOverride: tradeOverrideText.flatMap { Decimal(string: $0) },
            maximumOverride: maximumOverrideText.flatMap { Decimal(string: $0) })
    }
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
    // Optional/defaulted additions preserve pre-batch historical sessions.
    var listID: UUID? = nil
    var game: String? = nil
    var statusRaw: String = "completed"
    var completedAt: Date? = nil
    var cashRateText: String? = nil
    var tradeRateText: String? = nil
    var maximumRateText: String? = nil
    var savedOffersData: Data? = nil
    var lastConsumedRecognitionRef: String? = nil
    var isActive: Bool { statusRaw == "active" && listID != nil }
    var isBatch: Bool { listID != nil }
    var rates: OfferRates {
        OfferRates(cash: cashRateText.flatMap { Decimal(string: $0) } ?? 70,
            trade: tradeRateText.flatMap { Decimal(string: $0) } ?? 80,
            maximum: maximumRateText.flatMap { Decimal(string: $0) } ?? 75)
    }
    func setRates(_ rates: OfferRates) {
        cashRateText = CSVExportService.number(rates.cash)
        tradeRateText = CSVExportService.number(rates.trade)
        maximumRateText = CSVExportService.number(rates.maximum)
    }
    func savedOffers() throws -> [OfferSnapshot] {
        guard let savedOffersData else { return [] }
        return try JSONDecoder().decode([OfferSnapshot].self, from: savedOffersData)
    }
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
        guard !list.isCardShowInventory else { throw CardShowInventoryFailure.readOnlyList }
        // Every confirmation is a physical card, including exact duplicates.
        let item = try InventoryCard(card: card)
        if let last = list.orderedCards.last {
            item.addedAt = max(Date.now, last.addedAt.addingTimeInterval(0.001))
        }
        context.insert(item); list.cards.append(item)
        DiagnosticLog.shared.record("inventory.insert")
    }

    /// Editing never coalesces physical rows, even when their identities become equal.
    static func edit(_ item: InventoryCard, card: CardCandidate, quantity: Int,
                     cashOverride: String?, tradeOverride: String?, maximumOverride: String?, context: ModelContext) throws {
        guard item.sourceInventoryID == nil, item.list?.isCardShowInventory != true else { throw CardShowInventoryFailure.readOnlyList }
        guard quantity > 0 else { throw BatchFailure.invalidQuantity }
        do {
            try item.update(card); item.quantity = quantity
            item.cashOverrideText = cashOverride; item.tradeOverrideText = tradeOverride; item.maximumOverrideText = maximumOverride
            try context.save()
        } catch { context.rollback(); throw error }
    }

    static func duplicate(_ list: CardList, context: ModelContext) throws {
        // Copies intentionally have neither source metadata nor source row IDs.
        let copy = CardList(name: list.name + " Copy"); context.insert(copy)
        for card in list.orderedCards {
            let item = try InventoryCard(card: card.snapshot, quantity: card.quantity)
            item.addedAt = card.addedAt
            item.cashOverrideText = card.cashOverrideText; item.tradeOverrideText = card.tradeOverrideText
            item.maximumOverrideText = card.maximumOverrideText
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
