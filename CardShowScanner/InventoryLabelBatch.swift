import Foundation
import Observation

enum LabelPrintOrder: String, CaseIterable, Identifiable, Sendable {
    case cardName, priceAscending, priceDescending

    var id: Self { self }
    var title: String {
        switch self {
        case .cardName: return "Card Name"
        case .priceAscending: return "Price: Low to High"
        case .priceDescending: return "Price: High to Low"
        }
    }

    func orderedDrafts(_ drafts: [InventoryLabelDraft]) -> [InventoryLabelDraft] {
        ordered(drafts, name: { $0.cardName }, price: { Self.price($0.isBlankPrice ? nil : $0.tag) })
    }

    func orderedEntries(_ entries: [LabelQueueEntry]) -> [LabelQueueEntry] {
        ordered(entries, name: { $0.cardName }, price: { Self.price($0.stickerTag) })
    }

    /// Sort the actual printed amount, keeping write-in and invalid amounts
    /// last in either direction. Equal names retain the supplied copy order.
    private func ordered<Element>(_ elements: [Element], name: (Element) -> String,
                                  price: (Element) -> Int64?) -> [Element] {
        let keyed = elements.enumerated().map { index, element in
            (element: element, index: index, name: name(element), price: price(element))
        }
        return keyed.sorted { left, right in
            if self != .cardName {
                switch (left.price, right.price) {
                case let (left?, right?) where left != right:
                    return self == .priceAscending ? left < right : left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            let names = left.name.localizedStandardCompare(right.name)
            return names == .orderedSame ? left.index < right.index : names == .orderedAscending
        }.map(\.element)
    }

    private static func price(_ tag: StickerPrice?) -> Int64? {
        switch tag {
        case .twoForOne: return 50
        case let .individual(cents): return ShowBudgetMoney.isValid(cents) ? cents : nil
        case nil: return nil
        }
    }
}

/// This preference changes only label ordering. It never starts printing or
/// rearranges an existing queue until the user explicitly chooses an order.
@MainActor @Observable final class LabelPrintOrderPreferences {
    static let shared: LabelPrintOrderPreferences = {
        let arguments = ProcessInfo.processInfo.arguments
        let token = arguments.first(where: { $0.hasPrefix("--show-transactions-fixture-id=") })
            .map { String($0.dropFirst("--show-transactions-fixture-id=".count)) }
        let fixture = arguments.contains("--show-transactions-ui-fixture")
            ? token.flatMap { UUID(uuidString: $0)?.uuidString } : nil
        let key = "labelPrintOrder" + (fixture.map { ".fixture." + $0 } ?? "")
        return LabelPrintOrderPreferences(defaults: .standard, key: key)
    }()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    var order: LabelPrintOrder {
        didSet {
            guard order != oldValue else { return }
            defaults.set(order.rawValue, forKey: key)
        }
    }

    init(defaults: UserDefaults = .standard, key: String = "labelPrintOrder") {
        self.defaults = defaults
        self.key = key
        order = defaults.string(forKey: key).flatMap(LabelPrintOrder.init(rawValue:)) ?? .cardName
    }
}

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
