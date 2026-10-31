import Foundation
import SwiftData

/// Source identity and freshness commit in the same store as the imported rows.
/// No sidecar UUID can outlive a failed save or recreate a deleted local list.
struct CardShowInventoryLink: Codable, Equatable, Sendable {
    let version: Int
    let locationID: Int
    let locationName: String
    let refreshedAt: Date

    init(locationID: Int, locationName: String, refreshedAt: Date, version: Int = 1) {
        self.version = version; self.locationID = locationID
        self.locationName = locationName; self.refreshedAt = refreshedAt
    }

    private enum CodingKeys: String, CodingKey { case version, locationID, locationName, refreshedAt }
    private var valid: Bool {
        version == 1 && locationID > 0 && !locationName.isEmpty && locationName.count <= 200 && refreshedAt.timeIntervalSince1970.isFinite
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        locationID = try values.decode(Int.self, forKey: .locationID)
        locationName = try values.decode(String.self, forKey: .locationName)
        refreshedAt = try values.decode(Date.self, forKey: .refreshedAt)
        guard valid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid inventory link."))
        }
    }
    func encode(to encoder: Encoder) throws {
        guard valid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Invalid inventory link."))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version); try values.encode(locationID, forKey: .locationID)
        try values.encode(locationName, forKey: .locationName); try values.encode(refreshedAt, forKey: .refreshedAt)
    }
}

extension CardList {
    /// Even damaged metadata keeps source rows protected from local edits.
    var isCardShowInventory: Bool { inventorySourceData != nil }
    var cardShowInventory: CardShowInventoryLink? {
        guard let inventorySourceData, inventorySourceData.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(CardShowInventoryLink.self, from: inventorySourceData)
    }
}

@MainActor enum CardShowInventoryService {
    static func importedList(context: ModelContext) throws -> CardList? {
        let linked = try context.fetch(FetchDescriptor<CardList>()).filter(\.isCardShowInventory)
        guard linked.count <= 1 else {
            DiagnosticLog.shared.record("inventory_import.save_blocked", ["phase": "persistence", "reason": "multiple_imported_lists"])
            throw CardShowInventoryFailure.invalidResponse
        }
        guard let list = linked.first else { return nil }
        guard list.cardShowInventory != nil else {
            DiagnosticLog.shared.record("inventory_import.save_blocked", ["phase": "persistence", "reason": "invalid_source_link"])
            throw CardShowInventoryFailure.invalidResponse
        }
        return list
    }

