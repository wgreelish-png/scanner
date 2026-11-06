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
        if let quote = marketQuotes[item.id] {
            let hasNewerSavedQuote = quote.observedAt.map { importedAt in
                item.card.marketPriceMetadata.map { $0.fetchedAt > importedAt } ?? false
            } ?? false
            if !hasNewerSavedQuote { snapshot.card.marketPrice = quote.market }
        }
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
        if entry.blankPrice == true {
            do { try entry.validate() }
            catch { return "This write-in label is invalid. Review its paper and copies before preparing it again." }
            return nil
        }
        if entry.stickerTag == .individual(0) {
            return "This saved label still prints $0. Clear the queue and prepare a write-in label with a blank price."
        }
        if entry.source == .custom {
            do { try entry.validate() }
            catch { return "This custom label is invalid. Review its price, paper and copies before preparing it again." }
            return nil
        }
        guard store.isLoaded else { return "Reload saved label prices before printing this queue." }
        guard let inventoryID = entry.inventoryID else {
            return "This inventory label has no card reference. Prepare a new label from inventory."
        }
        guard let record = store.record(for: inventoryID) else {
            return entry.pricingRevisionID == nil ? nil : "This label's saved price is unavailable. Prepare a new label from inventory."
        }
        guard record.approvedTag == entry.stickerTag,
              entry.pricingRevisionID == nil || entry.pricingRevisionID == record.priceRevisionID else {
            return "The sticker price changed after this label was queued. Clear the outdated label and prepare a new one."
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
                // A source takeover must not silently replace an existing
                // physical sticker with market rounding. The originating lot
                // may still contain copies and can be repriced independently.
                if let origin = item.adoptedFromInventoryID, store.record(for: origin) != nil { return nil }
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
