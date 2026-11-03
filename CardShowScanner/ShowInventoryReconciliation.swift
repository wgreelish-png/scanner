import Foundation

/// The entire authoritative source is retained with the import operation. Its
/// source row identifiers describe provenance, not the identity of working lots.
struct ShowInventoryReconciliation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sourceLocationID: Int
    let snapshotID: Data
    let recordedAt: Date
    let sourceRows: [ShowInventorySeed]
    let createdInventoryIDs: [UUID]

    func validate() throws {
        guard sourceLocationID > 0, !snapshotID.isEmpty, snapshotID.count <= 4_096,
              recordedAt.timeIntervalSince1970.isFinite,
              createdInventoryIDs.count <= ShowBudgetBook.maximumInventorySeeds,
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

    static func newLotCount(seeds: [ShowInventorySeed], inventory: [ShowInventoryItem]) throws -> Int {
        let current = try totals(inventory), desired = try totals(seeds)
        return try desired.reduce(0) { count, row in
            let added = max(0, row.value - (current[row.key] ?? 0))
            let lots = added / ShowBudgetBook.maximumQuantity + (added % ShowBudgetBook.maximumQuantity == 0 ? 0 : 1)
            return try adding(count, lots)
        }
    }

    static func plan(_ event: ShowInventoryReconciliation, inventory: [ShowInventoryItem]) throws -> Plan {
        try event.validate()
        let desired = try totals(event.sourceRows), current = try totals(inventory)
        guard event.createdInventoryIDs.count == (try newLotCount(seeds: event.sourceRows, inventory: inventory)),
              event.createdInventoryIDs.count <= ShowBudgetBook.maximumInventoryItems - inventory.count,
              Set(event.createdInventoryIDs).isDisjoint(with: Set(inventory.map(\.id))) else {
            throw ShowTransactionFailure.invalidInventory
        }
        var result = inventory, changed: [UUID] = [], excess: [CardIdentity: Int] = [:]
        for (identity, count) in current { excess[identity] = max(0, count - (desired[identity] ?? 0)) }
        // Preserve known basis wherever possible. Unknown lots go first, then
        // newest acquisition, then UUID. Sold-out lots remain permanent history.
        let removalOrder = result.indices.filter { result[$0].quantity > 0 }.sorted {
            let left = result[$0], right = result[$1]
            if (left.remainingCostCents == nil) != (right.remainingCostCents == nil) { return left.remainingCostCents == nil }
            if left.acquiredAt != right.acquiredAt { return left.acquiredAt > right.acquiredAt }
            return left.id.uuidString < right.id.uuidString
        }
        var removedQuantity = 0, addedQuantity = 0
        for index in removalOrder {
            let item = result[index], count = min(item.quantity, excess[item.card.identity] ?? 0)
            guard count > 0 else { continue }
            let consumed = try ShowCostBasisMath.consumedCost(totalCostCents: item.remainingCostCents,
                quantity: item.quantity, consumedQuantity: count)
            result[index].quantity -= count
            result[index].remainingCostCents = item.remainingCostCents.flatMap { cost in consumed.map { cost - $0 } }
            excess[item.card.identity] = (excess[item.card.identity] ?? 0) - count
            changed.append(item.id)
            removedQuantity = try adding(removedQuantity, count)
        }
        var visited = Set<CardIdentity>(), newIndex = 0
        // Lowest source row ID supplies the immutable card/provenance for a
        // new group. Current prices never replace an existing lot's card.
        for source in event.sourceRows.sorted(by: { $0.sourceInventoryID < $1.sourceInventoryID }) {
            let identity = source.card.identity
            guard visited.insert(identity).inserted else { continue }
            var additional = max(0, (desired[identity] ?? 0) - (current[identity] ?? 0))
            while additional > 0 {
                let quantity = min(additional, ShowBudgetBook.maximumQuantity)
                let id = event.createdInventoryIDs[newIndex]
                result.append(ShowInventoryItem(id: id, card: source.card, quantity: quantity,
                    sourceInventoryID: source.sourceInventoryID, sourceLocationID: event.sourceLocationID,
                    acquiredAt: event.recordedAt, acquiredByReconciliationID: event.id))
                changed.append(id); newIndex += 1
                additional -= quantity
                addedQuantity = try adding(addedQuantity, quantity)
            }
        }
        // Zero target rows and archived zero lots are equivalent for stock.
        let actual = try totals(result).filter { $0.value != 0 }
        guard actual == desired.filter({ $0.value != 0 }) else { throw ShowTransactionFailure.invalidInventory }
        return Plan(inventory: result, changedIDs: changed,
            summary: .init(addedQuantity: addedQuantity, removedQuantity: removedQuantity,
                unchangedSnapshot: false, totalQuantity: try totalQuantity(result)))
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
    /// Restoring a receipt across a later authoritative change could recreate
    /// removed copies or erase imported stock. Compare the complete card group:
    /// an import may add its copies in a separate lot. Order handles equal dates.
    func reconciliationPreventsUndo(of receipt: ShowTransactionReceipt) -> Bool {
        let affected = Set(receipt.incoming.map { $0.card.identity } + receipt.outgoing.map { $0.card.identity })
        let stock = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        let position = costMutations.lastIndex { $0.kind == .record && $0.operationID == receipt.id }
        return costMutations.enumerated().contains { index, mutation in
            index > (position ?? -1) && mutation.kind == .reconciliation &&
                mutation.changes.contains { change in
                    stock[change.after.id].map { affected.contains($0.card.identity) } ?? false
                }
        }
    }
}
