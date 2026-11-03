import Foundation

struct ShowSaleAllocation: Equatable, Identifiable, Sendable {
    let inventoryID: UUID
    let quantity: Int
    let receivedCents: Int64
    var id: UUID { inventoryID }
}

/// Derived from immutable card references and the actual receipt total. Default
/// tags round each copy to a dollar; negotiated totals use one market percentage.
enum ShowSaleMath {
    static func suggestedTotal(_ lines: [ShowTransactionCardLine]) -> Int64? {
        guard !lines.isEmpty else { return nil }
        var total: Int64 = 0
        for line in lines {
            guard line.quantity > 0, let price = line.card.marketPrice, !price.isNaN, price >= 0 else { return nil }
            var raw = price, rounded = Decimal.zero
            NSDecimalRound(&rounded, &raw, 0, .plain)
            let value = rounded * Decimal(line.quantity) * 100
            guard !value.isNaN, value <= Decimal(ShowBudgetMoney.maximumCents) else { return nil }
            let cents = NSDecimalNumber(decimal: value).int64Value
            let sum = total.addingReportingOverflow(cents)
            guard ShowBudgetMoney.isValid(cents), !sum.overflow, ShowBudgetMoney.isValid(sum.partialValue) else { return nil }
            total = sum.partialValue
        }
        return total
    }

    static func marketTotal(_ lines: [ShowTransactionCardLine]) -> Decimal? {
        guard !lines.isEmpty else { return nil }
        var total = Decimal.zero
        for line in lines {
            guard line.quantity > 0, let price = line.card.marketPrice, !price.isNaN, price >= 0 else { return nil }
            total += price * Decimal(line.quantity)
            guard !total.isNaN else { return nil }
        }
        return total
    }

    static func marketPercentage(_ lines: [ShowTransactionCardLine], receivedCents: Int64) -> Decimal? {
        guard ShowBudgetMoney.isValid(receivedCents), let market = marketTotal(lines), market > 0 else { return nil }
        let percentage = ShowBudgetMoney.decimal(receivedCents) / market * 100
        return percentage.isNaN ? nil : percentage
    }

    static func allocations(_ lines: [ShowTransactionCardLine], receivedCents: Int64) -> [ShowSaleAllocation]? {
        guard ShowBudgetMoney.isValid(receivedCents), Set(lines.map(\.inventoryID)).count == lines.count,
              let market = marketTotal(lines) else { return nil }
        if suggestedTotal(lines) == receivedCents {
            var result: [ShowSaleAllocation] = []
            for line in lines {
                guard let value = suggestedTotal([line]) else { return nil }
                result.append(ShowSaleAllocation(inventoryID: line.inventoryID, quantity: line.quantity, receivedCents: value))
            }
            return result
        }
        guard market > 0 else { return nil }
        var cents: [Int64] = [], fractions: [Decimal] = []
        var allocated: Int64 = 0
        for line in lines {
            guard let price = line.card.marketPrice else { return nil }
            let exact = Decimal(receivedCents) * price * Decimal(line.quantity) / market
            guard !exact.isNaN, exact >= 0, exact <= Decimal(receivedCents) else { return nil }
            var raw = exact, floor = Decimal.zero
            NSDecimalRound(&floor, &raw, 0, .down)
            let value = NSDecimalNumber(decimal: floor).int64Value
            cents.append(value); fractions.append(exact - floor); allocated += value
        }
        let remainder = receivedCents - allocated
        guard remainder >= 0, remainder <= Int64(lines.count) else { return nil }
        let order = lines.indices.sorted {
            fractions[$0] == fractions[$1]
                ? lines[$0].inventoryID.uuidString < lines[$1].inventoryID.uuidString
                : fractions[$0] > fractions[$1]
        }
        for index in order.prefix(Int(remainder)) { cents[index] += 1 }
        return lines.indices.map { ShowSaleAllocation(inventoryID: lines[$0].inventoryID,
            quantity: lines[$0].quantity, receivedCents: cents[$0]) }
    }
}

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
    case invalidCost, costAllocationRequired, inventoryReconciled

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
        case .invalidCost: return "Enter a valid total cost for the remaining copies. Sold receipts keep their recorded cost."
        case .costAllocationRequired: return "Review the incoming card costs. Entered costs must fit the actual total, and remaining cards need usable allocation weights."
        case .inventoryReconciled: return "A later website import changed this card’s stock. No inventory or cash was reversed. Review the current inventory and this transaction’s receipt."
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
    /// Import-created copies have unknown acquisition cost and their own audit origin.
    var acquiredByReconciliationID: UUID?
    var acquiredAt: Date
    /// Total actual cost of the copies still in this lot. Nil means unknown.
    var remainingCostCents: Int64?

    init(id: UUID = UUID(), card: CardCandidate, quantity: Int, sourceInventoryID: Int? = nil,
         sourceLocationID: Int? = nil, acquiredByTransactionID: UUID? = nil, acquiredAt: Date = Date(),
         remainingCostCents: Int64? = nil, acquiredByReconciliationID: UUID? = nil) {
        self.id = id; self.card = card; self.quantity = quantity; self.sourceInventoryID = sourceInventoryID
        self.sourceLocationID = sourceLocationID; self.acquiredByTransactionID = acquiredByTransactionID
        self.acquiredAt = acquiredAt
        self.remainingCostCents = remainingCostCents
        self.acquiredByReconciliationID = acquiredByReconciliationID
    }
}

