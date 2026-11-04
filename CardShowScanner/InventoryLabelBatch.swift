import Foundation

enum InventoryLabelBatchMode: String, CaseIterable, Identifiable, Sendable {
    case all, priceChanged, custom

    var id: Self { self }
    var title: String {
        switch self {
        case .all: return "Print All"
        case .priceChanged: return "Price Changed"
        case .custom: return "Choose Cards"
        }
    }
}

/// Batch selection and draft preparation only. Approval and physical printing
/// remain separate, explicit actions in the existing label flow.
@MainActor enum InventoryLabelBatch {
    static func selectedIDs(mode: InventoryLabelBatchMode, inventory: [ShowInventoryItem],
                            marketQuotes: [UUID: TagMarketQuote] = [:],
                            store: TagApprovalStore = .shared) -> Set<UUID> {
        guard mode != .custom else { return [] }
        return Set(inventory.filter { item in
            guard item.quantity > 0 else { return false }
            guard mode == .priceChanged else { return true }
            guard let approval = store.record(for: item.id) else { return true }
            if approval.needsLabels { return true }
            let draft = TagPricingContext.draft(for: item, marketQuotes: marketQuotes, store: store)
            return needsMarketReview(draft, store: store)
        }.map(\.id))
    }

    static func drafts(mode: InventoryLabelBatchMode, inventory: [ShowInventoryItem],
                       marketQuotes: [UUID: TagMarketQuote] = [:],
                       store: TagApprovalStore = .shared) -> [InventoryLabelDraft] {
        let selected = selectedIDs(mode: mode, inventory: inventory, marketQuotes: marketQuotes, store: store)
        return inventory.filter { selected.contains($0.id) }.sorted { left, right in
            let names = left.card.name.localizedStandardCompare(right.card.name)
            return names == .orderedSame ? left.id.uuidString < right.id.uuidString : names == .orderedAscending
        }.map { draft(for: $0, mode: mode, marketQuotes: marketQuotes, store: store) }
    }

    static func draft(for item: ShowInventoryItem, mode: InventoryLabelBatchMode,
                      marketQuotes: [UUID: TagMarketQuote] = [:],
                      store: TagApprovalStore = .shared) -> InventoryLabelDraft {
        var draft = TagPricingContext.draft(for: item, marketQuotes: marketQuotes, store: store)
        let approval = store.record(for: item.id)
        if let approval, approval.isManualOverride {
            // The base draft can cross the bulk boundary when market moves.
            // An approved manual category or price always survives that move.
            switch approval.approvedTag {
            case .twoForOne:
                draft.isBulk = true
                draft.askingPriceText = ""
            case .individual(let cents):
                draft.isBulk = false
                draft.askingPriceText = InventoryLabelDraft.inputText(cents)
            }
            draft.isManualOverride = true
        } else if mode == .priceChanged, needsMarketReview(draft, store: store), draft.pricing.tag != nil {
            // A valid suggestion can still need profit review. Its existing
            // warnings and required acknowledgement remain in force.
            draft.useSuggestedPrice()
        }
        // Do not clamp: existing copy/batch validation must expose oversized
        // requests instead of silently leaving physical cards unlabeled.
        draft.copies = mode == .custom ? 1 : item.quantity
        return draft
    }

    static func shouldPrint(_ draft: InventoryLabelDraft, approval: TagApprovalRecord?,
                            reprintAll: Bool, keepExisting: Bool = false) -> Bool {
        guard !draft.isBulk, !keepExisting, draft.tag != nil else { return false }
        if reprintAll { return true }
        guard let approval else { return true }
        return approval.approvedTag != draft.tag || approval.needsLabels
    }

    private static func needsMarketReview(_ draft: InventoryLabelDraft, store: TagApprovalStore) -> Bool {
        TagPricingContext.review(for: draft, store: store).reasons.contains { reason in
            switch reason {
            case .newPricing, .marketDecrease, .overpriced, .marketIncrease: return true
            case .marketUnavailable: return false
            }
        }
    }
}
