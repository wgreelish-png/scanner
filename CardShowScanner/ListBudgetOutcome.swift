import Foundation
import SwiftData

enum ListBudgetOutcomeFailure: LocalizedError, Equatable {
    case invalidAmount, partialValuation, missingTradePrice, unsavedChanges, listUnavailable, manualReceiptExists, noApplicableShowForReplacement, differentShowReplacement
    var errorDescription: String? {
        switch self {
        case .invalidAmount: return "The calculated cash amount is invalid. Review the prices and offer percentages before recording this outcome."
        case .partialValuation: return "Some cards have no price. Set their prices before automatically recording cash in the show budget."
        case .missingTradePrice: return "Enter My Card Price and calculate Trade + Cash before recording Trade + Purchase."
        case .unsavedChanges: return "Finish or cancel the current edits before updating this list’s outcome and budget."
        case .listUnavailable: return "This list is no longer available. Reopen it before recording an outcome."
        case .manualReceiptExists: return "Cash for this list was already recorded manually. Review that receipt in Show Details before adding automatic cash."
        case .differentShowReplacement: return "Cash for this list belongs to another show. Clear or correct that receipt deliberately before recording it against the selected show."
        case .noApplicableShowForReplacement: return "No show budget applies today. The previous cash receipt is kept; choose an applicable show before replacing it."
        }
    }
}

struct ListBudgetOutcomeResult: Sendable {
    let message: String?
    let isPending: Bool
}

/// Latest durable command for one list. Money and this command commit together
/// in the budget file; SwiftData is a recoverable projection of desiredOutcomeData.
struct BudgetListOutcomeUpdate: Codable, Equatable, Identifiable, Sendable {
    enum Disposition: String, Codable, Sendable { case applied, noCash, noApplicableShow, manualCashPreserved }
    let id: UUID
    let listID: UUID
    let desiredOutcomeData: Data?
    let calculatedPaidCents: Int64
    let calculatedReceivedCents: Int64
    let createdAt: Date
    let showID: UUID?
    let entryID: UUID?
    let disposition: Disposition
    var mirrored: Bool

    var outcomeKind: ListOutcomeKind? {
        desiredOutcomeData.flatMap { try? JSONDecoder().decode(ListOutcomeRecord.self, from: $0).kind }
    }
    var hasCash: Bool { calculatedPaidCents > 0 || calculatedReceivedCents > 0 }
    var message: String? {
        switch disposition {
        case .applied, .noCash: return nil
        case .noApplicableShow: return "Outcome saved. No show budget applies today, so no funds changed."
        case .manualCashPreserved: return "Outcome saved. Existing manual cash receipts remain in Show Details."
        }
    }
    func validate() throws {
        guard createdAt.timeIntervalSince1970.isFinite,
              ShowBudgetMoney.isValid(calculatedPaidCents), ShowBudgetMoney.isValid(calculatedReceivedCents),
              !(calculatedPaidCents > 0 && calculatedReceivedCents > 0), (showID == nil) == (entryID == nil) else {
            throw ShowBudgetFailure.invalidBook
        }
        if let data = desiredOutcomeData {
            guard data.count <= 4096 else { throw ShowBudgetFailure.invalidBook }
            let record = try JSONDecoder().decode(ListOutcomeRecord.self, from: data)
            guard record.recordedAt == createdAt else { throw ShowBudgetFailure.invalidBook }
        }
        switch outcomeKind {
        case .purchase?: guard calculatedReceivedCents == 0 else { throw ShowBudgetFailure.invalidBook }
        case .tradeAndPurchase?: break
        case .trade?, .nothingHappened?, nil: guard !hasCash else { throw ShowBudgetFailure.invalidBook }
        }
        switch disposition {
        case .applied:
            if hasCash { guard entryID == id else { throw ShowBudgetFailure.invalidBook } }
            else { guard entryID == nil else { throw ShowBudgetFailure.invalidBook } }
        case .noApplicableShow: guard hasCash, entryID == nil else { throw ShowBudgetFailure.invalidBook }
        case .noCash, .manualCashPreserved: guard !hasCash, entryID == nil else { throw ShowBudgetFailure.invalidBook }
        }
    }
}

struct ListBudgetOutcomeRequest {
    let listID: UUID
    let listName: String
    let kind: ListOutcomeKind?
    let paidCents: Int64
    let receivedCents: Int64
    let recordedAt: Date
    let desiredOutcomeData: Data?
    var hasCash: Bool { paidCents > 0 || receivedCents > 0 }
}

@MainActor enum ListBudgetOutcomeService {
    typealias Save = @MainActor (ModelContext) throws -> Void

