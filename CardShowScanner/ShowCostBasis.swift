import Foundation

/// Integer-cent cost accounting. Market prices supply allocation weights only;
/// they never turn an unknown acquisition cost into a known one.
enum ShowCostBasisMath {
    /// Earlier copies consume remainder cents first. Repeating this operation
    /// against the remaining quantity and cost recovers the exact original lot.
    static func consumedCost(totalCostCents: Int64?, quantity: Int,
                             consumedQuantity: Int) throws -> Int64? {
        guard (1...ShowBudgetBook.maximumQuantity).contains(quantity),
              (0...quantity).contains(consumedQuantity),
              totalCostCents.map(ShowBudgetMoney.isValid) ?? true else {
            throw ShowTransactionFailure.invalidDraft
        }
        guard let totalCostCents else { return nil }
        let count = Int64(quantity), consumed = Int64(consumedQuantity)
        return totalCostCents / count * consumed + min(totalCostCents % count, consumed)
    }

    /// Largest-remainder allocation preserves the exact negotiated total.
    /// UUID order resolves equal fractions independently of presentation order.
    static func allocate(totalCents: Int64, ids: [UUID], weights: [Decimal]) throws -> [Int64] {
        guard ShowBudgetMoney.isValid(totalCents), ids.count == weights.count,
              ids.count <= ShowBudgetBook.maximumTransactionCards,
              Set(ids).count == ids.count,
              weights.allSatisfy({ !$0.isNaN && $0 >= 0 }) else {
            throw ShowTransactionFailure.invalidDraft
        }
        guard totalCents > 0 else { return Array(repeating: 0, count: ids.count) }
        guard !ids.isEmpty else { throw ShowTransactionFailure.costAllocationRequired }
        var totalWeight = Decimal.zero
        for weight in weights {
            totalWeight += weight
            guard !totalWeight.isNaN else { throw ShowTransactionFailure.costAllocationRequired }
        }
        guard totalWeight > 0 else { throw ShowTransactionFailure.costAllocationRequired }

        var cents: [Int64] = [], fractions: [Decimal] = []
        var allocated: Int64 = 0
        for weight in weights {
            // Divide first so large but valid reference quotes cannot overflow
            // when multiplied by a cash total.
            let exact = Decimal(totalCents) * (weight / totalWeight)
            guard !exact.isNaN, exact >= 0, exact <= Decimal(totalCents) else {
                throw ShowTransactionFailure.costAllocationRequired
            }
            var raw = exact, floor = Decimal.zero
            NSDecimalRound(&floor, &raw, 0, .down)
            let value = NSDecimalNumber(decimal: floor).int64Value
            let sum = allocated.addingReportingOverflow(value)
            guard !sum.overflow else { throw ShowBudgetFailure.arithmeticOverflow }
            allocated = sum.partialValue
            cents.append(value)
            fractions.append(exact - floor)
        }
        let remainder = totalCents - allocated
        guard remainder >= 0, remainder <= Int64(ids.count) else {
            throw ShowTransactionFailure.costAllocationRequired
        }
        let order = ids.indices.sorted {
            fractions[$0] == fractions[$1]
                ? ids[$0].uuidString < ids[$1].uuidString
                : fractions[$0] > fractions[$1]
        }
        for index in order.prefix(Int(remainder)) { cents[index] += 1 }
        return cents
    }

    /// Reviewed lot costs stay fixed. Any unassigned lots share the remaining
    /// actual cost using calculated offers or reference weights.
    static func incomingCosts(_ rows: [ShowIncomingCard], totalCostCents: Int64?) throws -> [Int64?] {
        guard rows.count <= ShowBudgetBook.maximumTransactionCards,
              Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ (1...ShowBudgetBook.maximumQuantity).contains($0.quantity) &&
                  ($0.costWeightCents.map(ShowBudgetMoney.isValid) ?? true) &&
                  ($0.allocatedCostCents.map(ShowBudgetMoney.isValid) ?? true) }),
              totalCostCents.map(ShowBudgetMoney.isValid) ?? true else {
            throw ShowTransactionFailure.invalidDraft
        }
        let explicit = rows.compactMap(\.allocatedCostCents)
        guard let totalCostCents else {
            guard explicit.isEmpty else { throw ShowTransactionFailure.costAllocationRequired }
            return Array(repeating: nil, count: rows.count)
        }
        var fixedTotal: Int64 = 0
        for value in explicit {
            let result = fixedTotal.addingReportingOverflow(value)
            guard !result.overflow else { throw ShowBudgetFailure.arithmeticOverflow }
            fixedTotal = result.partialValue
        }
        guard fixedTotal <= totalCostCents else { throw ShowTransactionFailure.costAllocationRequired }
        let unassigned = rows.indices.filter { rows[$0].allocatedCostCents == nil }
        let residual = totalCostCents - fixedTotal
        var costs = rows.map(\.allocatedCostCents)
        if unassigned.isEmpty {
            guard residual == 0 else { throw ShowTransactionFailure.costAllocationRequired }
            return costs
        }
        if residual == 0 {
            for index in unassigned { costs[index] = 0 }
            return costs
        }
        if unassigned.count == 1 {
            costs[unassigned[0]] = residual
            return costs
        }
        let weights = try unassigned.map { index -> Decimal in
            let row = rows[index]
            if let weight = row.costWeightCents { return Decimal(weight) }
            guard let price = row.card.marketPrice, !price.isNaN, price >= 0 else {
                throw ShowTransactionFailure.costAllocationRequired
            }
            let weight = price * Decimal(row.quantity) * 100
            guard !weight.isNaN else { throw ShowTransactionFailure.costAllocationRequired }
            return weight
        }
        let allocated = try allocate(totalCents: residual, ids: unassigned.map { rows[$0].id }, weights: weights)
        for (index, cost) in zip(unassigned, allocated) { costs[index] = cost }
        return costs
    }

    static func carriedTradeCost(outgoingCostCents: Int64?, paidCents: Int64,
                                 receivedCents: Int64) throws -> (incomingCostCents: Int64?, profitCents: Int64?) {
        guard ShowBudgetMoney.isValid(paidCents), ShowBudgetMoney.isValid(receivedCents),
              outgoingCostCents.map(ShowBudgetMoney.isValid) ?? true else {
            throw ShowTransactionFailure.invalidDraft
        }
        guard let outgoingCostCents else { return (nil, nil) }
        let invested = outgoingCostCents.addingReportingOverflow(paidCents)
        guard !invested.overflow else { throw ShowBudgetFailure.arithmeticOverflow }
        let incomingCost = max(invested.partialValue - receivedCents, 0)
        let profit = max(receivedCents - invested.partialValue, 0)
        guard ShowBudgetMoney.isValid(incomingCost), ShowBudgetMoney.isValid(profit) else {
            throw ShowBudgetFailure.arithmeticOverflow
        }
        return (incomingCost, profit)
    }
}
