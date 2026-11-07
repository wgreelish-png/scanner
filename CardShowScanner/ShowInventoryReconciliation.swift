import Foundation

enum ShowInventoryImportMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case merge, replace
    var id: Self { self }
    var title: String { self == .merge ? "Merge" : "Replace" }
}

/// The entire authoritative source is retained with the import operation. Its
/// source row identifiers describe provenance, not the identity of working lots.
struct ShowInventoryReconciliation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sourceLocationID: Int
    let snapshotID: Data
    let recordedAt: Date
    let sourceRows: [ShowInventorySeed]
    let createdInventoryIDs: [UUID]
    /// Missing on historical events, which replaced all working quantities.
    var mode: ShowInventoryImportMode? = nil
    var effectiveMode: ShowInventoryImportMode { mode ?? .replace }

    func validate() throws {
        guard sourceLocationID > 0, !snapshotID.isEmpty, snapshotID.count <= 4_096,
              recordedAt.timeIntervalSince1970.isFinite,
              createdInventoryIDs.count <= (mode == nil ? ShowBudgetBook.maximumInventorySeeds : ShowBudgetBook.maximumInventoryItems),
              Set(createdInventoryIDs).count == createdInventoryIDs.count else {
            throw ShowTransactionFailure.invalidInventory
        }
        try ShowInventoryReconciliationMath.validate(sourceRows)
    }
}

struct ShowInventoryReconciliationSummary: Equatable, Sendable {
    let addedQuantity: Int
    let removedQuantity: Int
    let unchangedSnapshot: Bool
    let totalQuantity: Int
}

/// A deterministic import plan is also used to validate the persisted journal.
/// Exact catalog identity includes game, product, SKU, printing, language, and
/// condition. Neither a source row ID nor CardCandidate.id is a stock identity.
enum ShowInventoryReconciliationMath {
    struct Plan {
        let inventory: [ShowInventoryItem]
        let changedIDs: [UUID]
        let summary: ShowInventoryReconciliationSummary
    }

    static func validate(_ seeds: [ShowInventorySeed]) throws {
        guard seeds.count <= ShowBudgetBook.maximumInventorySeeds else { throw ShowBudgetFailure.capacityExceeded }
        guard Set(seeds.map(\.sourceInventoryID)).count == seeds.count,
              seeds.allSatisfy({ $0.sourceInventoryID > 0 &&
                  (0...ShowBudgetBook.maximumQuantity).contains($0.quantity) && ShowTransactionMath.validCard($0.card) }) else {
            throw ShowTransactionFailure.invalidInventory
        }
    }

    static func totals(_ seeds: [ShowInventorySeed]) throws -> [CardIdentity: Int] {
        var result: [CardIdentity: Int] = [:]
        for seed in seeds { try add(seed.quantity, identity: seed.card.identity, to: &result) }
        return result
    }

    static func totals(_ items: [ShowInventoryItem]) throws -> [CardIdentity: Int] {
        var result: [CardIdentity: Int] = [:]
        for item in items { try add(item.quantity, identity: item.card.identity, to: &result) }
        return result
    }

    static func totalQuantity(_ inventory: [ShowInventoryItem]) throws -> Int {
        try inventory.reduce(0) { try adding($0, $1.quantity) }
    }

    private struct Addition {
        let source: ShowInventorySeed
        let quantity: Int
        let adoptedFrom: UUID?
    }

    private struct Removal {
        let inventoryID: UUID
        let quantity: Int
    }

