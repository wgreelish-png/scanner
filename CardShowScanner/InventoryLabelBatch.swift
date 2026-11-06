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

/// Batch selection and draft preparation without changing inventory or stored
/// prices. Physical printing remains an explicit queue action.
@MainActor enum InventoryLabelBatch {
    static func selectedIDs(mode: InventoryLabelBatchMode, inventory: [ShowInventoryItem],
                            marketQuotes: [UUID: TagMarketQuote] = [:],
                            store: TagApprovalStore = .shared) -> Set<UUID> {
        guard mode != .custom else { return [] }
        return Set(inventory.filter { item in
            guard item.quantity > 0 else { return false }
            guard mode == .priceChanged else { return true }
            guard let approval = store.record(for: item.id) else { return true }
            return approval.needsLabels
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
        // Labels use the saved inventory snapshot and final stored sticker.
        // New quote snapshots never reprice cards while preparing a print job.
        var draft = InventoryLabelDraft(item: item, preferences: store.preferences,
                                        approval: store.record(for: item.id))
        // Do not clamp: existing copy/batch validation must expose oversized
        // requests instead of silently leaving physical cards unlabeled.
        draft.copies = mode == .custom ? 1 : item.quantity
        return draft
    }

    /// Choosing cards or Print All explicitly requests replacement stickers.
    /// Only the automatic Price Changed mode suppresses unchanged labeled tags.
    static func shouldPrint(_ draft: InventoryLabelDraft, approval: TagApprovalRecord?,
                            mode: InventoryLabelBatchMode, keepExisting: Bool = false) -> Bool {
        shouldPrint(draft, approval: approval, reprintAll: mode != .priceChanged, keepExisting: keepExisting)
    }

    static func shouldPrint(_ draft: InventoryLabelDraft, approval: TagApprovalRecord?,
                            reprintAll: Bool, keepExisting: Bool = false) -> Bool {
        guard !keepExisting, draft.isBlankPrice || draft.tag != nil else { return false }
        if draft.isBlankPrice { return true }
        if reprintAll { return true }
        guard let approval else { return true }
        return approval.approvedTag != draft.tag || approval.needsLabels
    }
}
