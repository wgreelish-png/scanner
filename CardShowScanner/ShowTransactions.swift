import Foundation

enum ShowTransactionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case sale, trade, tradePayCustomer, tradeReceiveCash, purchase
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sale: return "Sale"
        case .trade: return "Trade"
        case .tradePayCustomer: return "Trade + Pay Customer"
        case .tradeReceiveCash: return "Trade + Receive Cash"
        case .purchase: return "Purchase"
        }
    }
    var budgetKind: ShowBudgetEntryKind {
        switch self { case .sale: return .sale; case .purchase: return .purchase; default: return .trade }
    }
}

enum ShowTransactionFailure: LocalizedError, Equatable, Sendable {
    case invalidDraft, invalidInventory, insufficientStock, inventoryLocationConflict, transactionNotFound
    case incomingListAlreadyUsed, legacyListOutcomeExists, inventoryLinkedEntry, dependentStockUsed

    var errorDescription: String? {
        switch self {
        case .invalidDraft: return "Review the transaction type, card quantities, values, and cash direction before recording."
        case .invalidInventory: return "The saved show inventory could not be validated. Your saved data has been kept."
        case .insufficientStock: return "Some selected cards are no longer available in that quantity. Review your show inventory."
        case .inventoryLocationConflict: return "Show inventory was already started from another location. Continue using the original location."
        case .transactionNotFound: return "This transaction is no longer available. Reopen Transaction History and retry."
        case .incomingListAlreadyUsed: return "This incoming list already belongs to a recorded transaction. Review or undo it in Transaction History."
        case .legacyListOutcomeExists: return "This list already has a purchase, trade, or cash receipt. Review its existing outcome before recording another transaction."
        case .inventoryLinkedEntry: return "This cash entry also moved cards. Undo the complete transaction in Transaction History."
        case .dependentStockUsed: return "Cards acquired by this transaction were used in a later transaction. Undo those transactions first."
        }
    }
}

struct ShowInventoryItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var card: CardCandidate
    var quantity: Int
    var sourceInventoryID: Int?
    var sourceLocationID: Int?
    var acquiredByTransactionID: UUID?
    var acquiredAt: Date

    init(id: UUID = UUID(), card: CardCandidate, quantity: Int, sourceInventoryID: Int? = nil,
         sourceLocationID: Int? = nil, acquiredByTransactionID: UUID? = nil, acquiredAt: Date = Date()) {
        self.id = id; self.card = card; self.quantity = quantity; self.sourceInventoryID = sourceInventoryID
        self.sourceLocationID = sourceLocationID; self.acquiredByTransactionID = acquiredByTransactionID
        self.acquiredAt = acquiredAt
    }
}

struct ShowInventorySeed: Sendable {
    var sourceInventoryID: Int
    var card: CardCandidate
    var quantity: Int
}

struct ShowIncomingCard: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var card: CardCandidate
    var quantity: Int
    init(id: UUID = UUID(), card: CardCandidate, quantity: Int = 1) {
        self.id = id; self.card = card; self.quantity = quantity
    }
}

struct ShowTransactionSelection: Codable, Equatable, Sendable {
    var inventoryID: UUID
    var quantity: Int
}

struct ShowTransactionDraft: Codable, Equatable, Sendable {
    var id: UUID
    var kind: ShowTransactionKind
    var incomingListID: UUID?
    var incomingListName: String?
    var incoming: [ShowIncomingCard]
    var outgoing: [ShowTransactionSelection]
    var incomingValueCents: Int64
    var outgoingValueCents: Int64
    var saleReceivedCents: Int64
    var makeEven: Bool
    var note: String

    init(id: UUID = UUID(), kind: ShowTransactionKind, incomingListID: UUID? = nil,
         incomingListName: String? = nil, incoming: [ShowIncomingCard] = [],
         outgoing: [ShowTransactionSelection] = [], incomingValueCents: Int64 = 0,
         outgoingValueCents: Int64 = 0, saleReceivedCents: Int64 = 0,
         makeEven: Bool = false, note: String = "") {
        self.id = id; self.kind = kind; self.incomingListID = incomingListID
        self.incomingListName = incomingListName; self.incoming = incoming; self.outgoing = outgoing
        self.incomingValueCents = incomingValueCents; self.outgoingValueCents = outgoingValueCents
        self.saleReceivedCents = saleReceivedCents; self.makeEven = makeEven; self.note = note
    }

    func validate() throws {
        guard incoming.count <= ShowBudgetBook.maximumTransactionCards,
              outgoing.count <= ShowBudgetBook.maximumTransactionCards else { throw ShowBudgetFailure.capacityExceeded }
        guard [incomingValueCents, outgoingValueCents, saleReceivedCents].allSatisfy(ShowBudgetMoney.isValid),
              note.count <= 1_000,
              Set(incoming.map(\.id)).count == incoming.count,
              Set(outgoing.map(\.inventoryID)).count == outgoing.count,
              incoming.allSatisfy({ (1...ShowBudgetBook.maximumQuantity).contains($0.quantity) && ShowTransactionMath.validCard($0.card) }),
              outgoing.allSatisfy({ (1...ShowBudgetBook.maximumQuantity).contains($0.quantity) }),
              incomingListName.map({ incomingListID != nil && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 250 }) ?? true else {
            throw ShowTransactionFailure.invalidDraft
        }
        switch kind {
        case .sale:
            guard incoming.isEmpty, incomingListID == nil, incomingListName == nil,
                  incomingValueCents == 0, !outgoing.isEmpty, !makeEven else { throw ShowTransactionFailure.invalidDraft }
        case .purchase:
            guard !incoming.isEmpty, outgoing.isEmpty, outgoingValueCents == 0,
                  saleReceivedCents == 0, !makeEven else { throw ShowTransactionFailure.invalidDraft }
        case .trade, .tradePayCustomer, .tradeReceiveCash:
            guard !incoming.isEmpty, !outgoing.isEmpty, saleReceivedCents == 0 else { throw ShowTransactionFailure.invalidDraft }
            switch kind {
            case .trade:
                guard makeEven || incomingValueCents == outgoingValueCents else { throw ShowTransactionFailure.invalidDraft }
            case .tradePayCustomer:
                guard !makeEven, incomingValueCents > outgoingValueCents else { throw ShowTransactionFailure.invalidDraft }
            case .tradeReceiveCash:
                guard !makeEven, outgoingValueCents > incomingValueCents else { throw ShowTransactionFailure.invalidDraft }
            default: break
            }
        }
    }
}

