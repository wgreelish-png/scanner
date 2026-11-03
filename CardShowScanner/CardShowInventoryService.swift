import Foundation
import SwiftData

/// The working stock state when a source download was authorized. A pending
/// handoff cannot overwrite local movements recorded after that download.
struct ShowInventorySyncRevision: Codable, Equatable, Sendable {
    let mutations: Int
    let lots: Int
    let locationID: Int?

    init(mutations: Int, lots: Int, locationID: Int? = nil) {
        self.mutations = mutations; self.lots = lots; self.locationID = locationID
    }

    @MainActor init(store: ShowBudgetStore) {
        mutations = store.book.costMutations.count
        lots = store.inventory.count
        locationID = store.inventorySourceLocationID
    }

    var isValid: Bool {
        let maximumMutations = ShowBudgetBook.maximumTransactions * 2 +
            ShowBudgetBook.maximumCostAdjustments + ShowBudgetBook.maximumInventoryReconciliations
        return (0...maximumMutations).contains(mutations) &&
            (0...ShowBudgetBook.maximumInventoryItems).contains(lots) &&
            (locationID.map { $0 > 0 } ?? true)
    }
}

/// Source identity and freshness commit in the same store as the imported rows.
/// No sidecar UUID can outlive a failed save or recreate a deleted local list.
struct CardShowInventoryLink: Codable, Equatable, Sendable {
    let version: Int
    let locationID: Int
    let locationName: String
    let refreshedAt: Date
    let syncID: UUID?
    let pendingWorkingSync: Bool?
    let workingRevision: ShowInventorySyncRevision?

    init(locationID: Int, locationName: String, refreshedAt: Date, version: Int = 1,
         syncID: UUID? = nil, pendingWorkingSync: Bool? = nil,
         workingRevision: ShowInventorySyncRevision? = nil) {
        self.version = version; self.locationID = locationID
        self.locationName = locationName; self.refreshedAt = refreshedAt
        self.syncID = syncID; self.pendingWorkingSync = pendingWorkingSync
        self.workingRevision = workingRevision
    }

    /// This token survives acknowledgement unchanged, so a retry can identify
    /// a source snapshot already applied to the independent financial store.
    var inventorySnapshotID: Data? {
        guard version == 2, let syncID else { return nil }
        return Data(syncID.uuidString.utf8)
    }

    private enum CodingKeys: String, CodingKey {
        case version, locationID, locationName, refreshedAt, syncID, pendingWorkingSync, workingRevision
    }
    private var valid: Bool {
        guard locationID > 0, !locationName.isEmpty, locationName.count <= 200,
              refreshedAt.timeIntervalSince1970.isFinite else { return false }
        switch version {
        case 1: return syncID == nil && pendingWorkingSync == nil && workingRevision == nil
        case 2: return syncID != nil && pendingWorkingSync != nil && (workingRevision?.isValid ?? true)
        default: return false
        }
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        locationID = try values.decode(Int.self, forKey: .locationID)
        locationName = try values.decode(String.self, forKey: .locationName)
        refreshedAt = try values.decode(Date.self, forKey: .refreshedAt)
        syncID = try values.decodeIfPresent(UUID.self, forKey: .syncID)
        pendingWorkingSync = try values.decodeIfPresent(Bool.self, forKey: .pendingWorkingSync)
        workingRevision = try values.decodeIfPresent(ShowInventorySyncRevision.self, forKey: .workingRevision)
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
        try values.encodeIfPresent(syncID, forKey: .syncID)
        try values.encodeIfPresent(pendingWorkingSync, forKey: .pendingWorkingSync)
        try values.encodeIfPresent(workingRevision, forKey: .workingRevision)
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
        workingRevision: ShowInventorySyncRevision? = nil,
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
            locationName: snapshot.location.name, refreshedAt: snapshot.fetchedAt,
            version: 2, syncID: UUID(), pendingWorkingSync: true, workingRevision: workingRevision))
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

    /// Clear only the exact source operation already committed to working
    /// inventory. The token and imported rows stay intact for durable retries.
    static func acknowledgeWorkingSync(list: CardList, expectedSnapshotID: Data, context: ModelContext,
        save: (@MainActor (ModelContext) throws -> Void)? = nil) throws {
        guard !context.hasChanges else {
            DiagnosticLog.shared.record("inventory_import.save_blocked", ["phase": "acknowledgement", "reason": "unsaved_changes"])
            throw CardShowInventoryFailure.persistenceFailed
        }
        guard let current = try importedList(context: context), current === list,
              let link = list.cardShowInventory, link.version == 2,
              link.pendingWorkingSync == true, link.inventorySnapshotID == expectedSnapshotID else {
            throw CardShowInventoryFailure.invalidResponse
        }
        let previous = list.inventorySourceData
        let acknowledged = CardShowInventoryLink(locationID: link.locationID,
            locationName: link.locationName, refreshedAt: link.refreshedAt,
            version: 2, syncID: link.syncID, pendingWorkingSync: false, workingRevision: link.workingRevision)
        let metadata = try JSONEncoder().encode(acknowledged)
        do {
            list.inventorySourceData = metadata
            if let save { try save(context) } else { try context.save() }
            DiagnosticLog.shared.record("inventory_import.working_sync_acknowledged")
        } catch {
            context.rollback()
            if list.inventorySourceData != previous {
                list.inventorySourceData = previous
                if context.hasChanges { context.rollback() }
            }
            context.processPendingChanges()
            DiagnosticLog.shared.failure("inventory_import.acknowledgement_error", error)
            DiagnosticLog.shared.record("inventory_import.save_failed", ServiceDiagnosticFields.failure(error)
                .merging(["phase": "acknowledgement", "reason": "persistence_failed"]) { _, value in value })
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
