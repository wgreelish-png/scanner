import Foundation
import Observation

/// A manually entered sticker with no inventory identity, quote or cost basis.
struct CustomPriceTagDraft: Equatable, Sendable {
    let priceCents: Int64
    let copies: Int
    let paperSize: InventoryLabelSize

    var priceText: String { StickerPrice.individual(priceCents).displayText }

    func validate() throws {
        guard ShowBudgetMoney.isValid(priceCents) else { throw InventoryLabelFailure.invalidPrice }
        guard priceCents % 100 == 0 else { throw InventoryLabelFailure.wholeDollarRequired }
        guard (1...InventoryLabelDraft.maximumCopies).contains(copies) else { throw InventoryLabelFailure.invalidCopies }
    }
}

@MainActor @Observable final class CustomPriceTagModel {
    typealias Render = @MainActor (CustomPriceTagDraft) throws -> LabelRaster
    var price = ""
    var copies = "1"
    var paperSize: InventoryLabelSize = .small30x14
    private(set) var error: String?
    private(set) var preparing = false
    @ObservationIgnored private let queue: LabelPrintQueue
    @ObservationIgnored private let render: Render
    private var preparedDraft: CustomPriceTagDraft?
    private var preparedIDs: Set<UUID> = []

    init(queue: LabelPrintQueue = .shared,
         render: @escaping Render = { try InventoryLabelRenderer.render($0).raster }) {
        self.queue = queue
        self.render = render
    }

    var draft: CustomPriceTagDraft? {
        guard let cents = ShowBudgetMoney.parse(price), let count = Int(copies) else { return nil }
        let draft = CustomPriceTagDraft(priceCents: cents, copies: count, paperSize: paperSize)
        return (try? draft.validate()) != nil ? draft : nil
    }

    var hasPreparedQueue: Bool {
        guard queue.isLoaded, let preparedDraft, preparedDraft == draft, !preparedIDs.isEmpty else { return false }
        return preparedIDs.isSubset(of: Set(queue.entries.map(\.id)))
    }

    /// Persists pending labels only. Transport still needs an explicit Print action.
    @discardableResult func prepare() -> Bool {
        guard !preparing else { return false }
        if hasPreparedQueue { return true }
        guard let draft else {
            error = "Enter a whole-dollar price and 1–100 copies."
            return false
        }
        preparing = true; error = nil
        defer { preparing = false }
        do {
            guard queue.isLoaded else { throw LabelPrintQueueFailure.notLoaded }
            guard queue.entries.isEmpty else { throw LabelPrintQueueFailure.unfinishedQueue }
            let raster = try render(draft)
            let entries = try (1...draft.copies).map { copy in
                try LabelQueueEntry(customPriceCents: draft.priceCents, raster: raster,
                    copyNumber: copy, paperSize: draft.paperSize)
            }
            try queue.replace(with: entries)
            preparedDraft = draft
            preparedIDs = Set(entries.map(\.id))
            DiagnosticLog.shared.record("labels.custom_prepared", ["quantity": String(entries.count)])
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