struct ShowInventorySeed: Codable, Equatable, Sendable {
    var sourceInventoryID: Int
    var card: CardCandidate
    var quantity: Int
}

struct ShowIncomingCard: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var card: CardCandidate
    var quantity: Int
    /// Row total from the actual cash/trade offer, including per-card overrides.
    var costWeightCents: Int64?
    /// An explicitly reviewed total cost for this row, rather than a weight.
    var allocatedCostCents: Int64?
    init(id: UUID = UUID(), card: CardCandidate, quantity: Int = 1,
         costWeightCents: Int64? = nil, allocatedCostCents: Int64? = nil) {
        self.id = id; self.card = card; self.quantity = quantity
        self.costWeightCents = costWeightCents; self.allocatedCostCents = allocatedCostCents
    }
}

struct ShowTransactionSelection: Codable, Equatable, Sendable {
    var inventoryID: UUID
    var quantity: Int
    var allocatedProceedsCents: Int64? = nil
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
    var feeCents: Int64

    init(id: UUID = UUID(), kind: ShowTransactionKind, incomingListID: UUID? = nil,
         incomingListName: String? = nil, incoming: [ShowIncomingCard] = [],
         outgoing: [ShowTransactionSelection] = [], incomingValueCents: Int64 = 0,
         outgoingValueCents: Int64 = 0, saleReceivedCents: Int64 = 0,
         makeEven: Bool = false, note: String = "", feeCents: Int64 = 0) {
        self.id = id; self.kind = kind; self.incomingListID = incomingListID
        self.incomingListName = incomingListName; self.incoming = incoming; self.outgoing = outgoing
        self.incomingValueCents = incomingValueCents; self.outgoingValueCents = outgoingValueCents
        self.saleReceivedCents = saleReceivedCents; self.makeEven = makeEven; self.note = note
        self.feeCents = feeCents
    }

