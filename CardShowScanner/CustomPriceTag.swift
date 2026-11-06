import Foundation
import Observation

/// A manually entered sticker with no inventory identity, quote or cost basis.
struct CustomPriceTagDraft: Equatable, Sendable {
    let priceCents: Int64
    let copies: Int
    let paperSize: InventoryLabelSize
    var isBulk: Bool = false
    var pricePosition: LabelPricePosition = .right

    var isBlankPrice: Bool { !isBulk && priceCents == 0 }
    var priceText: String {
        isBlankPrice ? "" : (isBulk ? StickerPrice.twoForOne.displayText : StickerPrice.individual(priceCents).displayText)
    }
    var priceDescription: String { isBlankPrice ? InventoryLabelDraft.blankPriceDescription : priceText }

    func validate() throws {
        guard ShowBudgetMoney.isValid(priceCents) else { throw InventoryLabelFailure.invalidPrice }
        guard !isBulk || priceCents == 0 else { throw InventoryLabelFailure.invalidPrice }
        guard priceCents % 100 == 0 else { throw InventoryLabelFailure.wholeDollarRequired }
        guard (1...InventoryLabelDraft.maximumCopies).contains(copies) else { throw InventoryLabelFailure.invalidCopies }
    }
}

@MainActor @Observable final class CustomPriceTagModel {
    typealias Render = @MainActor (CustomPriceTagDraft) throws -> LabelRaster
    var price = ""
    var isBulk = false
    var copies = "1"
    var paperSize: InventoryLabelSize
    var pricePosition: LabelPricePosition
    private(set) var error: String?
    private(set) var preparing = false
    @ObservationIgnored private let queue: LabelPrintQueue
    @ObservationIgnored private let render: Render
    @ObservationIgnored private var rasterCache: (draft: CustomPriceTagDraft, raster: LabelRaster)?
    private var preparedDraft: CustomPriceTagDraft?
    private var preparedIDs: Set<UUID> = []

    init(queue: LabelPrintQueue = .shared, paperSize: InventoryLabelSize = .small30x14,
         pricePosition: LabelPricePosition = .right,
         render: @escaping Render = { try InventoryLabelRenderer.renderRaster($0) }) {
        self.queue = queue
        self.paperSize = paperSize
        self.pricePosition = pricePosition
        self.render = render
    }

    var draft: CustomPriceTagDraft? {
        let amount: Int64? = isBulk ? 0 : ShowBudgetMoney.parse(price)
        guard let cents = amount, let count = Int(copies) else { return nil }
        let draft = CustomPriceTagDraft(priceCents: cents, copies: count, paperSize: paperSize,
                                       isBulk: isBulk, pricePosition: pricePosition)
        return (try? draft.validate()) != nil ? draft : nil
    }

    var hasPreparedQueue: Bool {
        guard queue.isLoaded, let preparedDraft, preparedDraft == draft, !preparedIDs.isEmpty else { return false }
        return preparedIDs.isSubset(of: Set(queue.entries.lazy.map(\.id)))
    }

    /// A preview prepares the same immutable printer bits used by Prepare.
    /// Keep only this model's latest exact draft, including its roll profile.
    func previewRaster(for draft: CustomPriceTagDraft) throws -> LabelRaster {
        var metrics = LabelPreparationMetrics()
        var phase = LabelPreparationMetrics.Phase.failed
        defer { metrics.record(kind: .custom, stage: .preview, phase: phase, total: 1) }
        let prepared = try raster(for: draft, metrics: &metrics)
        if prepared.reused { metrics.reusedRaster() }
        phase = .completed
        return prepared.raster
    }

    private func raster(for draft: CustomPriceTagDraft, metrics: inout LabelPreparationMetrics)
        throws -> (raster: LabelRaster, reused: Bool) {
        try draft.validate()
        if let cached = rasterCache, cached.draft == draft { return (cached.raster, true) }
        let raster = try metrics.measure(.render) { try self.render(draft) }
        try raster.validate()
        rasterCache = (draft, raster)
        return (raster, false)
    }

    /// Persists pending labels only. Transport still needs an explicit Print action.
    @discardableResult func prepare() -> Bool {
        guard !preparing else { return false }
        if hasPreparedQueue {
            LabelPreparationMetrics().record(kind: .custom, stage: .queue, phase: .reusedQueue,
                                            total: preparedIDs.count)
            return true
        }
        guard let draft else {
            error = isBulk ? "Enter 1–100 copies for the bulk price tag." : "Enter a whole-dollar price and 1–100 copies."
            return false
        }
        preparing = true; error = nil
        var metrics = LabelPreparationMetrics()
        var phase = LabelPreparationMetrics.Phase.failed
        defer {
            preparing = false
            metrics.record(kind: .custom, stage: .queue, phase: phase, total: draft.copies)
        }
        do {
            guard queue.isLoaded else { throw LabelPrintQueueFailure.notLoaded }
            guard queue.entries.isEmpty else { throw LabelPrintQueueFailure.unfinishedQueue }
            let prepared = try raster(for: draft, metrics: &metrics)
            let entries = try (1...draft.copies).map { copy in
                let entry = try LabelQueueEntry(customPriceCents: draft.priceCents, raster: prepared.raster,
                    copyNumber: copy, paperSize: draft.paperSize, isBulk: draft.isBulk)
                if prepared.reused || copy > 1 { metrics.reusedRaster() }
                return entry
            }
            try metrics.measure(.queueSave) { try queue.replace(with: entries) }
            preparedDraft = draft
            preparedIDs = Set(entries.lazy.map(\.id))
            phase = .completed
            DiagnosticLog.shared.record("labels.custom_prepared", ["quantity": String(entries.count)])
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
