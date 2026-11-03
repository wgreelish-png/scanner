import Foundation
import SwiftData

enum ShowTransactionListFailure: LocalizedError, Equatable {
    case unsavedChanges, listUnavailable, sourceChanged, inventoryRefreshRequired, invalidCards, invalidOffer, alreadyRecorded
    var errorDescription: String? {
        switch self {
        case .unsavedChanges: return "Finish or cancel your card edits before recording a transaction."
        case .listUnavailable: return "This scanned list is no longer available. Select it again before recording."
        case .sourceChanged: return "The scanned list changed while you were reviewing this deal. Select it again to review the current cards."
        case .inventoryRefreshRequired: return "Working inventory changed after the downloaded snapshot. Open Inventory → Source and tap Refresh Inventory to get a new website copy. Your local changes are kept."
        case .invalidCards: return "Choose a nonempty scanned list with valid cards and quantities."
        case .invalidOffer: return "The list’s offer settings are invalid. Review its percentages and per-card values."
        case .alreadyRecorded: return "This list already has a recorded transaction. Review or undo that transaction before recording it again."
        }
    }
}

/// Scanned lists remain the historical source. The durable stock/budget ledger
/// owns completed acquisitions, so there is no second financial projection or
/// mutation of a scanner's physical rows after a successful transaction.
@MainActor enum ShowTransactionListService {
    struct IncomingSnapshot: Equatable {
        let listID: UUID
        let name: String
        let cards: [ShowIncomingCard]
        let defaultValueCents: Int64?
    }

    static func incomingSnapshot(for list: CardList, kind: ShowTransactionKind,
                                 context: ModelContext) throws -> IncomingSnapshot {
        IncomingSnapshot(listID: list.id, name: list.name, cards: try costedIncomingCards(for: list, kind: kind, context: context),
            defaultValueCents: try defaultIncomingValue(for: list, kind: kind, context: context))
    }
    static func incomingCards(for list: CardList) throws -> [ShowIncomingCard] {
        guard !list.isCardShowInventory, !list.cards.isEmpty, list.cards.count <= 10_000 else {
            throw ShowTransactionListFailure.invalidCards
        }
        var seen = Set<UUID>()
        return try list.orderedCards.map { row in
            guard seen.insert(row.id).inserted, (1...1_000_000).contains(row.quantity),
                  let card = try? JSONDecoder().decode(CardCandidate.self, from: row.data),
                  !card.name.isEmpty, !card.identity.productID.isEmpty else {
                throw ShowTransactionListFailure.invalidCards
            }
            return ShowIncomingCard(id: row.id, card: card, quantity: row.quantity)
        }
    }

    /// Allocation weights are calculated offers, not acquisition costs. The
    /// actual confirmed payment (or carried trade cost) is allocated later.
    static func costedIncomingCards(for list: CardList, kind: ShowTransactionKind,
                                    context: ModelContext) throws -> [ShowIncomingCard] {
        var rows = try incomingCards(for: list)
        let rates = try offerRates(for: list, context: context)
        let items = Dictionary(uniqueKeysWithValues: list.cards.map { ($0.id, $0) })
        for index in rows.indices {
            guard let item = items[rows[index].id] else { throw ShowTransactionListFailure.invalidCards }
            let override = kind == .purchase ? item.cashOverrideText : item.tradeOverrideText
            let rate = kind == .purchase ? rates.cash : rates.trade
            let perCopy: Decimal?
            if let override { perCopy = CustomOfferAmount.parse(override) }
            else if let market = rows[index].card.marketPrice { perCopy = market * rate / 100 }
            else { perCopy = nil }
            if let perCopy {
                rows[index].costWeightCents = try exactCents(OfferCalculator.cents(perCopy * Decimal(rows[index].quantity)))
            }
        }
        return rows
    }