    func validate() throws {
        guard incoming.count <= ShowBudgetBook.maximumTransactionCards,
              outgoing.count <= ShowBudgetBook.maximumTransactionCards else { throw ShowBudgetFailure.capacityExceeded }
        guard [incomingValueCents, outgoingValueCents, saleReceivedCents, feeCents].allSatisfy(ShowBudgetMoney.isValid),
              feeCents <= saleReceivedCents, kind == .sale || feeCents == 0,
              note.count <= 1_000,
              Set(incoming.map(\.id)).count == incoming.count,
              Set(outgoing.map(\.inventoryID)).count == outgoing.count,
              incoming.allSatisfy({ (1...ShowBudgetBook.maximumQuantity).contains($0.quantity) && ShowTransactionMath.validCard($0.card) &&
                  ($0.costWeightCents.map(ShowBudgetMoney.isValid) ?? true) && ($0.allocatedCostCents.map(ShowBudgetMoney.isValid) ?? true) }),
              outgoing.allSatisfy({ (1...ShowBudgetBook.maximumQuantity).contains($0.quantity) &&
                  ($0.allocatedProceedsCents.map(ShowBudgetMoney.isValid) ?? true) && (kind == .sale || $0.allocatedProceedsCents == nil) }),
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

    private enum CodingKeys: String, CodingKey {
        case id, kind, incomingListID, incomingListName, incoming, outgoing, incomingValueCents,
             outgoingValueCents, saleReceivedCents, makeEven, note, feeCents
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(ShowTransactionKind.self, forKey: .kind)
        incomingListID = try values.decodeIfPresent(UUID.self, forKey: .incomingListID)
        incomingListName = try values.decodeIfPresent(String.self, forKey: .incomingListName)
        incoming = try values.decode([ShowIncomingCard].self, forKey: .incoming)
        outgoing = try values.decode([ShowTransactionSelection].self, forKey: .outgoing)
        incomingValueCents = try values.decode(Int64.self, forKey: .incomingValueCents)
        outgoingValueCents = try values.decode(Int64.self, forKey: .outgoingValueCents)
        saleReceivedCents = try values.decode(Int64.self, forKey: .saleReceivedCents)
        makeEven = try values.decode(Bool.self, forKey: .makeEven)
        note = try values.decode(String.self, forKey: .note)
        feeCents = try values.decodeIfPresent(Int64.self, forKey: .feeCents) ?? 0
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
    /// Nil on historical receipts: current inventory costs never backfill history.
    var accounting: ShowTransactionAccounting? = nil

    var totalCostCents: Int64? { accounting?.totalCostCents }
    var feeCents: Int64 { accounting?.feeCents ?? draft.feeCents }
    var profitCents: Int64? { accounting?.profitCents }

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
        if let accounting { try accounting.validate(receipt: self, saleReinvestmentPercent: saleReinvestmentPercent) }
        else if draft.feeCents != 0 { throw ShowBudgetFailure.invalidBook }
    }
}

struct ShowCostLineAccounting: Codable, Equatable, Identifiable, Sendable {
    let inventoryID: UUID
    let quantity: Int
    let totalCostCents: Int64?
    let proceedsCents: Int64?
    let feeCents: Int64?
    let profitCents: Int64?
    var id: UUID { inventoryID }

    func replacingInventoryID(_ id: UUID) -> Self {
        .init(inventoryID: id, quantity: quantity, totalCostCents: totalCostCents,
              proceedsCents: proceedsCents, feeCents: feeCents, profitCents: profitCents)
    }
}

/// Recorded numbers are independent of future prices and remaining-stock edits.
struct ShowTransactionAccounting: Codable, Equatable, Sendable {
    enum Policy: String, Codable, Sendable { case carryForwardV1 }
    let policy: Policy
    let totalCostCents: Int64?
    let feeCents: Int64
    let profitCents: Int64?
    let proceedsCents: Int64?
    let buyingFundsDeltaCents: Int64
    var incoming: [ShowCostLineAccounting]
    let outgoing: [ShowCostLineAccounting]

