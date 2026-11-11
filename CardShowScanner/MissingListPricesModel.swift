import Foundation
import Observation
import SwiftData

/// An explicit recovery pass for saved, editable list rows. Requests are serial
/// and use normal cache policy; known prices (including zero) are never touched.
@MainActor @Observable final class MissingListPricesModel {
    private struct Target {
        let id: UUID
        let data: Data
        let quantity: Int
        let addedAt: Date
        let cash: String?, trade: String?, maximum: String?

        init(_ row: InventoryCard) {
            id = row.id; data = row.data; quantity = row.quantity; addedAt = row.addedAt
            cash = row.cashOverrideText; trade = row.tradeOverrideText; maximum = row.maximumOverrideText
        }

        func matches(_ row: InventoryCard, listID: UUID) -> Bool {
            row.id == id && row.list?.id == listID && row.sourceInventoryID == nil && row.data == data
                && row.quantity == quantity && row.addedAt == addedAt && row.cashOverrideText == cash
                && row.tradeOverrideText == trade && row.maximumOverrideText == maximum
                && row.snapshot.marketPrice == nil
        }
    }

    private(set) var isRunning = false
    private(set) var total = 0
    private(set) var completed = 0
    private(set) var updated = 0
    private(set) var unavailable = 0
    private(set) var failed = 0
    private(set) var skipped = 0
    private(set) var remaining = 0
    private(set) var wasCancelled = false
    private(set) var pausedForCooling = false
    private(set) var error: String?
    @ObservationIgnored private let pricing: any MarketPricing
    @ObservationIgnored private let canContinue: @MainActor () -> Bool
    @ObservationIgnored private let save: @MainActor (ModelContext) throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private var hasStarted = false
    @ObservationIgnored private weak var activeList: CardList?