    private static func offerRates(for list: CardList, context: ModelContext) throws -> OfferRates {
        let sessions = try context.fetch(FetchDescriptor<ScanSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))
        let rates = sessions.first { $0.listID == list.id }?.rates ?? SessionService.defaults()
        guard rates.isValid else { throw ShowTransactionListFailure.invalidOffer }
        for item in list.cards {
            for raw in [item.cashOverrideText, item.tradeOverrideText] {
                if let raw, CustomOfferAmount.parse(raw) == nil { throw ShowTransactionListFailure.invalidOffer }
            }
        }
        return rates
    }

    private static func exactCents(_ value: Decimal) throws -> Int64 {
        guard !value.isNaN, value >= 0, value <= ShowBudgetMoney.decimal(ShowBudgetMoney.maximumCents) else {
            throw ShowTransactionListFailure.invalidOffer
        }
        let scaled = value * 100
        let cents = NSDecimalNumber(decimal: scaled).int64Value
        guard ShowBudgetMoney.isValid(cents), Decimal(cents) == scaled else { throw ShowTransactionListFailure.invalidOffer }
        return cents
    }

    private static func sameCards(_ source: [ShowIncomingCard], _ draft: [ShowIncomingCard]) -> Bool {
        guard source.count == draft.count else { return false }
        return zip(source, draft).allSatisfy { pair in
            pair.0.id == pair.1.id && pair.0.card == pair.1.card && pair.0.quantity == pair.1.quantity
        }
    }

    /// A partial price total is not silently used as the whole agreed amount.
    /// The form may accept an explicitly entered amount for an unpriced lot.
    static func defaultIncomingValue(for list: CardList, kind: ShowTransactionKind,
                                     context: ModelContext) throws -> Int64? {
        _ = try incomingCards(for: list)
        let rates = try offerRates(for: list, context: context)
        let totals = OfferCalculator.calculate(list.cards.map(\.offerLine), rates: rates)
        guard totals.unpricedQuantity == 0 else { return nil }
        let value = kind == .purchase ? totals.cash : totals.trade
        return try exactCents(value)
    }

    static func record(_ draft: ShowTransactionDraft, showID: UUID, context: ModelContext,
                       store: ShowBudgetStore = .shared) throws -> ShowTransactionReceipt {
        // A committed retry is independent of later edits/deletion of its source.
        if let old = store.transactions.first(where: { $0.id == draft.id }) {
            guard old.draft == draft, old.showID == showID else { throw ShowBudgetStoreFailure.conflictingEntry }
            return try store.recordTransaction(draft, showID: showID)
        }
        guard !context.hasChanges else { throw ShowTransactionListFailure.unsavedChanges }
        if let listID = draft.incomingListID {
            guard let list = try context.fetch(FetchDescriptor<CardList>(predicate: #Predicate { $0.id == listID })).first,
                  !list.isCardShowInventory else { throw ShowTransactionListFailure.listUnavailable }
            guard sameCards(try incomingCards(for: list), draft.incoming), list.name == draft.incomingListName else {
                throw ShowTransactionListFailure.sourceChanged
            }
            guard store.transaction(forListID: listID) == nil,
                  list.transactionOutcomeData == nil || list.outcomeRecord?.kind == .nothingHappened else {
                throw ShowTransactionListFailure.alreadyRecorded
            }
        } else if !draft.incoming.isEmpty || draft.kind != .sale {
            throw ShowTransactionListFailure.listUnavailable
        }
        let receipt = try store.recordTransaction(draft, showID: showID)
        DiagnosticLog.shared.record("show_transaction.recorded", ["reason": receipt.kind.rawValue,
            "records": String(receipt.incoming.count + receipt.outgoing.count)])
        return receipt
    }

    static func outcomeTitle(for list: CardList, store: ShowBudgetStore = .shared) -> String {
        if let receipt = store.transaction(forListID: list.id) { return receipt.kind.title }
        if let reversed = store.transactions.filter({ $0.incomingListID == list.id }).compactMap(\.reversedAt).max(),
           list.outcomeRecord.map({ $0.recordedAt < reversed }) ?? true { return "Transaction undone" }
        return list.outcomeTitle
    }
}

/// A fresh source snapshot first commits its pending marker with the source
/// rows. The working ledger applies that marker once, then acknowledges it.
/// Acknowledgment failures can retry without replaying stock after local sales.
@MainActor enum ShowInventoryBridge {
    static func seedFromImportedList(context: ModelContext, store: ShowBudgetStore = .shared) throws {
        guard !context.hasChanges else { throw ShowTransactionListFailure.unsavedChanges }
        guard let list = try CardShowInventoryService.importedList(context: context),
              let link = list.cardShowInventory else { return }
        if link.version == 2, link.pendingWorkingSync == true {
            _ = try synchronizeImportedList(list, context: context, store: store)
            return
        }
        // An established v1 source has no durable fresh-refresh marker. Keep
        // its working stock until the user imports a complete fresh snapshot.
        guard link.version == 1 else { return }
        store.reload()
        guard store.isLoaded else { throw ShowBudgetStoreFailure.notLoaded }
        guard store.inventorySourceLocationID == nil, store.inventory.isEmpty,
              store.transactions.isEmpty else { return }
        try store.seedInventory(try seeds(from: list), sourceLocationID: link.locationID)
    }

    @discardableResult
    static func synchronizeImportedList(_ list: CardList, context: ModelContext,
        store: ShowBudgetStore = .shared) throws -> ShowInventoryReconciliationSummary {
        guard !context.hasChanges else { throw ShowTransactionListFailure.unsavedChanges }
        guard let source = try CardShowInventoryService.importedList(context: context),
              source.id == list.id, source.inventorySourceData == list.inventorySourceData,
              let link = source.cardShowInventory else { throw ShowTransactionListFailure.sourceChanged }
        // A write may have completed before its caller reported a failure.
        // Reopen the durable book before deciding whether a marker is new.
        store.reload()
        guard store.isLoaded else { throw ShowBudgetStoreFailure.notLoaded }
        let rows = try seeds(from: source)
        guard link.version == 2, let marker = link.inventorySnapshotID else {
            return try unchangedSummary(store)
        }
        guard store.inventorySourceLocationID.map({ $0 == link.locationID }) ?? true else {
            throw ShowTransactionFailure.inventoryLocationConflict
        }
        let markerWasApplied = store.inventoryReconciliations.contains { $0.snapshotID == marker }
        if link.pendingWorkingSync != true {
            // Acknowledged source rows are historical. A known marker may be
            // checked through core deduplication, but never applied as fresh.
            guard markerWasApplied else {
                return try unchangedSummary(store)
            }
            return try store.reconcileInventory(rows, sourceLocationID: link.locationID, snapshotID: marker)
        }
        // A source saved before its first ledger write must not overwrite a
        // local sale/cost edit made before retry. Already committed markers
        // ignore this revision so a later sale cannot block acknowledgment.
        if !markerWasApplied, let expected = link.workingRevision,
           expected != ShowInventorySyncRevision(store: store) {
            throw ShowTransactionListFailure.inventoryRefreshRequired
        }
        let summary = try store.reconcileInventory(rows, sourceLocationID: link.locationID, snapshotID: marker)
        try CardShowInventoryService.acknowledgeWorkingSync(list: source,
            expectedSnapshotID: marker, context: context)
        return summary
    }

    private static func seeds(from list: CardList) throws -> [ShowInventorySeed] {
        guard list.cards.count <= ShowBudgetBook.maximumInventorySeeds else { throw ShowBudgetFailure.capacityExceeded }
        var rowIDs = Set<UUID>()
        let seeds = try list.orderedCards.map { row -> ShowInventorySeed in
            guard rowIDs.insert(row.id).inserted, row.list?.id == list.id,
                  let id = row.sourceInventoryID, id > 0,
                  let card = try? JSONDecoder().decode(CardCandidate.self, from: row.data),
                  (0...ShowBudgetBook.maximumQuantity).contains(row.quantity),
                  ShowTransactionMath.validCard(card) else { throw ShowTransactionListFailure.invalidCards }
            return ShowInventorySeed(sourceInventoryID: id, card: card, quantity: row.quantity)
        }
        try ShowInventoryReconciliationMath.validate(seeds)
        return seeds
    }

    private static func unchangedSummary(_ store: ShowBudgetStore) throws -> ShowInventoryReconciliationSummary {
        .init(addedQuantity: 0, removedQuantity: 0, unchangedSnapshot: true,
            totalQuantity: try ShowInventoryReconciliationMath.totalQuantity(store.inventory))
    }
}