    func validate(receipt: ShowTransactionReceipt, saleReinvestmentPercent: Int) throws {
        guard incoming.count == receipt.incoming.count, outgoing.count == receipt.outgoing.count else {
            throw ShowBudgetFailure.invalidBook
        }
        // Recompute from the immutable consumed costs, never today's lot costs.
        let stock = zip(receipt.outgoing, outgoing).map { line, cost in
            ShowInventoryItem(id: line.inventoryID, card: line.card, quantity: line.quantity,
                              remainingCostCents: cost.totalCostCents)
        }
        var expected = try ShowTransactionMath.preview(receipt.draft, inventory: stock,
            saleReinvestmentPercent: saleReinvestmentPercent)
        expected.incoming = zip(expected.incoming, receipt.incoming).map { cost, line in cost.replacingInventoryID(line.inventoryID) }
        guard self == expected else { throw ShowBudgetFailure.invalidBook }
    }
}

struct ShowInventoryCostAdjustment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let inventoryID: UUID
    let quantity: Int
    let previousCostCents: Int64?
    let totalCostCents: Int64?
    let recordedAt: Date

    func validate() throws {
        guard (1...ShowBudgetBook.maximumQuantity).contains(quantity),
              previousCostCents.map(ShowBudgetMoney.isValid) ?? true,
              totalCostCents.map(ShowBudgetMoney.isValid) ?? true,
              previousCostCents != totalCostCents, recordedAt.timeIntervalSince1970.isFinite else {
            throw ShowTransactionFailure.invalidCost
        }
    }
}

struct ShowProfitSummary: Equatable, Sendable {
    let salesCents: Int64
    let sellingFeesCents: Int64
    let soldCostCents: Int64
    /// Includes known sale profits and realized trade cash profits.
    let knownProfitCents: Int64
    let tradeCashProfitCents: Int64
    let unknownCostQuantity: Int
    let unknownCostLineCount: Int
    let uncostedSaleCount: Int
    let incompleteTransactionCount: Int
    var uncostedTradeCount: Int = 0
    var isComplete: Bool { incompleteTransactionCount == 0 && uncostedSaleCount == 0 && uncostedTradeCount == 0 }
}