    /// Recording the outcome is explicit authorization to post its calculated
    /// cash. Reconciliation only mirrors an already committed command.
    static func record(_ kind: ListOutcomeKind?, totals: OfferTotals, transaction: TradeTransactionResult?,
                       for list: CardList, context: ModelContext, store: ShowBudgetStore? = nil,
                       save: Save? = nil) throws -> ListBudgetOutcomeResult {
        let store = store ?? .shared
        guard !context.hasChanges else { throw ListBudgetOutcomeFailure.unsavedChanges }
        let listID = list.id
        guard let current = try context.fetch(FetchDescriptor<CardList>(predicate: #Predicate { $0.id == listID })).first,
              current.persistentModelID == list.persistentModelID else { throw ListBudgetOutcomeFailure.listUnavailable }
        let previous = try synchronizePending(context: context, store: store, save: save)
        if previous.isPending { return previous }
        let amounts = try amounts(kind: kind, totals: totals, transaction: transaction)
        let recordedAt = store.currentDate
        let data = try kind.map { try JSONEncoder().encode(ListOutcomeRecord(kind: $0, recordedAt: recordedAt)) }
        let update = try store.applyListOutcome(.init(listID: list.id, listName: list.name, kind: kind,
            paidCents: amounts.paid, receivedCents: amounts.received, recordedAt: recordedAt, desiredOutcomeData: data))
        let synced = try synchronizePending(context: context, store: store, save: save)
        return .init(message: synced.isPending ? synced.message : update.message, isPending: synced.isPending)
    }

    /// No new cash is posted here, even if a show has since ended. A deleted
    /// list is never recreated; its historical financial receipt remains.
    @discardableResult static func synchronizePending(context: ModelContext, store: ShowBudgetStore? = nil,
                                                       save: Save? = nil) throws -> ListBudgetOutcomeResult {
        let store = store ?? .shared
        guard store.isLoaded else { throw ShowBudgetStoreFailure.notLoaded }
        guard !context.hasChanges else { throw ListBudgetOutcomeFailure.unsavedChanges }
        let pending = (store.book.listOutcomeUpdates ?? []).filter { !$0.mirrored }
        for update in pending {
            do {
                let id = update.listID
                if let list = try context.fetch(FetchDescriptor<CardList>(predicate: #Predicate { $0.id == id })).first,
                   list.transactionOutcomeData != update.desiredOutcomeData {
                    let previous = list.transactionOutcomeData
                    list.transactionOutcomeData = update.desiredOutcomeData
                    do {
                        if let save { try save(context) } else { try context.save() }
                    } catch {
                        // The context was clean on entry and this synchronous
                        // operation staged only its outcome projection.
                        context.rollback()
                        if list.transactionOutcomeData != previous { list.transactionOutcomeData = previous }
                        context.processPendingChanges()
                        if context.hasChanges { context.rollback() }
                        throw error
                    }
                }
                try store.acknowledgeListOutcome(update.id)
            } catch {
                DiagnosticLog.shared.record("list.outcome_budget_pending", ["phase": "projection"])
                return .init(message: "The budget update is recorded. The list outcome is still syncing; retry or reopen the list to finish.", isPending: true)
            }
        }
        return .init(message: nil, isPending: false)
    }

    private static func amounts(kind: ListOutcomeKind?, totals: OfferTotals,
                                transaction: TradeTransactionResult?) throws -> (paid: Int64, received: Int64) {
        guard totals.quantity >= 0, totals.unpricedQuantity >= 0, totals.unpricedQuantity <= totals.quantity else {
            throw ListBudgetOutcomeFailure.invalidAmount
        }
        guard kind == .purchase || kind == .tradeAndPurchase else { return (0, 0) }
        guard totals.unpricedQuantity == 0 else { throw ListBudgetOutcomeFailure.partialValuation }
        // Empty saved lists still support status labels without inventing cash.
        if totals.quantity == 0 { return (0, 0) }
        if kind == .purchase { return (try cents(totals.cash), 0) }
        guard let transaction, transaction.mode == .tradeAndCash, !transaction.isPartial,
              let expected = try? TradeTransactionCalculator.calculate(totals: totals, input: transaction.input),
              transaction == expected else {
            throw ListBudgetOutcomeFailure.missingTradePrice
        }
        return (try cents(transaction.cashPayout), try cents(transaction.customerPays))
    }

    private static func cents(_ amount: Decimal) throws -> Int64 {
        guard CustomOfferAmount.isValid(amount) else { throw ListBudgetOutcomeFailure.invalidAmount }
        let scaled = amount * 100, value = NSDecimalNumber(decimal: amount * 100).int64Value
        guard ShowBudgetMoney.isValid(value), Decimal(value) == scaled else { throw ListBudgetOutcomeFailure.invalidAmount }
        return value
    }
}
