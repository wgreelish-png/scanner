import Foundation
import SwiftData

struct TagMarketQuote: Equatable, Sendable {
    let market: Decimal?
    let observedAt: Date?
    init(market: Decimal?, observedAt: Date? = nil) { self.market = market; self.observedAt = observedAt }
}

struct TagSaleSuggestion: Equatable {
    let totalCents: Int64
    let allocations: [ShowSaleAllocation]
    let usesApprovedPrices: Bool
}

/// Fresh pricing stays outside immutable acquisition/transaction card snapshots.
/// This reads the existing saved import; it does not change stock or fetch data.
@MainActor enum TagPricingContext {
    static func currentQuotes(inventory: [ShowInventoryItem], context: ModelContext) -> [UUID: TagMarketQuote] {
        guard let list = try? CardShowInventoryService.importedList(context: context) else { return [:] }
        let source = list.orderedCards.compactMap { try? JSONDecoder().decode(CardCandidate.self, from: $0.data) }
        let grouped = Dictionary(grouping: source, by: key)
        var result: [UUID: TagMarketQuote] = [:]
        for item in inventory {
            guard let matches = grouped[key(item.card)] else { continue }
            let exact = item.card.identity.skuID.map { sku in matches.filter { $0.identity.skuID == sku } } ?? []
            let chosen = exact.isEmpty ? matches : exact
            let prices = Set(chosen.map(\.marketPrice))
            // Conflicting snapshots are unavailable rather than a guessed quote.
            result[item.id] = TagMarketQuote(market: prices.count == 1 ? chosen.first?.marketPrice : nil,
                observedAt: list.cardShowInventory?.refreshedAt)
        }
        return result
    }

    static func draft(for item: ShowInventoryItem, marketQuotes: [UUID: TagMarketQuote] = [:],
                      store: TagApprovalStore = .shared) -> InventoryLabelDraft {
        var snapshot = item
        if let quote = marketQuotes[item.id] { snapshot.card.marketPrice = quote.market }
        return InventoryLabelDraft(item: snapshot, preferences: store.preferences, approval: store.record(for: item.id))
    }

    static func review(for draft: InventoryLabelDraft, store: TagApprovalStore = .shared) -> RepricingEvaluation {
        let approved = store.record(for: draft.id)
        return RepricingPolicy.evaluate(baselineMarket: approved?.marketAtLastApproval,
            currentMarket: draft.marketValue, approvedStickerCents: approved?.approvedTag.integerPriceCents,
            hasApprovedCategory: approved?.approvedTag == .twoForOne)
    }

    static func bundleLines(drafts: [InventoryLabelDraft], inventory: [ShowInventoryItem],
                            preferences: TagPricingPreferences) -> [TagBundleLine] {
        let items = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        return drafts.map { draft in
            let inputs = items[draft.id].map { preferences.profitInputs(for: $0, quantity: draft.copies) } ?? draft.profitInputs
            return TagBundleLine(id: draft.id, quantity: draft.copies,
                individualStickerCents: draft.isBulk ? nil : draft.priceCents,
                isTwoForOne: draft.isBulk, profitInputs: inputs)
        }
    }

    static func bundleSettings(_ preferences: TagPricingPreferences) -> TagBundleSettings {
        var promotions: [TagBundlePromotion] = [.twoForOne]
        if preferences.enableTwoFiveForNine { promotions.append(.twoFiveForNine) }
        if preferences.enableThreeFiveForThirteen { promotions.append(.threeFiveForThirteen) }
        return TagBundleSettings(enabledPromotions: promotions, allowsDiscountStacking: preferences.allowPromotionStacking)
    }

    static func printingIssue(for entry: LabelQueueEntry, store: TagApprovalStore = .shared) -> String? {
        guard store.isLoaded else { return "Reload saved tag approvals before printing this queue." }
        guard let record = store.record(for: entry.inventoryID) else {
            return entry.pricingRevisionID == nil ? nil : "This label's approval is unavailable. Review its price before preparing a new label."
        }
        guard record.approvedTag.integerPriceCents == entry.priceCents,
              entry.pricingRevisionID == nil || entry.pricingRevisionID == record.priceRevisionID else {
            return "The approved sticker changed after this label was queued. Discard the outdated label and prepare the approved price."
        }
        return nil
    }

    /// Checkout uses approved stickers immediately. Legacy reference rounding
    /// remains separate so saved transaction validation never changes its math.
    static func saleSuggestion(lines: [ShowTransactionCardLine], inventory: [ShowInventoryItem],
                               store: TagApprovalStore = .shared) -> TagSaleSuggestion? {
        guard store.isLoaded, !lines.isEmpty, Set(lines.map(\.inventoryID)).count == lines.count else { return nil }
        let items = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        var amounts: [UUID: Int64] = [:], bulk: [TagBundleLine] = []
        var usesApproved = false
        for line in lines {
            guard line.quantity > 0, let item = items[line.inventoryID], item.quantity >= line.quantity else { return nil }
            if let approved = store.record(for: line.inventoryID) {
                usesApproved = true
                switch approved.approvedTag {
                case .twoForOne:
                    bulk.append(TagBundleLine(id: line.inventoryID, quantity: line.quantity, isTwoForOne: true,
                        profitInputs: store.preferences.profitInputs(for: item, quantity: line.quantity)))
                case .individual(let cents):
                    let value = cents.multipliedReportingOverflow(by: Int64(line.quantity))
                    guard !value.overflow, ShowBudgetMoney.isValid(value.partialValue) else { return nil }
                    amounts[line.inventoryID] = value.partialValue
                }
            } else {
                guard let value = ShowSaleMath.suggestedTotal([line]) else { return nil }
                amounts[line.inventoryID] = value
            }
        }
        if !bulk.isEmpty {
            let settings = store.preferences
            let offer = TagBundlePricing.evaluate(lines: bulk, promotion: .twoForOne,
                paymentFixedFee: ShowBudgetMoney.decimal(settings.fixedPaymentFeeCents),
                paymentPercentageFee: settings.percentagePaymentFee,
                settings: bundleSettings(settings))
            guard offer.isEligible else { return nil }
            for allocation in offer.allocations { amounts[allocation.id] = allocation.chargedCents }
        }
        var total: Int64 = 0
        var allocations: [ShowSaleAllocation] = []
        for line in lines {
            guard let amount = amounts[line.inventoryID] else { return nil }
            let sum = total.addingReportingOverflow(amount)
            guard !sum.overflow, ShowBudgetMoney.isValid(sum.partialValue) else { return nil }
            total = sum.partialValue
            allocations.append(ShowSaleAllocation(inventoryID: line.inventoryID, quantity: line.quantity, receivedCents: amount))
        }
        return TagSaleSuggestion(totalCents: total, allocations: allocations, usesApprovedPrices: usesApproved)
    }

    private static func key(_ card: CardCandidate) -> String {
        let identity = card.identity
        return [identity.game, identity.productID, identity.printing, identity.language, identity.condition]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
            .joined(separator: "\u{1f}")
    }
}
