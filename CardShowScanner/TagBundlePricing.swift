import Foundation

/// Explicitly selected copies. Costs, expenses, and desired profit are per copy.
struct TagBundleLine: Equatable, Identifiable, Sendable {
    let id: UUID
    let quantity: Int
    let individualStickerCents: Int64?
    let isTwoForOne: Bool
    let profitInputs: TagProfitInputs

    init(id: UUID = UUID(), quantity: Int = 1, individualStickerCents: Int64? = nil,
         isTwoForOne: Bool = false, profitInputs: TagProfitInputs) {
        self.id = id
        self.quantity = quantity
        self.individualStickerCents = individualStickerCents
        self.isTwoForOne = isTwoForOne
        self.profitInputs = profitInputs
    }
}

struct TagBundlePromotion: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let quantity: Int
    let eligibleStickerCents: Int64?
    let bundlePriceCents: Int64
    let isBulkBin: Bool

    static let twoForOne = TagBundlePromotion(id: "two-for-one", quantity: 2,
        eligibleStickerCents: nil, bundlePriceCents: 100, isBulkBin: true)
    static let twoFiveForNine = TagBundlePromotion(id: "two-five-for-nine", quantity: 2,
        eligibleStickerCents: 500, bundlePriceCents: 900, isBulkBin: false)
    static let threeFiveForThirteen = TagBundlePromotion(id: "three-five-for-thirteen", quantity: 3,
        eligibleStickerCents: 500, bundlePriceCents: 1_300, isBulkBin: false)

    var title: String {
        switch id {
        case Self.twoForOne.id: return "2 for $1"
        case Self.twoFiveForNine.id: return "2 × $5 for $9"
        case Self.threeFiveForThirteen.id: return "3 × $5 for $13"
        default:
            let amount = NSDecimalNumber(decimal: Decimal(bundlePriceCents) / 100).stringValue
            return "\(quantity) for $\(amount)"
        }
    }
}

struct TagBundleSettings: Codable, Equatable, Sendable {
    var enabledPromotions: [TagBundlePromotion]
    var allowsDiscountStacking: Bool

    init(enabledPromotions: [TagBundlePromotion] = [.twoForOne], allowsDiscountStacking: Bool = false) {
        self.enabledPromotions = enabledPromotions
        self.allowsDiscountStacking = allowsDiscountStacking
    }
}

struct TagBundleAllocation: Equatable, Identifiable, Sendable {
    let id: UUID
    let quantity: Int
    let chargedCents: Int64
}

struct TagBundleEvaluation: Equatable, Sendable {
    let promotion: TagBundlePromotion
    let selectedQuantity: Int
    let eligibleLineIDs: [UUID]
    let excludedLineIDs: [UUID]
    let allocations: [TagBundleAllocation]
    /// The proposed charge is available even when a profit warning blocks automatic eligibility.
    let totalChargeCents: Int64?
    let breakEvenCents: Int64?
    let preferredFloorCents: Int64?
    /// Nil for category-only cards, which deliberately have no individual sticker price.
    let savingsCents: Int64?
    let manualReviewReasons: [String]

    var isEligible: Bool { manualReviewReasons.isEmpty }
    var requiresManualOverride: Bool { !isEligible }
    var manualOverrideWarning: String? {
        isEligible ? nil : "Manual override: this bundle has not passed its profit and eligibility checks."
    }
}

