import Foundation
import SwiftData

enum ShowTransactionListFailure: LocalizedError, Equatable {
    case unsavedChanges, listUnavailable, sourceChanged, invalidCards, invalidOffer, alreadyRecorded
    var errorDescription: String? {
        switch self {
        case .unsavedChanges: return "Finish or cancel your card edits before recording a transaction."
        case .listUnavailable: return "This scanned list is no longer available. Select it again before recording."
        case .sourceChanged: return "The scanned list changed while you were reviewing this deal. Select it again to review the current cards."
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

    /// A partial price total is not silently used as the whole agreed amount.
    /// The form may accept an explicitly entered amount for an unpriced lot.
    static func defaultIncomingValue(for list: CardList, kind: ShowTransactionKind,
                                     context: ModelContext) throws -> Int64? {
        _ = try incomingCards(for: list)
        let sessions = try context.fetch(FetchDescriptor<ScanSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))
        let rates = sessions.first { $0.listID == list.id }?.rates ?? SessionService.defaults()
        guard rates.isValid else { throw ShowTransactionListFailure.invalidOffer }
        for item in list.cards {
            for raw in [item.cashOverrideText, item.tradeOverrideText] {
                if let raw, CustomOfferAmount.parse(raw) == nil { throw ShowTransactionListFailure.invalidOffer }
            }
        }
        let totals = OfferCalculator.calculate(list.cards.map(\.offerLine), rates: rates)
        guard totals.unpricedQuantity == 0 else { return nil }
        let value = kind == .purchase ? totals.cash : totals.trade
        let scaled = value * 100
        let cents = NSDecimalNumber(decimal: scaled).int64Value
        guard !value.isNaN, ShowBudgetMoney.isValid(cents), Decimal(cents) == scaled else {
            throw ShowTransactionListFailure.invalidOffer
        }
        return cents
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
            guard try incomingCards(for: list) == draft.incoming, list.name == draft.incomingListName else {
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

/// Only the initial source copy seeds working stock. Later source refreshes and
/// removal of that snapshot cannot undo a local sale or discard a local purchase.
@MainActor enum ShowInventoryBridge {
    static func seedFromImportedList(context: ModelContext, store: ShowBudgetStore = .shared) throws {
        guard store.isLoaded else { throw ShowBudgetStoreFailure.notLoaded }
        guard store.inventorySourceLocationID == nil else { return }
        guard !context.hasChanges else { throw ShowTransactionListFailure.unsavedChanges }
        guard let list = try CardShowInventoryService.importedList(context: context),
              let link = list.cardShowInventory else { return }
        let seeds = try list.orderedCards.map { row -> ShowInventorySeed in
            guard let id = row.sourceInventoryID, id > 0,
                  let card = try? JSONDecoder().decode(CardCandidate.self, from: row.data),
                  (0...1_000_000).contains(row.quantity) else { throw ShowTransactionListFailure.invalidCards }
            return ShowInventorySeed(sourceInventoryID: id, card: card, quantity: row.quantity)
        }
        try store.seedInventory(seeds, sourceLocationID: link.locationID)
    }
}