struct ShowTransactionAmounts: Equatable, Sendable {
    let paidCents: Int64
    let receivedCents: Int64
    let reinvestedCents: Int64
    let savedCents: Int64
    /// Positive means the seller gave up value to make an uneven trade even.
    let concessionCents: Int64
}

enum ShowTransactionMath {
    static func calculate(_ draft: ShowTransactionDraft, saleReinvestmentPercent: Int = 65) throws -> ShowTransactionAmounts {
        try draft.validate()
        guard (0...100).contains(saleReinvestmentPercent) else { throw ShowTransactionFailure.invalidDraft }
        var paid: Int64 = 0, received: Int64 = 0, reinvested: Int64 = 0, concession: Int64 = 0
        switch draft.kind {
        case .sale:
            received = draft.saleReceivedCents
            let product = received.multipliedReportingOverflow(by: Int64(saleReinvestmentPercent))
            guard !product.overflow else { throw ShowBudgetFailure.arithmeticOverflow }
            let rounded = product.partialValue.addingReportingOverflow(50)
            guard !rounded.overflow else { throw ShowBudgetFailure.arithmeticOverflow }
            reinvested = rounded.partialValue / 100
        case .purchase: paid = draft.incomingValueCents
        case .trade:
            if draft.makeEven { concession = draft.outgoingValueCents - draft.incomingValueCents }
        case .tradePayCustomer: paid = draft.incomingValueCents - draft.outgoingValueCents
        case .tradeReceiveCash:
            received = draft.outgoingValueCents - draft.incomingValueCents
            reinvested = received
        }
        return ShowTransactionAmounts(paidCents: paid, receivedCents: received,
            reinvestedCents: reinvested, savedCents: received - reinvested, concessionCents: concession)
    }

    static func validCard(_ card: CardCandidate) -> Bool {
        let fields = [card.identity.game, card.identity.productID, card.identity.printing, card.identity.language,
                      card.identity.condition, card.name, card.set, card.number]
        return !card.identity.productID.isEmpty && !card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            fields.allSatisfy { $0.count <= 2_000 } && card.confidence.isFinite &&
            (card.marketPrice.map { !$0.isNaN && $0 >= 0 } ?? true) && card.printings.count <= 100 &&
            card.printings.allSatisfy { $0.count <= 2_000 } && (card.printingQuotes?.count ?? 0) <= 100
    }
}

struct ShowTransactionCardLine: Codable, Equatable, Sendable {
    var inventoryID: UUID
    var card: CardCandidate
    var quantity: Int
}

struct ShowTransactionReceipt: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var showID: UUID
    var showName: String
    var kind: ShowTransactionKind
    var recordedAt: Date
    var incomingListID: UUID?
    var incomingListName: String?
    var incoming: [ShowTransactionCardLine]
    var outgoing: [ShowTransactionCardLine]
    var incomingValueCents: Int64
    var outgoingValueCents: Int64
    var paidCents: Int64
    var receivedCents: Int64
    var reinvestedCents: Int64
    var savedCents: Int64
    var concessionCents: Int64
    var reversedAt: Date?
    var draft: ShowTransactionDraft

    func validate(saleReinvestmentPercent: Int) throws {
        let amounts = try ShowTransactionMath.calculate(draft, saleReinvestmentPercent: saleReinvestmentPercent)
        guard id == draft.id, kind == draft.kind, recordedAt.timeIntervalSince1970.isFinite,
              reversedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= recordedAt }) ?? true,
              !showName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, showName.count <= 120,
              incomingListID == draft.incomingListID, incomingListName == draft.incomingListName,
              incomingValueCents == draft.incomingValueCents, outgoingValueCents == draft.outgoingValueCents,
              paidCents == amounts.paidCents, receivedCents == amounts.receivedCents,
              reinvestedCents == amounts.reinvestedCents, savedCents == amounts.savedCents,
              concessionCents == amounts.concessionCents, incoming.count == draft.incoming.count,
              outgoing.count == draft.outgoing.count,
              Set(incoming.map(\.inventoryID)).count == incoming.count,
              Set(outgoing.map(\.inventoryID)).count == outgoing.count else { throw ShowBudgetFailure.invalidBook }
        for (line, original) in zip(incoming, draft.incoming) {
            guard line.card == original.card, line.quantity == original.quantity else { throw ShowBudgetFailure.invalidBook }
        }
        for (line, original) in zip(outgoing, draft.outgoing) {
            guard line.inventoryID == original.inventoryID, line.quantity == original.quantity,
                  ShowTransactionMath.validCard(line.card) else { throw ShowBudgetFailure.invalidBook }
        }
    }
}