/// A preview for exactly the selected copies. It never chooses cheaper copies,
/// changes market prices, or records a checkout discount or cash transaction.
enum TagBundlePricing {
    static func evaluate(lines: [TagBundleLine], promotion: TagBundlePromotion,
                         paymentFixedFee: Decimal = 0, paymentPercentageFee: Decimal = 0,
                         settings: TagBundleSettings = .init(),
                         alreadyDiscountedLineIDs: Set<UUID> = []) -> TagBundleEvaluation {
        var reasons: [String] = []
        func warn(_ message: String) {
            if !reasons.contains(message) { reasons.append(message) }
        }

        let identifiers = lines.map(\.id)
        if lines.isEmpty { warn("Select cards to preview a bundle.") }
        if Set(identifiers).count != identifiers.count {
            warn("Each selected inventory row must appear once.")
        }
        if !settings.enabledPromotions.contains(promotion) {
            warn("Enable this promotion before applying it.")
        }
        let validPromotion = promotion.quantity >= 2 && !promotion.id.isEmpty
            && validCents(promotion.bundlePriceCents)
            && (promotion.isBulkBin
                ? promotion.eligibleStickerCents == nil
                : promotion.eligibleStickerCents.map { validCents($0) && $0 > 0 } == true)
        if !validPromotion { warn("Review the promotion quantity, eligible tag, and bundle price.") }
        if !settings.allowsDiscountStacking && !Set(identifiers).isDisjoint(with: alreadyDiscountedLineIDs) {
            warn("Discount stacking is disabled for already discounted cards.")
        }

        var selectedQuantity = 0
        var validQuantities = true
        var acquisitionCost = Decimal.zero
        var expenses = Decimal.zero
        var desiredProfit = Decimal.zero
        var knownValidCosts = true
        var knownDesiredProfit = true
        var stickerTotal: Int64? = 0

        for line in lines {
            let sum = selectedQuantity.addingReportingOverflow(line.quantity)
            guard line.quantity > 0, !sum.overflow else {
                validQuantities = false
                warn("Choose positive quantities within the supported limit.")
                continue
            }
            selectedQuantity = sum.partialValue
            if promotion.isBulkBin {
                if !line.isTwoForOne || line.individualStickerCents != nil {
                    warn("Only cards in the 2 for $1 category, without individual tags, qualify.")
                }
            } else if line.isTwoForOne || line.individualStickerCents != promotion.eligibleStickerCents {
                warn("Only cards with the promotion's eligible individual tag qualify.")
            }

            if let sticker = line.individualStickerCents {
                let product = sticker.multipliedReportingOverflow(by: Int64(line.quantity))
                if validCents(sticker), !product.overflow, validCents(product.partialValue), let previous = stickerTotal {
                    let total = previous.addingReportingOverflow(product.partialValue)
                    if !total.overflow && validCents(total.partialValue) { stickerTotal = total.partialValue }
                    else { stickerTotal = nil; warn("Bundle totals exceed the supported money limit.") }
                } else {
                    stickerTotal = nil
                    warn("Review individual tags within the supported money limit.")
                }
            } else {
                stickerTotal = nil
            }

            let numericProblems = TagPricing.validateInputs(line.profitInputs).filter {
                $0 != .unknownAcquisitionCost && $0 != .missingMinimumDesiredProfit
            }
            if !numericProblems.isEmpty {
                knownValidCosts = false
                warn("Review invalid acquisition cost, expense, profit, or fee values.")
            }
            if line.profitInputs.minimumDesiredProfit == nil {
                knownDesiredProfit = false
                warn("Set the minimum desired profit for every selected card before applying a bundle.")
            }
            guard let cost = line.profitInputs.acquisitionCost else {
                knownValidCosts = false
                warn("Some selected cards have unknown acquisition cost.")
                continue
            }
            let exactCost = addProduct(to: &acquisitionCost, amount: cost, quantity: line.quantity)
            let exactExpenses = addProduct(to: &expenses, amount: line.profitInputs.allocatedExpenses, quantity: line.quantity)
            let exactProfit = addProduct(to: &desiredProfit, amount: line.profitInputs.minimumDesiredProfit ?? 0,
                                        quantity: line.quantity)
            if !exactCost || !exactExpenses || !exactProfit {
                knownValidCosts = false
                warn("Bundle totals exceed the supported money limit or decimal precision.")
            }
        }

        var totalCharge: Int64?
        if validPromotion && validQuantities && selectedQuantity > 0 {
            if selectedQuantity % promotion.quantity != 0 {
                warn("Select complete groups of \(promotion.quantity) cards for this promotion.")
            } else {
                let groups = selectedQuantity / promotion.quantity
                let charge = promotion.bundlePriceCents.multipliedReportingOverflow(by: Int64(groups))
                if !charge.overflow && validCents(charge.partialValue) { totalCharge = charge.partialValue }
                else { warn("Bundle totals exceed the supported money limit.") }
            }
        }

        // Per-copy fee fields are validated above, but a complete payment pays its
        // fixed fee once and its percentage once. They are never summed per line.
        if knownValidCosts && (!canSumExactly([acquisitionCost, expenses, paymentFixedFee])
            || (knownDesiredProfit && !canSumExactly([acquisitionCost, expenses, desiredProfit, paymentFixedFee]))) {
            knownValidCosts = false
            warn("Bundle totals exceed the supported money limit or decimal precision.")
        }
        let aggregate = TagProfitInputs(acquisitionCost: knownValidCosts ? acquisitionCost : nil,
            allocatedExpenses: expenses, minimumDesiredProfit: knownDesiredProfit ? desiredProfit : nil,
            fixedPaymentFee: paymentFixedFee, percentagePaymentFee: paymentPercentageFee)
        let validAggregate = TagPricing.validateInputs(aggregate).filter {
            $0 != .unknownAcquisitionCost && $0 != .missingMinimumDesiredProfit
        }.isEmpty
        if !validAggregate {
            warn("Review total costs and payment fees within the supported limits.")
        }
        var breakEven: Int64?
        var preferredFloor: Int64?
        if knownValidCosts && validAggregate && !lines.isEmpty {
            do {
                breakEven = try TagPricing.floorCents(inputs: aggregate, desiredProfit: 0)
                if knownDesiredProfit {
                    preferredFloor = try TagPricing.floorCents(inputs: aggregate, desiredProfit: desiredProfit)
                }
            } catch {
                warn("Bundle totals exceed the supported money limit.")
            }
        }
        if let charge = totalCharge, let floor = breakEven, charge < floor {
            warn("The complete bundle is below break-even.")
        }
        if let charge = totalCharge, let floor = preferredFloor, charge < floor, floor != breakEven {
            warn("The complete bundle is below its desired profit floor.")
        }

        var allocations: [TagBundleAllocation] = []
        if let charge = totalCharge, Set(identifiers).count == identifiers.count {
            allocations = allocate(charge, lines: lines, quantity: selectedQuantity)
            if allocations.count != lines.count {
                warn("The bundle charge could not be allocated to the selected copies.")
            }
        }
        let savings: Int64?
        if let original = stickerTotal, let charge = totalCharge {
            savings = max(0, original - charge)
        } else {
            savings = nil
        }
        return TagBundleEvaluation(promotion: promotion, selectedQuantity: selectedQuantity,
            eligibleLineIDs: reasons.isEmpty ? identifiers : [],
            excludedLineIDs: reasons.isEmpty ? [] : identifiers,
            allocations: allocations, totalChargeCents: totalCharge, breakEvenCents: breakEven,
            preferredFloorCents: preferredFloor, savingsCents: savings, manualReviewReasons: reasons)
    }