    init(pricing: any MarketPricing = StandardMarketPricing(),
         canContinue: @escaping @MainActor () -> Bool = {
             let state = ProcessInfo.processInfo.thermalState
             return state != .serious && state != .critical
         }, save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }) {
        self.pricing = pricing; self.canContinue = canContinue; self.save = save
    }

    deinit { task?.cancel() }

    var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    var summary: String? {
        guard hasStarted, !isRunning else { return nil }
        if total == 0, error != nil { return nil }
        if total == 0, error == nil { return "All editable entries already have a price." }
        var parts = ["Updated \(updated) of \(total) entries. \(remaining) still have no price."]
        if failed > 0 { parts.append("\(failed) lookups or saves failed.") }
        if skipped > 0 { parts.append("\(skipped) changed or removed entries were kept unchanged.") }
        if wasCancelled { parts.append("Refresh cancelled; saved prices were kept.") }
        if pausedForCooling { parts.append("Paused to let the phone cool. Refresh again when it has cooled.") }
        return parts.joined(separator: " ")
    }

    @discardableResult func start(list: CardList, context: ModelContext) -> Bool {
        guard !isRunning else { return false }
        task?.cancel(); generation = UUID(); hasStarted = true; activeList = list
        total = 0; completed = 0; updated = 0; unavailable = 0; failed = 0; skipped = 0
        wasCancelled = false; pausedForCooling = false; error = nil
        remaining = 0
        guard isAvailable(list, context: context) else {
            error = "This saved list is no longer available."
            return false
        }
        guard !list.isCardShowInventory else {
            error = "Imported inventory keeps its source prices. Duplicate the list to refresh prices locally."
            return false
        }
        remaining = Self.missingCount(list)
        guard !context.hasChanges else { stopForEdits(); return false }
        let targets = list.orderedCards.filter { $0.sourceInventoryID == nil && $0.snapshot.marketPrice == nil }.map(Target.init)
        total = targets.count
        guard !targets.isEmpty else { return false }
        guard canContinue() else { pausedForCooling = true; return false }
        isRunning = true
        let current = generation
        DiagnosticLog.shared.record("list.missing_prices_started", ["total": String(total)])
        task = Task { [weak self] in
            await self?.refresh(targets, list: list, context: context, generation: current)
        }
        return true
    }

    func cancel() {
        guard isRunning else { return }
        generation = UUID(); task?.cancel(); isRunning = false; wasCancelled = true
        if let activeList, let context = activeList.modelContext, isAvailable(activeList, context: context) {
            remaining = Self.missingCount(activeList)
        }
        recordFinished(reason: "cancelled")
    }

    func waitUntilFinished() async { await task?.value }

    private func refresh(_ targets: [Target], list: CardList, context: ModelContext, generation current: UUID) async {
        defer {
            if generation == current {
                isRunning = false; task = nil
                remaining = isAvailable(list, context: context) ? Self.missingCount(list) : remaining
                recordFinished(reason: pausedForCooling ? "cooling" : (error == nil ? "completed" : "stopped"))
            }
        }
        for target in targets {
            guard generation == current, !Task.isCancelled else { return }
            guard isAvailable(list, context: context) else { error = "This list is no longer available. Saved prices were kept."; return }
            guard !context.hasChanges else { stopForEdits(); return }
            guard canContinue() else { pausedForCooling = true; return }
            guard let row = currentRow(target, in: list, context: context) else { skipped += 1; completed += 1; continue }
            let card = row.snapshot
            do {
                let details = try await pricing.details(for: card, candidates: [card], forceRefresh: false)
                guard generation == current, !Task.isCancelled else { return }
                guard canContinue() else { pausedForCooling = true; return }
                guard isAvailable(list, context: context) else { error = "This list is no longer available. Saved prices were kept."; return }
                guard !context.hasChanges else { stopForEdits(); return }
                guard let currentRow = currentRow(target, in: list, context: context),
                      try persistedRowMatches(target, listID: list.id, container: context.container) else {
                    skipped += 1; completed += 1; continue
                }
                guard let quote = details.quote, MarketDetails.hasPrice(quote.marketPrice) else {
                    unavailable += 1; completed += 1; continue
                }
                var priced = card
                priced.marketPrice = quote.marketPrice
                priced.identity.skuID = quote.skuID ?? card.identity.skuID
                priced.marketPriceMetadata = details.metadata
                let replacement = try JSONEncoder().encode(priced)
                // There is no suspension between this clean-context check,
                // mutation and save. A background reply never commits edits
                // made elsewhere in the presenting context while it awaited.
                guard !context.hasChanges else { stopForEdits(); return }
                currentRow.data = replacement
                do { try save(context) }
                catch {
                    // Restore only our field. Never roll back unrelated models.
                    if currentRow.data == replacement { currentRow.data = target.data }
                    failed += 1; completed += 1
                    self.error = "The price could not be saved. Your saved prices and current edits were kept. Refresh again after saving your current edits."
                    logFailure(error)
                    return
                }
                updated += 1; completed += 1; remaining = Self.missingCount(list)
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                failed += 1; completed += 1; logFailure(error)
            }
            await Task.yield()
        }
    }

    private func stopForEdits() {
        error = "Finish saving your current edits, then refresh again. Prices already refreshed were kept."
    }

    private func isAvailable(_ list: CardList, context: ModelContext) -> Bool {
        list.modelContext === context && !context.deletedModelsArray.contains { ObjectIdentifier($0) == ObjectIdentifier(list) }
    }

    private func currentRow(_ target: Target, in list: CardList, context: ModelContext) -> InventoryCard? {
        guard let row = list.cards.first(where: { $0.id == target.id }), row.modelContext === context,
              !context.deletedModelsArray.contains(where: { ObjectIdentifier($0) == ObjectIdentifier(row) }),
              target.matches(row, listID: list.id) else { return nil }
        return row
    }

    private func persistedRowMatches(_ target: Target, listID: UUID, container: ModelContainer) throws -> Bool {
        let reader = ModelContext(container)
        let rowID = target.id
        let row = try reader.fetch(FetchDescriptor<InventoryCard>(predicate: #Predicate { $0.id == rowID })).first
        return row.map { target.matches($0, listID: listID) } ?? false
    }

    private static func missingCount(_ list: CardList) -> Int {
        list.cards.filter { $0.sourceInventoryID == nil && $0.snapshot.marketPrice == nil }.count
    }

    private func logFailure(_ failure: Error) {
        var fields = ServiceDiagnosticFields.failure(failure); fields["phase"] = "missing_prices"
        DiagnosticLog.shared.record("list.missing_prices_failed", fields)
    }

    private func recordFinished(reason: String) {
        DiagnosticLog.shared.record("list.missing_prices_finished", ["reason": reason, "total": String(total),
            "priced_records": String(updated), "unpriced_records": String(remaining), "rejected_records": String(skipped)])
    }
}