    /// Apply one fully fetched snapshot, preserving source quantities as given.
    /// Source order is retained on first import; new rows append thereafter.
    @discardableResult static func apply(_ snapshot: CardShowInventorySnapshot, context: ModelContext,
        save: (@MainActor (ModelContext) throws -> Void)? = nil) throws -> CardList {
        guard snapshot.location.id > 0, snapshot.location.name.count <= 200,
              normalized(snapshot.location.name) == "card show", snapshot.fetchedAt.timeIntervalSince1970.isFinite,
              snapshot.rows.count <= 10_000 else { throw CardShowInventoryFailure.invalidResponse }
        var identifiers = Set<Int>()
        let encoder = JSONEncoder()
        let prepared = try snapshot.rows.map { row -> (row: CardShowInventoryRow, data: Data) in
            guard row.inventoryID > 0, identifiers.insert(row.inventoryID).inserted,
                  (0...1_000_000).contains(row.quantity), !row.card.name.isEmpty,
                  !row.card.identity.productID.isEmpty else { throw CardShowInventoryFailure.invalidResponse }
            return (row, try encoder.encode(row.card))
        }
        let existing = try importedList(context: context)
        if let existing, existing.cardShowInventory?.locationID != snapshot.location.id {
            throw CardShowInventoryFailure.locationChanged
        }
        // A rollback of a sync must never discard somebody else's unsaved draft.
        guard !context.hasChanges else {
            DiagnosticLog.shared.record("inventory_import.save_blocked", ["phase": "persistence", "reason": "unsaved_changes"])
            throw CardShowInventoryFailure.persistenceFailed
        }
        let list = existing ?? CardList(name: "Card Show")
        let previous = State(list: list)
        var bySource: [Int: InventoryCard] = [:]
        for item in list.cards {
            guard let sourceID = item.sourceInventoryID, sourceID > 0, bySource[sourceID] == nil,
                  item.list?.id == list.id, (try? JSONDecoder().decode(CardCandidate.self, from: item.data)) != nil else {
                throw CardShowInventoryFailure.invalidResponse
            }
            bySource[sourceID] = item
        }
        let metadata = try encoder.encode(CardShowInventoryLink(locationID: snapshot.location.id,
            locationName: snapshot.location.name, refreshedAt: snapshot.fetchedAt))
        do {
            if existing == nil { context.insert(list) }
            var nextDate = list.orderedCards.last?.addedAt ?? snapshot.fetchedAt.addingTimeInterval(-0.001)
            var nextRows = list.orderedCards.filter { identifiers.contains($0.sourceInventoryID ?? -1) }
            for value in prepared {
                if let item = bySource[value.row.inventoryID] {
                    item.data = value.data; item.quantity = value.row.quantity
                } else {
                    let item = try InventoryCard(card: value.row.card, quantity: value.row.quantity)
                    item.sourceInventoryID = value.row.inventoryID
                    nextDate = nextDate.addingTimeInterval(0.001); item.addedAt = nextDate
                    context.insert(item); nextRows.append(item)
                }
            }
            let removed = list.cards.filter { !identifiers.contains($0.sourceInventoryID ?? -1) }
            list.cards = nextRows
            list.inventorySourceData = metadata
            for item in removed { context.delete(item) }
            if let save { try save(context) } else { try context.save() }
            DiagnosticLog.shared.record("inventory_import.saved", ["records": String(nextRows.count), "quantity": String(list.quantity)])
            return list
        } catch {
            context.rollback()
            if existing != nil {
                previous.restore(context: context)
                // Reconcile any cached relationship repair to the unchanged
                // store savepoint. Never leave our repairs as a dirty draft
                // that the next explicit retry would reject.
                if context.hasChanges { context.rollback() }
            }
            // Initial inserts are discarded by rollback. Deleting them here
            // would introduce new pending changes after a failed save.
            context.processPendingChanges()
            DiagnosticLog.shared.failure("inventory_import.persistence_error", error)
            DiagnosticLog.shared.record("inventory_import.save_failed", ServiceDiagnosticFields.failure(error)
                .merging(["phase": "persistence", "reason": "persistence_failed"]) { _, value in value })
            throw CardShowInventoryFailure.persistenceFailed
        }
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private struct State {
        let list: CardList
        let sourceData: Data?
        let rows: [RowState]
        init(list: CardList) { self.list = list; sourceData = list.inventorySourceData; rows = list.cards.map(RowState.init) }
        func restore(context: ModelContext) {
            if list.inventorySourceData != sourceData { list.inventorySourceData = sourceData }
            for row in rows { row.restore() }
            if Set(list.cards.map(\.id)) != Set(rows.map { $0.item.id }) { list.cards = rows.map(\.item) }
            context.processPendingChanges()
        }
    }
    private struct RowState {
        let item: InventoryCard
        let data: Data
        let quantity: Int
        let addedAt: Date
        let sourceID: Int?
        let cash: String?, trade: String?, maximum: String?
        init(_ item: InventoryCard) {
            self.item = item; data = item.data; quantity = item.quantity; addedAt = item.addedAt
            sourceID = item.sourceInventoryID; cash = item.cashOverrideText
            trade = item.tradeOverrideText; maximum = item.maximumOverrideText
        }
        func restore() {
            if item.data != data { item.data = data }; if item.quantity != quantity { item.quantity = quantity }
            if item.addedAt != addedAt { item.addedAt = addedAt }; if item.sourceInventoryID != sourceID { item.sourceInventoryID = sourceID }
            if item.cashOverrideText != cash { item.cashOverrideText = cash }
            if item.tradeOverrideText != trade { item.tradeOverrideText = trade }
            if item.maximumOverrideText != maximum { item.maximumOverrideText = maximum }
        }
    }
}