    private static func removals(desired: [CardIdentity: Int], inventory: [ShowInventoryItem],
                                 mode: ShowInventoryImportMode,
                                 legacyLocalOverlap: [UUID: Int]) throws -> [Removal] {
        let managed = managedInventory(inventory, mode: mode, legacyLocalOverlap: legacyLocalOverlap)
        let current = try totals(managed)
        var excess: [CardIdentity: Int] = [:]
        for (identity, count) in current { excess[identity] = max(0, count - (desired[identity] ?? 0)) }
        // Preserve known basis wherever possible. Unknown lots go first, then
        // newest acquisition, then UUID. Sold-out lots remain permanent history.
        let order = managed.filter { $0.quantity > 0 }.sorted {
            if ($0.remainingCostCents == nil) != ($1.remainingCostCents == nil) { return $0.remainingCostCents == nil }
            if $0.acquiredAt != $1.acquiredAt { return $0.acquiredAt > $1.acquiredAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var result: [Removal] = []
        for item in order {
            let quantity = min(item.quantity, excess[item.card.identity] ?? 0)
            guard quantity > 0 else { continue }
            result.append(.init(inventoryID: item.id, quantity: quantity))
            excess[item.card.identity] = (excess[item.card.identity] ?? 0) - quantity
        }
        return result
    }

    /// The same deterministic list supplies both reserved IDs and journal replay.
    /// Merge adopts matching local copies only when the website's complete
    /// count grew, never merely because a local sale reduced source stock.
    private static func additions(seeds: [ShowInventorySeed], inventory: [ShowInventoryItem],
                                  mode: ShowInventoryImportMode?,
                                  previousSourceRows: [ShowInventorySeed],
                                  legacyLocalOverlap: [UUID: Int]) throws -> [Addition] {
        let desired = try totals(seeds), previous = try totals(previousSourceRows)
        let current = try totals(managedInventory(inventory, mode: mode ?? .replace, legacyLocalOverlap: legacyLocalOverlap))
        let removed: [UUID: Int]
        if mode != nil {
            removed = Dictionary(uniqueKeysWithValues: try removals(desired: desired, inventory: inventory,
                mode: mode ?? .replace, legacyLocalOverlap: legacyLocalOverlap).map { ($0.inventoryID, $0.quantity) })
        } else { removed = [:] }
        let local = Dictionary(grouping: inventory.filter { $0.isLocalAcquisition && $0.quantity > 0 }, by: { $0.card.identity })
        var visited = Set<CardIdentity>(), result: [Addition] = []
        for source in seeds.sorted(by: { $0.sourceInventoryID < $1.sourceInventoryID }) {
            let identity = source.card.identity
            guard visited.insert(identity).inserted else { continue }
            var needed = max(0, (desired[identity] ?? 0) - (current[identity] ?? 0))
            let candidates = (local[identity] ?? []).sorted {
                $0.acquiredAt == $1.acquiredAt ? $0.id.uuidString < $1.id.uuidString : $0.acquiredAt < $1.acquiredAt
            }
            // Explicit Replace makes every surviving copy source-managed, so
            // a subsequent Merge cannot count a matching local lot twice.
            // Historical missing-mode events retain their exact old plan.
            var adoptable = mode == .merge ? min(needed, max(0, (desired[identity] ?? 0) - (previous[identity] ?? 0))) : 0
            for item in candidates {
                let overlap = mode == .merge ? overlapQuantity(item, legacyLocalOverlap) : 0
                var quantity = mode == .replace ? item.quantity - (removed[item.id] ?? 0) : max(0, overlap - (removed[item.id] ?? 0))
                if adoptable > 0 {
                    let additional = min(adoptable, item.quantity - overlap)
                    quantity += additional
                    adoptable -= additional; needed -= additional
                }
                guard quantity > 0 else { continue }
                result.append(.init(source: source, quantity: quantity, adoptedFrom: item.id))
            }
            while needed > 0 {
                let quantity = min(needed, ShowBudgetBook.maximumQuantity)
                result.append(.init(source: source, quantity: quantity, adoptedFrom: nil))
                needed -= quantity
            }
        }
        return result
    }

    static func newLotCount(seeds: [ShowInventorySeed], inventory: [ShowInventoryItem],
                            mode: ShowInventoryImportMode? = nil,
                            previousSourceRows: [ShowInventorySeed] = [],
                            legacyLocalOverlap: [UUID: Int] = [:]) throws -> Int {
        try additions(seeds: seeds, inventory: inventory, mode: mode, previousSourceRows: previousSourceRows,
            legacyLocalOverlap: legacyLocalOverlap).count
    }

    static func plan(_ event: ShowInventoryReconciliation, inventory: [ShowInventoryItem],
                     previousSourceRows: [ShowInventorySeed] = [],
                     legacyLocalOverlap: [UUID: Int] = [:]) throws -> Plan {
        try event.validate()
        let mode = event.effectiveMode
        let desired = try totals(event.sourceRows)
        let additions = try additions(seeds: event.sourceRows, inventory: inventory, mode: event.mode,
            previousSourceRows: previousSourceRows, legacyLocalOverlap: legacyLocalOverlap)
        guard event.createdInventoryIDs.count == additions.count,
              event.createdInventoryIDs.count <= ShowBudgetBook.maximumInventoryItems - inventory.count,
              Set(event.createdInventoryIDs).isDisjoint(with: Set(inventory.map(\.id))) else {
            throw ShowTransactionFailure.invalidInventory
        }
        var result = inventory, changed: [UUID] = [], changedSet = Set<UUID>()
        let positions = Dictionary(uniqueKeysWithValues: result.indices.map { (result[$0].id, $0) })
        var removedQuantity = 0, addedQuantity = 0
        for removal in try removals(desired: desired, inventory: inventory, mode: mode, legacyLocalOverlap: legacyLocalOverlap) {
            guard let index = positions[removal.inventoryID] else { throw ShowTransactionFailure.invalidInventory }
            let item = result[index], count = removal.quantity
            let consumed = try ShowCostBasisMath.consumedCost(totalCostCents: item.remainingCostCents,
                quantity: item.quantity, consumedQuantity: count)
            result[index].quantity -= count
            result[index].remainingCostCents = item.remainingCostCents.flatMap { cost in consumed.map { cost - $0 } }
            changed.append(item.id); changedSet.insert(item.id)
            removedQuantity = try adding(removedQuantity, count)
        }
        for (addition, id) in zip(additions, event.createdInventoryIDs) {
            var cost: Int64?
            if let origin = addition.adoptedFrom {
                guard let index = positions[origin], result[index].isLocalAcquisition,
                      result[index].card.identity == addition.source.card.identity,
                      result[index].quantity >= addition.quantity else { throw ShowTransactionFailure.invalidInventory }
                let item = result[index]
                cost = try ShowCostBasisMath.consumedCost(totalCostCents: item.remainingCostCents,
                    quantity: item.quantity, consumedQuantity: addition.quantity)
                result[index].quantity -= addition.quantity
                result[index].remainingCostCents = item.remainingCostCents.flatMap { original in cost.map { original - $0 } }
                if changedSet.insert(origin).inserted { changed.append(origin) }
            } else { addedQuantity = try adding(addedQuantity, addition.quantity) }
            result.append(ShowInventoryItem(id: id, card: addition.source.card, quantity: addition.quantity,
                sourceInventoryID: addition.source.sourceInventoryID, sourceLocationID: event.sourceLocationID,
                acquiredAt: event.recordedAt, remainingCostCents: cost, acquiredByReconciliationID: event.id,
                adoptedFromInventoryID: addition.adoptedFrom))
            changed.append(id)
        }
        let actual = try totals(managedInventory(result, mode: mode)).filter { $0.value != 0 }
        guard actual == desired.filter({ $0.value != 0 }) else { throw ShowTransactionFailure.invalidInventory }
        return Plan(inventory: result, changedIDs: changed,
            summary: .init(addedQuantity: addedQuantity, removedQuantity: removedQuantity,
                unchangedSnapshot: false, totalQuantity: try totalQuantity(result)))
    }

    private static func managedInventory(_ inventory: [ShowInventoryItem], mode: ShowInventoryImportMode,
                                         legacyLocalOverlap: [UUID: Int] = [:]) -> [ShowInventoryItem] {
        guard mode == .merge else { return inventory }
        return inventory.compactMap { item in
            guard item.isLocalAcquisition else { return item }
            let quantity = overlapQuantity(item, legacyLocalOverlap)
            guard quantity > 0 else { return nil }
            var managed = item; managed.quantity = quantity
            return managed
        }
    }

    private static func overlapQuantity(_ item: ShowInventoryItem, _ legacyLocalOverlap: [UUID: Int]) -> Int {
        min(item.quantity, max(0, legacyLocalOverlap[item.id] ?? 0))
    }

    private static func add(_ quantity: Int, identity: CardIdentity, to totals: inout [CardIdentity: Int]) throws {
        totals[identity] = try adding(totals[identity] ?? 0, quantity)
    }

    private static func adding(_ left: Int, _ right: Int) throws -> Int {
        let value = left.addingReportingOverflow(right)
        guard !value.overflow else { throw ShowBudgetFailure.arithmeticOverflow }
        return value.partialValue
    }
}

extension ShowBudgetBook {
    /// Historical Replace could retain a known-cost local lot instead of an
    /// unknown source lot. Only those checkpoint copies overlap the website;
    /// purchases made afterward must remain independently available locally.
    func legacyLocalOverlapForNextImport() -> [UUID: Int] {
        guard let event = inventoryReconciliations.last, event.mode == nil else { return [:] }
        let localIDs = Set(inventory.filter { $0.isLocalAcquisition }.map(\.id))
        var states = Dictionary(uniqueKeysWithValues: costLedgerBaseline.map { ($0.id, $0.quantity) })
        for mutation in costMutations {
            for change in mutation.changes { states[change.after.id] = change.after.quantity }
            if mutation.kind == .reconciliation && mutation.operationID == event.id {
                return states.filter { localIDs.contains($0.key) && $0.value > 0 }
            }
        }
        return [:]
    }

    /// Source counts at the ledger checkpoint must not be confused with a later
    /// local sale. Legacy checkpoints predate the cost journal, so add back
    /// their then-active source outgoings to recover the seeded website count.
    func initialWebsiteSourceRows() throws -> [ShowInventorySeed] {
        let stock = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        let activeLegacy = Set(legacyTransactionIDs).subtracting(legacyReversedTransactionIDs)
        var legacyConsumed: [UUID: Int] = [:]
        for receipt in transactions where activeLegacy.contains(receipt.id) {
            for line in receipt.outgoing {
                let count = (legacyConsumed[line.inventoryID] ?? 0).addingReportingOverflow(line.quantity)
                guard !count.overflow else { throw ShowBudgetFailure.arithmeticOverflow }
                legacyConsumed[line.inventoryID] = count.partialValue
            }
        }
        return try costLedgerBaseline.compactMap { state -> ShowInventorySeed? in
            guard let item = stock[state.id], !item.isLocalAcquisition,
                  item.acquiredByReconciliationID == nil, let sourceID = item.sourceInventoryID else { return nil }
            let quantity = state.quantity.addingReportingOverflow(legacyConsumed[item.id] ?? 0)
            guard !quantity.overflow, (0...Self.maximumQuantity).contains(quantity.partialValue) else {
                throw ShowBudgetFailure.arithmeticOverflow
            }
            return ShowInventorySeed(sourceInventoryID: sourceID, card: item.card, quantity: quantity.partialValue)
        }.sorted { $0.sourceInventoryID < $1.sourceInventoryID }
    }

    /// Restoring a receipt across a later authoritative change could recreate
    /// removed copies or erase imported stock. Merge covers source identities
    /// and any directly adopted lot; Replace covers the complete card group.
    func reconciliationPreventsUndo(of receipt: ShowTransactionReceipt) -> Bool {
        let affected = Set(receipt.incoming.map { $0.card.identity } + receipt.outgoing.map { $0.card.identity })
        let stock = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        let sourceAffected = Set((receipt.incoming + receipt.outgoing).compactMap { line -> CardIdentity? in
            guard let item = stock[line.inventoryID], !item.isLocalAcquisition else { return nil }
            return line.card.identity
        })
        let affectedIDs = Set((receipt.incoming + receipt.outgoing).map(\.inventoryID))
        let events = Dictionary(uniqueKeysWithValues: inventoryReconciliations.map { ($0.id, $0) })
        let position = costMutations.lastIndex { $0.kind == .record && $0.operationID == receipt.id }
        return costMutations.enumerated().contains { index, mutation in
            guard index > (position ?? -1), mutation.kind == .reconciliation else { return false }
            let identities = events[mutation.operationID]?.effectiveMode == .merge ? sourceAffected : affected
            return mutation.changes.contains { change in
                affectedIDs.contains(change.after.id) ||
                    (stock[change.after.id].map { identities.contains($0.card.identity) } ?? false)
            }
        }
    }
}