extension ShowTransactionMath {
    static func preview(_ draft: ShowTransactionDraft, inventory: [ShowInventoryItem],
                        saleReinvestmentPercent: Int = 65) throws -> ShowTransactionAccounting {
        let amounts = try calculate(draft, saleReinvestmentPercent: saleReinvestmentPercent)
        guard Set(inventory.map(\.id)).count == inventory.count else { throw ShowTransactionFailure.invalidInventory }
        let byID = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        var outgoingCards: [ShowTransactionCardLine] = []
        var costs: [Int64?] = []
        for row in draft.outgoing {
            guard let item = byID[row.inventoryID], item.quantity >= row.quantity else {
                throw ShowTransactionFailure.insufficientStock
            }
            costs.append(try ShowCostBasisMath.consumedCost(totalCostCents: item.remainingCostCents,
                quantity: item.quantity, consumedQuantity: row.quantity))
            outgoingCards.append(.init(inventoryID: item.id, card: item.card, quantity: row.quantity))
        }
        let outgoingCost = try sumKnown(costs)
        let incomingCost: Int64?
        let profit: Int64?
        if draft.kind == .purchase {
            incomingCost = amounts.paidCents; profit = nil
        } else if draft.kind == .sale {
            incomingCost = nil
            profit = outgoingCost.map { amounts.receivedCents - draft.feeCents - $0 }
        } else {
            let trade = try ShowCostBasisMath.carriedTradeCost(outgoingCostCents: outgoingCost,
                paidCents: amounts.paidCents, receivedCents: amounts.receivedCents)
            incomingCost = trade.incomingCostCents; profit = trade.profitCents
        }
        let incomingCosts = draft.incoming.isEmpty ? [] : try ShowCostBasisMath.incomingCosts(draft.incoming, totalCostCents: incomingCost)
        let incoming = zip(draft.incoming, incomingCosts).map { row, cost in
            ShowCostLineAccounting(inventoryID: row.id, quantity: row.quantity, totalCostCents: cost,
                                  proceedsCents: nil, feeCents: nil, profitCents: nil)
        }
        var proceeds: [Int64]? = nil, fees: [Int64]? = nil
        if draft.kind == .sale {
            if draft.outgoing.contains(where: { $0.allocatedProceedsCents != nil }) {
                guard draft.outgoing.allSatisfy({ $0.allocatedProceedsCents != nil }),
                      try sumKnown(draft.outgoing.map(\.allocatedProceedsCents)) == amounts.receivedCents else {
                    throw ShowTransactionFailure.invalidDraft
                }
                proceeds = draft.outgoing.compactMap(\.allocatedProceedsCents)
            } else if outgoingCards.count == 1 { proceeds = [amounts.receivedCents] }
            else if amounts.receivedCents == 0 { proceeds = outgoingCards.map { _ in 0 } }
            else { proceeds = ShowSaleMath.allocations(outgoingCards, receivedCents: amounts.receivedCents)?.map(\.receivedCents) }
            if let proceeds {
                fees = try ShowCostBasisMath.allocate(totalCents: draft.feeCents,
                    ids: outgoingCards.map(\.inventoryID), weights: proceeds.map { Decimal($0) })
            } else if draft.feeCents == 0 {
                fees = outgoingCards.map { _ in 0 }
            }
        }
        let outgoing = draft.outgoing.indices.map { index in
            let received = proceeds?[index], fee = fees?[index], cost = costs[index]
            let lineProfit: Int64?
            if let received, let fee, let cost { lineProfit = received - fee - cost }
            else { lineProfit = nil }
            return ShowCostLineAccounting(inventoryID: draft.outgoing[index].inventoryID,
                quantity: draft.outgoing[index].quantity, totalCostCents: cost,
                proceedsCents: received, feeCents: fee, profitCents: lineProfit)
        }
        return ShowTransactionAccounting(policy: .carryForwardV1,
            totalCostCents: draft.kind == .purchase ? incomingCost : outgoingCost,
            feeCents: draft.feeCents, profitCents: profit,
            proceedsCents: draft.kind == .purchase ? nil : amounts.receivedCents,
            buyingFundsDeltaCents: amounts.reinvestedCents - amounts.paidCents - draft.feeCents,
            incoming: incoming, outgoing: outgoing)
    }

    private static func sumKnown(_ values: [Int64?]) throws -> Int64? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        var total: Int64 = 0
        for case let value? in values {
            guard ShowBudgetMoney.isValid(value) else { throw ShowTransactionFailure.invalidCost }
            let result = total.addingReportingOverflow(value)
            guard !result.overflow, ShowBudgetMoney.isValid(result.partialValue) else { throw ShowBudgetFailure.arithmeticOverflow }
            total = result.partialValue
        }
        return total
    }
}

struct ShowCostStockState: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let quantity: Int
    let remainingCostCents: Int64?

    init(_ item: ShowInventoryItem) {
        id = item.id; quantity = item.quantity; remainingCostCents = item.remainingCostCents
    }
    init(id: UUID, quantity: Int, remainingCostCents: Int64?) {
        self.id = id; self.quantity = quantity; self.remainingCostCents = remainingCostCents
    }
    func validate() throws {
        guard (0...ShowBudgetBook.maximumQuantity).contains(quantity),
              remainingCostCents.map(ShowBudgetMoney.isValid) ?? true,
              quantity != 0 || remainingCostCents == nil || remainingCostCents == 0 else {
            throw ShowTransactionFailure.invalidInventory
        }
    }
}

struct ShowCostStockChange: Codable, Equatable, Sendable {
    let before: ShowCostStockState?
    let after: ShowCostStockState
}