    private static func validCents(_ value: Int64) -> Bool {
        value >= 0 && value <= TagPricing.maximumCents
    }

    private static func addProduct(to total: inout Decimal, amount: Decimal, quantity: Int) -> Bool {
        var amount = amount, copies = Decimal(quantity), product = Decimal.zero
        guard NSDecimalMultiply(&product, &amount, &copies, .plain) == .noError else { return false }
        var previous = total, sum = Decimal.zero
        guard NSDecimalAdd(&sum, &previous, &product, .plain) == .noError else { return false }
        total = sum
        return true
    }

    private static func canSumExactly(_ amounts: [Decimal]) -> Bool {
        var total = Decimal.zero
        for amount in amounts {
            if !addProduct(to: &total, amount: amount, quantity: 1) { return false }
        }
        return true
    }

    /// Equal per-copy allocation, with fractional cents assigned by stable ID.
    /// No line's allocation is used as its profit floor; profit is assessed once
    /// for the complete bundle, allowing genuine whole-bundle cost protection.
    private static func allocate(_ charge: Int64, lines: [TagBundleLine], quantity: Int) -> [TagBundleAllocation] {
        guard quantity > 0 else { return [] }
        var amounts: [Int64] = []
        var fractions: [Decimal] = []
        var allocated: Int64 = 0
        for line in lines {
            guard line.quantity > 0 else { return [] }
            let exact = Decimal(charge) * Decimal(line.quantity) / Decimal(quantity)
            guard !exact.isNaN, exact >= 0, exact <= Decimal(charge) else { return [] }
            var raw = exact, rounded = Decimal.zero
            NSDecimalRound(&rounded, &raw, 0, .down)
            let cents = NSDecimalNumber(decimal: rounded).int64Value
            let total = allocated.addingReportingOverflow(cents)
            guard !total.overflow else { return [] }
            amounts.append(cents)
            fractions.append(exact - rounded)
            allocated = total.partialValue
        }
        let remainder = charge - allocated
        guard remainder >= 0 && remainder <= Int64(lines.count) else { return [] }
        let order = lines.indices.sorted {
            fractions[$0] == fractions[$1]
                ? lines[$0].id.uuidString < lines[$1].id.uuidString
                : fractions[$0] > fractions[$1]
        }
        for index in order.prefix(Int(remainder)) { amounts[index] += 1 }
        return lines.indices.map {
            TagBundleAllocation(id: lines[$0].id, quantity: lines[$0].quantity, chargedCents: amounts[$0])
        }
    }
}