/// Each stock/cost command has one checked before/after mutation. This allows
/// validation of consumed costs against the lot at recording, including edits
/// and out-of-order Undo, without reconstructing historical unknown costs.
struct ShowCostLedgerMutation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case record, undo, adjustment, reconciliation }
    let kind: Kind
    let operationID: UUID
    let recordedAt: Date
    let changes: [ShowCostStockChange]

    static func capturing(kind: Kind, operationID: UUID, recordedAt: Date, itemIDs: [UUID],
                          before: [ShowInventoryItem], after: [ShowInventoryItem]) throws -> Self {
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        let changes = try itemIDs.map { id -> ShowCostStockChange in
            guard let item = new[id] else { throw ShowBudgetFailure.invalidBook }
            return .init(before: old[id].map(ShowCostStockState.init), after: .init(item))
        }
        return .init(kind: kind, operationID: operationID, recordedAt: recordedAt, changes: changes)
    }
}

extension ShowBudgetBook {
    func validateCostLedger() throws {
        let maximumMutations = Self.maximumTransactions * 2 + Self.maximumCostAdjustments + Self.maximumInventoryReconciliations
        guard costLedgerBaseline.count <= Self.maximumInventoryItems, costMutations.count <= maximumMutations else {
            throw ShowBudgetFailure.capacityExceeded
        }
        guard Set(costLedgerBaseline.map(\.id)).count == costLedgerBaseline.count,
              Set(legacyTransactionIDs).count == legacyTransactionIDs.count,
              Set(legacyReversedTransactionIDs).count == legacyReversedTransactionIDs.count else {
            throw ShowBudgetFailure.duplicateIdentity
        }
        let legacy = Set(legacyTransactionIDs), legacyReversed = Set(legacyReversedTransactionIDs)
        let stock = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        let receipts = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        let adjustments = Dictionary(uniqueKeysWithValues: costAdjustments.map { ($0.id, $0) })
        let reconciliations = Dictionary(uniqueKeysWithValues: inventoryReconciliations.map { ($0.id, $0) })
        let reinvestmentPercents = Dictionary(uniqueKeysWithValues: shows.flatMap(\.entries).compactMap { entry in
            entry.transactionID.map { ($0, entry.reinvestmentPercent) }
        })
        guard legacy.isSubset(of: Set(receipts.keys)), legacyReversed.isSubset(of: legacy),
              legacyReversed.allSatisfy({ receipts[$0]?.reversedAt != nil }) else { throw ShowBudgetFailure.invalidBook }
        for receipt in transactions {
            guard (receipt.accounting == nil) == legacy.contains(receipt.id) else { throw ShowBudgetFailure.invalidBook }
        }
        var states: [UUID: ShowCostStockState] = [:]
        for state in costLedgerBaseline {
            try state.validate()
            guard let item = stock[state.id], state.remainingCostCents == nil,
                  item.acquiredByReconciliationID == nil,
                  item.acquiredByTransactionID.map({ legacy.contains($0) }) ?? true else { throw ShowBudgetFailure.invalidBook }
            states[state.id] = state
        }
        let baselineIDs = Set(costLedgerBaseline.map(\.id))
        guard inventory.allSatisfy({ item in
            let needsBaseline = item.acquiredByReconciliationID == nil &&
                (item.acquiredByTransactionID.map({ legacy.contains($0) }) ?? true)
            return baselineIDs.contains(item.id) == needsBaseline
        }) else { throw ShowBudgetFailure.invalidBook }
        var recorded = Set<UUID>(), undone = Set<UUID>(), adjusted = Set<UUID>()
        var reconciled = Set<UUID>(), reconciliationOrder: [UUID] = []
        var recordPositions = Dictionary(uniqueKeysWithValues: legacy.map { ($0, -1) })
        var lastReconciliationPositions: [CardIdentity: Int] = [:]
        var activeReceipts = legacy.subtracting(legacyReversed)
        for (mutationIndex, mutation) in costMutations.enumerated() {
            let maximumChanges = mutation.kind == .reconciliation ? Self.maximumInventoryItems : Self.maximumTransactionCards * 2
            guard mutation.recordedAt.timeIntervalSince1970.isFinite,
                  mutation.changes.count <= maximumChanges,
                  Set(mutation.changes.map { $0.after.id }).count == mutation.changes.count else {
                throw ShowBudgetFailure.invalidBook
            }
            for change in mutation.changes {
                try change.after.validate()
                if let before = change.before { try before.validate() }
                guard change.before?.id == nil || change.before?.id == change.after.id,
                      states[change.after.id] == change.before else { throw ShowBudgetFailure.invalidBook }
            }
            let expected: [ShowCostStockChange]
            switch mutation.kind {
            case .record:
                guard !legacy.contains(mutation.operationID), recorded.insert(mutation.operationID).inserted,
                      let receipt = receipts[mutation.operationID], receipt.recordedAt == mutation.recordedAt,
                      let accounting = receipt.accounting, let reinvestmentPercent = reinvestmentPercents[receipt.id] else {
                    throw ShowBudgetFailure.invalidBook
                }
                // Only inventory that existed at this point can supply a cost.
                let beforeStock = try receipt.outgoing.map { line -> ShowInventoryItem in
                    guard let state = states[line.inventoryID], let item = stock[line.inventoryID] else {
                        throw ShowBudgetFailure.invalidBook
                    }
                    if let acquisition = item.acquiredByTransactionID {
                        guard activeReceipts.contains(acquisition) else { throw ShowBudgetFailure.invalidBook }
                    }
                    return .init(id: item.id, card: item.card, quantity: state.quantity,
                                 remainingCostCents: state.remainingCostCents)
                }
                var calculated = try ShowTransactionMath.preview(receipt.draft, inventory: beforeStock,
                    saleReinvestmentPercent: reinvestmentPercent)
                calculated.incoming = zip(calculated.incoming, receipt.incoming).map { cost, line in
                    cost.replacingInventoryID(line.inventoryID)
                }
                guard accounting == calculated else { throw ShowBudgetFailure.invalidBook }
                var changes: [ShowCostStockChange] = []
                for (line, cost) in zip(receipt.outgoing, accounting.outgoing) {
                    guard let before = states[line.inventoryID] else { throw ShowBudgetFailure.invalidBook }
                    let afterCost = before.remainingCostCents.flatMap { original in cost.totalCostCents.map { original - $0 } }
                    changes.append(.init(before: before, after: .init(id: line.inventoryID,
                        quantity: before.quantity - line.quantity, remainingCostCents: afterCost)))
                }
                for (line, cost) in zip(receipt.incoming, accounting.incoming) {
                    guard states[line.inventoryID] == nil else { throw ShowBudgetFailure.invalidBook }
                    changes.append(.init(before: nil, after: .init(id: line.inventoryID,
                        quantity: line.quantity, remainingCostCents: cost.totalCostCents)))
                }
                expected = changes
                activeReceipts.insert(receipt.id)
                recordPositions[receipt.id] = mutationIndex
            case .undo:
                guard undone.insert(mutation.operationID).inserted, activeReceipts.contains(mutation.operationID),
                      let receipt = receipts[mutation.operationID], receipt.reversedAt == mutation.recordedAt else {
                    throw ShowBudgetFailure.invalidBook
                }
                let affected = receipt.incoming.map { $0.card.identity } + receipt.outgoing.map { $0.card.identity }
                guard let recordedPosition = recordPositions[receipt.id],
                      affected.allSatisfy({ (lastReconciliationPositions[$0] ?? -1) <= recordedPosition }) else {
                    throw ShowBudgetFailure.invalidBook
                }
                var changes: [ShowCostStockChange] = []
                for line in receipt.incoming {
                    guard let before = states[line.inventoryID], before.quantity == line.quantity else {
                        throw ShowBudgetFailure.invalidBook
                    }
                    changes.append(.init(before: before, after: .init(id: line.inventoryID,
                        quantity: 0, remainingCostCents: before.remainingCostCents == nil ? nil : 0)))
                }
                for (index, line) in receipt.outgoing.enumerated() {
                    guard let before = states[line.inventoryID] else { throw ShowBudgetFailure.invalidBook }
                    let quantity = before.quantity.addingReportingOverflow(line.quantity)
                    guard !quantity.overflow, quantity.partialValue <= Self.maximumQuantity else { throw ShowBudgetFailure.invalidBook }
                    var cost: Int64?
                    if let original = before.remainingCostCents, let consumed = receipt.accounting?.outgoing[index].totalCostCents {
                        let sum = original.addingReportingOverflow(consumed)
                        guard !sum.overflow, ShowBudgetMoney.isValid(sum.partialValue) else { throw ShowBudgetFailure.invalidBook }
                        cost = sum.partialValue
                    }
                    changes.append(.init(before: before, after: .init(id: line.inventoryID,
                        quantity: quantity.partialValue, remainingCostCents: cost)))
                }
                expected = changes
                activeReceipts.remove(receipt.id)
            case .adjustment:
                guard adjusted.insert(mutation.operationID).inserted,
                      let adjustment = adjustments[mutation.operationID], adjustment.recordedAt == mutation.recordedAt,
                      let before = states[adjustment.inventoryID], before.quantity == adjustment.quantity,
                      before.remainingCostCents == adjustment.previousCostCents else { throw ShowBudgetFailure.invalidBook }
                expected = [.init(before: before, after: .init(id: adjustment.inventoryID,
                    quantity: before.quantity, remainingCostCents: adjustment.totalCostCents))]
            case .reconciliation:
                guard reconciled.insert(mutation.operationID).inserted,
                      let event = reconciliations[mutation.operationID], event.recordedAt == mutation.recordedAt,
                      event.sourceLocationID == inventorySourceLocationID else { throw ShowBudgetFailure.invalidBook }
                // Only lots that exist at this journal position participate;
                // future purchases/import additions cannot influence the plan.
                let beforeInventory = try states.keys.sorted(by: { $0.uuidString < $1.uuidString }).map { id -> ShowInventoryItem in
                    guard var item = stock[id], let state = states[id] else { throw ShowBudgetFailure.invalidBook }
                    item.quantity = state.quantity; item.remainingCostCents = state.remainingCostCents
                    return item
                }
                let plan = try ShowInventoryReconciliationMath.plan(event, inventory: beforeInventory)
                let planned = Dictionary(uniqueKeysWithValues: plan.inventory.map { ($0.id, $0) })
                for id in event.createdInventoryIDs {
                    guard var durable = stock[id], let initial = planned[id] else { throw ShowBudgetFailure.invalidBook }
                    durable.quantity = initial.quantity; durable.remainingCostCents = initial.remainingCostCents
                    guard durable == initial else { throw ShowBudgetFailure.invalidBook }
                }
                expected = try ShowCostLedgerMutation.capturing(kind: .reconciliation, operationID: event.id,
                    recordedAt: event.recordedAt, itemIDs: plan.changedIDs, before: beforeInventory,
                    after: plan.inventory).changes
                for id in plan.changedIDs {
                    guard let item = planned[id] else { throw ShowBudgetFailure.invalidBook }
                    lastReconciliationPositions[item.card.identity] = mutationIndex
                }
                reconciliationOrder.append(event.id)
            }
            guard mutation.changes == expected else { throw ShowBudgetFailure.invalidBook }
            for change in mutation.changes { states[change.after.id] = change.after }
        }
        let expectedRecorded = Set(transactions.map(\.id)).subtracting(legacy)
        let expectedUndone = Set(transactions.filter { $0.reversedAt != nil }.map(\.id)).subtracting(legacyReversed)
        guard recorded == expectedRecorded, undone == expectedUndone, adjusted == Set(adjustments.keys),
              reconciled == Set(reconciliations.keys), reconciliationOrder == inventoryReconciliations.map(\.id),
              states.count == inventory.count,
              inventory.allSatisfy({ states[$0.id] == ShowCostStockState($0) }) else { throw ShowBudgetFailure.invalidBook }
    }

}
