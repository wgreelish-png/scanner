import Foundation
import Observation

enum ShowBudgetStoreFailure: LocalizedError, Equatable, Sendable {
    case notLoaded, saving, showNotFound, entryNotFound, conflictingEntry, outsideShowDates, fileTooLarge, loadFailed, saveFailed

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "The saved show budget could not be opened. Retry loading it before making changes. Your existing file has been kept."
        case .saving: return "The show budget is already being saved."
        case .showNotFound: return "This show budget is no longer available. Reopen the show and retry."
        case .outsideShowDates: return "This show budget applies only during its scheduled dates. Choose an active show or update its dates before recording cash."
        case .entryNotFound: return "This budget entry is no longer available. Reopen the show and retry."
        case .conflictingEntry: return "This transaction was already recorded with different details. Review the existing entry before adding another."
        case .fileTooLarge: return "The saved show budget is too large to open or update safely. The original file has been kept."
        case .loadFailed: return "The saved show budget could not be opened. Your existing file has been kept. Retry after storage becomes available."
        case .saveFailed: return "The show budget was not saved. Your entries and selections have been kept; retry saving."
        }
    }
}

/// Independent, versioned financial records. Changes are published only after
/// an atomic file write. List-outcome commands coordinate their recoverable
/// SwiftData projection without a second financial charge.
@MainActor @Observable final class ShowBudgetStore {
    typealias Reader = @MainActor (URL) throws -> Data?
    typealias Writer = @MainActor (Data, URL) throws -> Void
    typealias Clock = @MainActor () -> Date

    static let shared = ShowBudgetStore()
    static let maximumBytes = 32 * 1_024 * 1_024

    private(set) var book = ShowBudgetBook()
    private(set) var error: String?
    private(set) var isLoaded = false
    private(set) var isSaving = false

    var inventory: [ShowInventoryItem] { book.inventory }
    var transactions: [ShowTransactionReceipt] { book.transactions }
    var visibleShows: [ShowBudgetEvent] { book.shows.filter { $0.deletedAt == nil } }
    var inventorySourceLocationID: Int? { book.inventorySourceLocationID }
    var costAdjustments: [ShowInventoryCostAdjustment] { book.costAdjustments }
    var inventoryReconciliations: [ShowInventoryReconciliation] { book.inventoryReconciliations }
    var lastInventorySnapshotID: Data? { book.inventoryReconciliations.last?.snapshotID }

    var activeShow: ShowBudgetEvent? {
        guard isLoaded, let id = book.activeShowID else { return nil }
        return book.shows.first { $0.id == id && $0.deletedAt == nil }
    }

    private let url: URL
    private let read: Reader
    private let write: Writer
    private let now: Clock
    let calendar: Calendar

    var currentDate: Date { now() }

    /// Selection remains available for review; funds apply only on show days.
    var eligibleActiveShow: ShowBudgetEvent? {
        guard let show = activeShow, show.applies(on: now(), calendar: calendar) else { return nil }
        return show
    }

    func canRecord(showID: UUID) -> Bool {
        guard isLoaded, let show = book.shows.first(where: { $0.id == showID }) else { return false }
        return show.applies(on: now(), calendar: calendar)
    }

    init(url: URL? = nil, read: Reader? = nil, write: Writer? = nil,
         now: @escaping Clock = Date.init, calendar: Calendar = .current) {
        self.url = url ?? Self.defaultURL
        self.read = read ?? Self.readFile
        self.write = write ?? Self.writeFile
        self.now = now; self.calendar = calendar
        reload()
    }

    func reload() {
        guard !isSaving else { return }
        do {
            let next: ShowBudgetBook
            if let data = try read(url) {
                guard data.count <= Self.maximumBytes else { throw ShowBudgetStoreFailure.fileTooLarge }
                next = try JSONDecoder().decode(ShowBudgetBook.self, from: data)
            } else { next = ShowBudgetBook() }
            try next.validate()
            book = next
            isLoaded = true
            error = nil
        } catch {
            // Never replace an unreadable file with an empty/default budget.
            // Retain any in-memory book, but block financial changes until a
            // successful reload establishes the current durable state.
            isLoaded = false
            self.error = (error as? ShowBudgetStoreFailure)?.errorDescription
                ?? ShowBudgetStoreFailure.loadFailed.errorDescription
            DiagnosticLog.shared.record("budget.load_failed")
        }
    }

    @discardableResult
    func create(name: String, startingCents: Int64, startDate: Date? = nil, endDate: Date? = nil) throws -> UUID {
        try requireWritable()
        guard visibleShows.count < ShowBudgetBook.maximumShows, book.shows.count < ShowBudgetBook.maximumStoredShows else {
            throw ShowBudgetFailure.capacityExceeded
        }
        let show = ShowBudgetEvent(name: name.trimmingCharacters(in: .whitespacesAndNewlines), startingCents: startingCents, createdAt: now(),
                                   startDate: startDate, endDate: endDate)
        var next = book
        next.shows.append(show)
        next.activeShowID = show.id
        try commit(next)
        return show.id
    }

    func select(showID: UUID?) throws {
        try requireWritable()
        guard showID == nil || book.shows.contains(where: { $0.id == showID && $0.deletedAt == nil }) else {
            throw ShowBudgetStoreFailure.showNotFound
        }
        guard book.activeShowID != showID else { return }
        var next = book
        next.activeShowID = showID
        try commit(next)
    }

    func update(showID: UUID, name: String, startingCents: Int64) throws {
        try requireWritable()
        guard let show = book.shows.first(where: { $0.id == showID && $0.deletedAt == nil }) else { throw ShowBudgetStoreFailure.showNotFound }
        try update(showID: showID, name: name, startingCents: startingCents, startDate: show.startDate, endDate: show.endDate)
    }

    func update(showID: UUID, name: String, startingCents: Int64, startDate: Date?, endDate: Date?) throws {
        try requireWritable()
        guard let index = book.shows.firstIndex(where: { $0.id == showID && $0.deletedAt == nil }) else {
            throw ShowBudgetStoreFailure.showNotFound
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard book.shows[index].name != trimmed || book.shows[index].startingCents != startingCents ||
                book.shows[index].startDate != startDate || book.shows[index].endDate != endDate else { return }
        var next = book
        next.shows[index].name = trimmed
        next.shows[index].startingCents = startingCents
        next.shows[index].startDate = startDate; next.shows[index].endDate = endDate
        try commit(next)
    }

    func record(_ entry: ShowBudgetEntry, showID: UUID) throws {
        try requireWritable()
        guard entry.transactionID == nil else { throw ShowTransactionFailure.inventoryLinkedEntry }
        guard let index = book.shows.firstIndex(where: { $0.id == showID }) else {
            throw ShowBudgetStoreFailure.showNotFound
        }
        for show in book.shows {
            if let existing = show.entries.first(where: { $0.id == entry.id }) {
                guard show.id == showID, existing == entry else { throw ShowBudgetStoreFailure.conflictingEntry }
                return // The exact same confirmation/retry has already committed.
            }
        }
        if let listID = entry.listID, transaction(forListID: listID) != nil {
            throw ShowTransactionFailure.incomingListAlreadyUsed
        }
        // Recheck at commit time: an open form or a midnight boundary must not
        // post cash outside the scheduled days. Exact committed retries above
        // remain idempotent even after the show has ended.
        guard book.shows[index].applies(on: now(), calendar: calendar) else {
            throw ShowBudgetStoreFailure.outsideShowDates
        }
        var next = book
        next.shows[index].entries.append(entry)
        try commit(next)
    }

    func void(entryID: UUID, showID: UUID, now: Date = .now) throws {
        try requireWritable()
        guard let show = book.shows.firstIndex(where: { $0.id == showID }) else {
            throw ShowBudgetStoreFailure.showNotFound
        }
        guard let entry = book.shows[show].entries.firstIndex(where: { $0.id == entryID }) else {
            throw ShowBudgetStoreFailure.entryNotFound
        }
        guard book.shows[show].entries[entry].transactionID == nil else {
            throw ShowTransactionFailure.inventoryLinkedEntry
        }
        guard book.shows[show].entries[entry].voidedAt == nil else { return }
        var next = book
        next.shows[show].entries[entry].voidedAt = now
        try commit(next)
    }

    /// Budget cash and its pending SwiftData projection share this one durable
    /// write. Repeated semantic requests reuse the original operation before
    /// today's date is checked, so old committed cash is never charged twice.
    func applyListOutcome(_ request: ListBudgetOutcomeRequest) throws -> BudgetListOutcomeUpdate {
        try requireWritable()
        guard transaction(forListID: request.listID) == nil else {
            throw ShowTransactionFailure.incomingListAlreadyUsed
        }
        guard !request.listName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.listName.count <= 250 else { throw ShowBudgetFailure.invalidBook }
        let candidate = BudgetListOutcomeUpdate(id: UUID(), listID: request.listID,
            desiredOutcomeData: request.desiredOutcomeData, calculatedPaidCents: request.paidCents,
            calculatedReceivedCents: request.receivedCents, createdAt: request.recordedAt,
            showID: nil, entryID: nil, disposition: request.hasCash ? .noApplicableShow : .noCash, mirrored: false)
        try candidate.validate()
        guard candidate.outcomeKind == request.kind else { throw ShowBudgetFailure.invalidBook }
        if let previous = book.listOutcomeUpdates?.first(where: { $0.listID == request.listID }) {
            let same = previous.outcomeKind == request.kind && previous.calculatedPaidCents == request.paidCents &&
                previous.calculatedReceivedCents == request.receivedCents
            if same {
                if !previous.mirrored { return previous }
                if previous.disposition == .noApplicableShow {
                    if eligibleActiveShow == nil { return previous }
                } else if let entryID = previous.entryID {
                    if book.shows.contains(where: { $0.entries.contains { $0.id == entryID && $0.voidedAt == nil } }) { return previous }
                } else { return previous }
            }
            guard previous.mirrored else { throw ShowBudgetStoreFailure.conflictingEntry }
        }
        let priorAuto = book.shows.flatMap(\.entries).filter {
            $0.listID == request.listID && $0.outcomeOperationID != nil && $0.voidedAt == nil
        }
        let manualCash = book.shows.flatMap(\.entries).contains {
            $0.listID == request.listID && $0.outcomeOperationID == nil && $0.voidedAt == nil &&
                ($0.paidCents > 0 || $0.grossReceivedCents > 0)
        }
        if request.hasCash && manualCash { throw ListBudgetOutcomeFailure.manualReceiptExists }
        let target = request.hasCash ? eligibleActiveShow : nil
        if let target, request.hasCash, book.shows.contains(where: { show in
            show.id != target.id && show.entries.contains { $0.listID == request.listID && $0.outcomeOperationID != nil && $0.voidedAt == nil }
        }) { throw ListBudgetOutcomeFailure.differentShowReplacement }
        if request.hasCash && target == nil && !priorAuto.isEmpty {
            throw ListBudgetOutcomeFailure.noApplicableShowForReplacement
        }
        var next = book
        // Zero-cash corrections are allowed after the original show's dates.
        // They reverse only this app's auto receipts, never manual cash records.
        for show in next.shows.indices {
            for entry in next.shows[show].entries.indices {
                let old = next.shows[show].entries[entry]
                if old.listID == request.listID && old.outcomeOperationID != nil && old.voidedAt == nil {
                    next.shows[show].entries[entry].voidedAt = max(request.recordedAt, old.recordedAt)
                }
            }
        }
        var showID: UUID?, entryID: UUID?
        let disposition: BudgetListOutcomeUpdate.Disposition
        if let target, let index = next.shows.firstIndex(where: { $0.id == target.id }) {
            let receipt = ShowBudgetEntry(id: candidate.id, kind: request.kind == .purchase ? .purchase : .trade,
                paidCents: request.paidCents, grossReceivedCents: request.receivedCents,
                reinvestmentPercent: request.kind == .tradeAndPurchase ? 100 : target.reinvestmentPercent, splitBasis: .grossProceeds,
                recordedAt: request.recordedAt, listID: request.listID, listName: request.listName,
                note: "Recorded from list outcome", outcomeOperationID: candidate.id)
            next.shows[index].entries.append(receipt)
            showID = target.id; entryID = receipt.id; disposition = .applied
        } else if request.hasCash { disposition = .noApplicableShow }
        else if manualCash { disposition = .manualCashPreserved }
        else { disposition = priorAuto.isEmpty ? .noCash : .applied }
        let update = BudgetListOutcomeUpdate(id: candidate.id, listID: request.listID,
            desiredOutcomeData: request.desiredOutcomeData, calculatedPaidCents: request.paidCents,
            calculatedReceivedCents: request.receivedCents, createdAt: request.recordedAt,
            showID: showID, entryID: entryID, disposition: disposition, mirrored: false)
        var updates = next.listOutcomeUpdates ?? []
        updates.removeAll { $0.listID == request.listID }; updates.append(update)
        next.listOutcomeUpdates = updates
        try commit(next)
        DiagnosticLog.shared.record("list.outcome_budget_committed", ["phase": "budget", "reason": disposition.rawValue])
        return update
    }

    func acknowledgeListOutcome(_ operationID: UUID) throws {
        try requireWritable()
        guard let index = book.listOutcomeUpdates?.firstIndex(where: { $0.id == operationID }),
              book.listOutcomeUpdates?[index].mirrored == false else { return }
        var next = book
        next.listOutcomeUpdates?[index].mirrored = true
        try commit(next)
    }

    /// Import a remote inventory mirror once. Keep sold-out lots so a later
    /// screen refresh cannot resurrect stock or overwrite local transactions.
    func seedInventory(_ seeds: [ShowInventorySeed], sourceLocationID: Int) throws {
        try requireWritable()
        if let original = book.inventorySourceLocationID {
            guard original == sourceLocationID else { throw ShowTransactionFailure.inventoryLocationConflict }
            return
        }
        guard seeds.count <= ShowBudgetBook.maximumInventorySeeds,
              seeds.count <= ShowBudgetBook.maximumInventoryItems - book.inventory.count else {
            throw ShowBudgetFailure.capacityExceeded
        }
        guard sourceLocationID > 0, Set(seeds.map(\.sourceInventoryID)).count == seeds.count,
              seeds.allSatisfy({ $0.sourceInventoryID > 0 }),
              seeds.allSatisfy({ (0...ShowBudgetBook.maximumQuantity).contains($0.quantity) && ShowTransactionMath.validCard($0.card) }) else {
            throw ShowTransactionFailure.invalidInventory
        }
        var next = book
        let timestamp = now()
        next.inventorySourceLocationID = sourceLocationID
        let seeded = seeds.map {
            ShowInventoryItem(card: $0.card, quantity: $0.quantity, sourceInventoryID: $0.sourceInventoryID,
                sourceLocationID: sourceLocationID, acquiredAt: timestamp)
        }
        next.inventory.append(contentsOf: seeded)
        next.costLedgerBaseline.append(contentsOf: seeded.map(ShowCostStockState.init))
        try commit(next)
        DiagnosticLog.shared.record("show_inventory.seeded", ["records": String(seeds.count)])
    }

    /// Merge preserves unmatched acquisitions and adopts newly matching website
    /// copies with their cost/provenance. Replace uses the entire website count.
    @discardableResult
    func reconcileInventory(_ seeds: [ShowInventorySeed], sourceLocationID: Int,
                            snapshotID: Data, mode: ShowInventoryImportMode = .merge) throws -> ShowInventoryReconciliationSummary {
        try requireWritable()
        guard sourceLocationID > 0,
              book.inventorySourceLocationID.map({ $0 == sourceLocationID }) ?? true else {
            throw ShowTransactionFailure.inventoryLocationConflict
        }
        let rows = seeds.sorted { $0.sourceInventoryID < $1.sourceInventoryID }
        // Check every committed marker, not just the last refresh. Reopening
        // an old source must never restore copies sold or corrected locally.
        if let prior = book.inventoryReconciliations.first(where: { $0.snapshotID == snapshotID }) {
            guard prior.sourceLocationID == sourceLocationID, prior.sourceRows == rows,
                  prior.effectiveMode == mode else {
                throw ShowBudgetStoreFailure.conflictingEntry
            }
            return .init(addedQuantity: 0, removedQuantity: 0, unchangedSnapshot: true,
                totalQuantity: try ShowInventoryReconciliationMath.totalQuantity(book.inventory))
        }
        // Validate the complete source before making a plan or changing state.
        try ShowInventoryReconciliationMath.validate(rows)
        guard !snapshotID.isEmpty, snapshotID.count <= 4_096 else { throw ShowTransactionFailure.invalidInventory }
        guard book.inventoryReconciliations.count < ShowBudgetBook.maximumInventoryReconciliations else {
            throw ShowBudgetFailure.capacityExceeded
        }
        let previousSourceRows = try book.inventoryReconciliations.last?.sourceRows ?? book.initialWebsiteSourceRows()
        let legacyLocalOverlap = book.legacyLocalOverlapForNextImport()
        let count = try ShowInventoryReconciliationMath.newLotCount(seeds: rows, inventory: book.inventory,
            mode: mode, previousSourceRows: previousSourceRows, legacyLocalOverlap: legacyLocalOverlap)
        guard count <= ShowBudgetBook.maximumInventoryItems - book.inventory.count else { throw ShowBudgetFailure.capacityExceeded }
        let timestamp = max(now(), book.costMutations.map(\.recordedAt).max() ?? .distantPast)
        let event = ShowInventoryReconciliation(id: UUID(), sourceLocationID: sourceLocationID,
            snapshotID: snapshotID, recordedAt: timestamp, sourceRows: rows,
            createdInventoryIDs: (0..<count).map { _ in UUID() }, mode: mode)
        let plan = try ShowInventoryReconciliationMath.plan(event, inventory: book.inventory,
            previousSourceRows: previousSourceRows, legacyLocalOverlap: legacyLocalOverlap)
        var next = book
        next.inventorySourceLocationID = sourceLocationID
        next.inventory = plan.inventory
        next.inventoryReconciliations.append(event)
        next.costMutations.append(try .capturing(kind: .reconciliation, operationID: event.id,
            recordedAt: timestamp, itemIDs: plan.changedIDs, before: book.inventory, after: next.inventory))
        // Marker, provenance, quantity/cost deltas and event share one atomic
        // write. A failed write leaves the same snapshot available for retry.
        try commit(next)
        DiagnosticLog.shared.record("show_inventory.reconciled", ["records": String(rows.count)])
        return plan.summary
    }

    func transaction(forListID listID: UUID) -> ShowTransactionReceipt? {
        book.transactions.first { $0.incomingListID == listID && $0.reversedAt == nil }
    }

    /// Only remaining stock is corrected. Completed receipts retain their cost.
    func setInventoryCost(itemID: UUID, totalCostCents: Int64?) throws {
        try requireWritable()
        guard totalCostCents.map(ShowBudgetMoney.isValid) ?? true,
              let index = book.inventory.firstIndex(where: { $0.id == itemID }),
              book.inventory[index].quantity > 0 else { throw ShowTransactionFailure.invalidCost }
        let item = book.inventory[index]
        guard item.remainingCostCents != totalCostCents else { return }
        guard book.costAdjustments.count < ShowBudgetBook.maximumCostAdjustments else { throw ShowBudgetFailure.capacityExceeded }
        var next = book
        next.inventory[index].remainingCostCents = totalCostCents
        let adjustment = ShowInventoryCostAdjustment(id: UUID(), inventoryID: itemID, quantity: item.quantity,
            previousCostCents: item.remainingCostCents, totalCostCents: totalCostCents,
            recordedAt: max(now(), item.acquiredAt))
        next.costAdjustments.append(adjustment)
        next.costMutations.append(try .capturing(kind: .adjustment, operationID: adjustment.id,
            recordedAt: adjustment.recordedAt, itemIDs: [itemID], before: book.inventory, after: next.inventory))
        try commit(next)
    }

    /// Cash-only historical sales are disclosed as uncosted, never reconstructed
    /// from a current quote. Deleted shows and their history remain reportable.
    func profitSummary(showID: UUID? = nil) throws -> ShowProfitSummary {
        var sales: Int64 = 0, fees: Int64 = 0, soldCost: Int64 = 0, profit: Int64 = 0, tradeProfit: Int64 = 0
        var unknownQuantity = 0, unknownLines = 0, uncostedSales = 0, uncostedTrades = 0, incomplete = 0
        func add(_ value: Int64, to total: inout Int64) throws {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { throw ShowBudgetFailure.arithmeticOverflow }
            total = result.partialValue
        }
        for show in book.shows where showID == nil || show.id == showID {
            for entry in show.entries where entry.voidedAt == nil {
                if entry.kind == .sale {
                    try add(entry.grossReceivedCents, to: &sales)
                    try add(entry.feeCents, to: &fees)
                    if entry.transactionID == nil { uncostedSales += 1 }
                } else if entry.kind == .trade && entry.transactionID == nil { uncostedTrades += 1 }
            }
        }
        for receipt in book.transactions where receipt.reversedAt == nil && (showID == nil || receipt.showID == showID) && receipt.kind != .purchase {
            let lines = receipt.accounting?.outgoing
            for (index, line) in receipt.outgoing.enumerated() {
                let cost = lines?[index].totalCostCents
                if let cost, receipt.kind == .sale { try add(cost, to: &soldCost) }
                if cost == nil { unknownLines += 1; unknownQuantity += line.quantity }
            }
            if let known = receipt.profitCents {
                try add(known, to: &profit)
                if receipt.kind != .sale { try add(known, to: &tradeProfit) }
            } else {
                incomplete += 1
                // Where per-row proceeds are known, retain the known subtotal.
                if receipt.kind == .sale {
                    for line in lines ?? [] {
                        if let known = line.profitCents { try add(known, to: &profit) }
                    }
                }
            }
        }
        return .init(salesCents: sales, sellingFeesCents: fees, soldCostCents: soldCost,
            knownProfitCents: profit, tradeCashProfitCents: tradeProfit,
            unknownCostQuantity: unknownQuantity, unknownCostLineCount: unknownLines,
            uncostedSaleCount: uncostedSales, incompleteTransactionCount: incomplete, uncostedTradeCount: uncostedTrades)
    }

    /// Card movement, the immutable receipt, and its cash projection all share
    /// the same atomic JSON write. Nothing is published when that write fails.
    @discardableResult
    func recordTransaction(_ draft: ShowTransactionDraft, showID: UUID) throws -> ShowTransactionReceipt {
        try requireWritable()
        if let existing = book.transactions.first(where: { $0.id == draft.id }) {
            guard existing.showID == showID, existing.draft == draft else { throw ShowBudgetStoreFailure.conflictingEntry }
            return existing
        }
        guard let showIndex = book.shows.firstIndex(where: { $0.id == showID && $0.deletedAt == nil }) else {
            throw ShowBudgetStoreFailure.showNotFound
        }
        let show = book.shows[showIndex]
        guard show.applies(on: now(), calendar: calendar) else { throw ShowBudgetStoreFailure.outsideShowDates }
        let amounts = try ShowTransactionMath.calculate(draft, saleReinvestmentPercent: show.reinvestmentPercent)
        var accounting = try ShowTransactionMath.preview(draft, inventory: book.inventory,
            saleReinvestmentPercent: show.reinvestmentPercent)
        if let listID = draft.incomingListID {
            guard transaction(forListID: listID) == nil else { throw ShowTransactionFailure.incomingListAlreadyUsed }
            let legacyCash = book.shows.flatMap(\.entries).contains {
                $0.transactionID == nil && $0.listID == listID && $0.voidedAt == nil &&
                    ($0.paidCents > 0 || $0.grossReceivedCents > 0 || $0.kind == .purchase || $0.kind == .trade)
            }
            let legacyOutcome = (book.listOutcomeUpdates ?? []).contains {
                $0.listID == listID && ($0.outcomeKind == .purchase || $0.outcomeKind == .trade || $0.outcomeKind == .tradeAndPurchase)
            }
            guard !legacyCash, !legacyOutcome else { throw ShowTransactionFailure.legacyListOutcomeExists }
        }
        guard !book.shows.contains(where: { $0.entries.contains(where: { $0.id == draft.id }) }) else {
            throw ShowBudgetStoreFailure.conflictingEntry
        }
        guard book.transactions.count < ShowBudgetBook.maximumTransactions,
              draft.incoming.count <= ShowBudgetBook.maximumInventoryItems - book.inventory.count else {
            throw ShowBudgetFailure.capacityExceeded
        }
        var next = book
        var outgoing: [ShowTransactionCardLine] = []
        for (selection, cost) in zip(draft.outgoing, accounting.outgoing) {
            guard let index = next.inventory.firstIndex(where: { $0.id == selection.inventoryID }),
                  next.inventory[index].quantity >= selection.quantity else { throw ShowTransactionFailure.insufficientStock }
            let item = next.inventory[index]
            next.inventory[index].quantity -= selection.quantity
            if let remaining = item.remainingCostCents, let consumed = cost.totalCostCents {
                next.inventory[index].remainingCostCents = remaining - consumed
            } else { next.inventory[index].remainingCostCents = nil }
            outgoing.append(ShowTransactionCardLine(inventoryID: item.id, card: item.card, quantity: selection.quantity))
        }
        let timestamp = now()
        var incoming: [ShowTransactionCardLine] = []
        for (row, cost) in zip(draft.incoming, accounting.incoming) {
            let item = ShowInventoryItem(card: row.card, quantity: row.quantity,
                acquiredByTransactionID: draft.id, acquiredAt: timestamp, remainingCostCents: cost.totalCostCents)
            next.inventory.append(item)
            incoming.append(ShowTransactionCardLine(inventoryID: item.id, card: item.card, quantity: item.quantity))
        }
        accounting.incoming = zip(accounting.incoming, incoming).map { cost, line in cost.replacingInventoryID(line.inventoryID) }
        let receipt = ShowTransactionReceipt(id: draft.id, showID: show.id, showName: show.name,
            kind: draft.kind, recordedAt: timestamp, incomingListID: draft.incomingListID,
            incomingListName: draft.incomingListName, incoming: incoming, outgoing: outgoing,
            incomingValueCents: draft.incomingValueCents, outgoingValueCents: draft.outgoingValueCents,
            paidCents: amounts.paidCents, receivedCents: amounts.receivedCents,
            reinvestedCents: amounts.reinvestedCents, savedCents: amounts.savedCents,
            concessionCents: amounts.concessionCents, reversedAt: nil, draft: draft, accounting: accounting)
        next.transactions.append(receipt)
        next.shows[showIndex].entries.append(ShowBudgetEntry(id: receipt.id, kind: draft.kind.budgetKind,
            paidCents: amounts.paidCents, grossReceivedCents: amounts.receivedCents, feeCents: draft.feeCents,
            reinvestmentPercent: draft.kind == .sale ? show.reinvestmentPercent : 100,
            recordedAt: timestamp, listID: draft.incomingListID, listName: draft.incomingListName,
            note: draft.note, transactionID: receipt.id))
        next.costMutations.append(try .capturing(kind: .record, operationID: receipt.id, recordedAt: timestamp,
            itemIDs: outgoing.map(\.inventoryID) + incoming.map(\.inventoryID), before: book.inventory, after: next.inventory))
        try commit(next)
        return receipt
    }

    /// Undo is available after show dates and deletion. Lots retain their own
    /// identity, so unrelated copies cannot conceal a later dependent sale.
    func undoTransaction(_ id: UUID) throws {
        try requireWritable()
        guard let index = book.transactions.firstIndex(where: { $0.id == id }) else {
            throw ShowTransactionFailure.transactionNotFound
        }
        let receipt = book.transactions[index]
        guard receipt.reversedAt == nil else { return }
        guard !book.reconciliationPreventsUndo(of: receipt) else { throw ShowTransactionFailure.inventoryReconciled }
        let acquired = Set(receipt.incoming.map(\.inventoryID))
        guard !book.transactions.contains(where: { $0.id != id && $0.reversedAt == nil &&
            $0.outgoing.contains(where: { acquired.contains($0.inventoryID) }) }) else {
            throw ShowTransactionFailure.dependentStockUsed
        }
        guard let show = book.shows.firstIndex(where: { $0.id == receipt.showID }),
              let entry = book.shows[show].entries.firstIndex(where: { $0.transactionID == id }) else {
            throw ShowBudgetFailure.invalidBook
        }
        var next = book
        for line in receipt.incoming {
            guard let stock = next.inventory.firstIndex(where: { $0.id == line.inventoryID }),
                  next.inventory[stock].quantity == line.quantity else { throw ShowTransactionFailure.dependentStockUsed }
            next.inventory[stock].quantity = 0
            next.inventory[stock].remainingCostCents = next.inventory[stock].remainingCostCents == nil ? nil : 0
        }
        for (lineIndex, line) in receipt.outgoing.enumerated() {
            guard let stock = next.inventory.firstIndex(where: { $0.id == line.inventoryID }) else { throw ShowBudgetFailure.invalidBook }
            let restored = next.inventory[stock].quantity.addingReportingOverflow(line.quantity)
            guard !restored.overflow, restored.partialValue <= ShowBudgetBook.maximumQuantity else { throw ShowBudgetFailure.arithmeticOverflow }
            next.inventory[stock].quantity = restored.partialValue
            if let consumed = receipt.accounting?.outgoing[lineIndex].totalCostCents,
               let remaining = next.inventory[stock].remainingCostCents {
                let cost = remaining.addingReportingOverflow(consumed)
                guard !cost.overflow, ShowBudgetMoney.isValid(cost.partialValue) else { throw ShowBudgetFailure.arithmeticOverflow }
                next.inventory[stock].remainingCostCents = cost.partialValue
            } else {
                // Historical/unknown consumed copies cannot become known merely
                // because the remaining copies were subsequently costed.
                next.inventory[stock].remainingCostCents = nil
            }
        }
        let reversedAt = max(now(), receipt.recordedAt)
        next.transactions[index].reversedAt = reversedAt
        next.shows[show].entries[entry].voidedAt = reversedAt
        next.costMutations.append(try .capturing(kind: .undo, operationID: receipt.id, recordedAt: reversedAt,
            itemIDs: receipt.incoming.map(\.inventoryID) + receipt.outgoing.map(\.inventoryID),
            before: book.inventory, after: next.inventory))
        try commit(next)
        DiagnosticLog.shared.record("show_transaction.undone", ["reason": receipt.kind.rawValue,
            "records": String(receipt.incoming.count + receipt.outgoing.count)])
    }

    /// Deleting a show hides its settings; stock and audit receipts stay durable.
    func deleteShow(showID: UUID) throws {
        try requireWritable()
        guard let index = book.shows.firstIndex(where: { $0.id == showID }) else { throw ShowBudgetStoreFailure.showNotFound }
        guard book.shows[index].deletedAt == nil else { return }
        var next = book
        next.shows[index].deletedAt = max(now(), next.shows[index].createdAt)
        if next.activeShowID == showID { next.activeShowID = nil }
        try commit(next)
        DiagnosticLog.shared.record("show.deleted", ["reason": "history_preserved"])
    }

    private func requireWritable() throws {
        guard isLoaded else { throw ShowBudgetStoreFailure.notLoaded }
        guard !isSaving else { throw ShowBudgetStoreFailure.saving }
    }

    private func commit(_ next: ShowBudgetBook) throws {
        try requireWritable()
        isSaving = true
        defer { isSaving = false }
        do {
            try next.validate()
            let data = try JSONEncoder().encode(next)
            guard data.count <= Self.maximumBytes else { throw ShowBudgetStoreFailure.fileTooLarge }
            do { try write(data, url) }
            catch { throw ShowBudgetStoreFailure.saveFailed }
            book = next
            error = nil
            DiagnosticLog.shared.record("budget.saved")
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? ShowBudgetStoreFailure.saveFailed.errorDescription
            DiagnosticLog.shared.record("budget.save_failed")
            throw error
        }
    }

    private static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("show-budgets.json", isDirectory: false)
    }

    private static func readFile(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return nil }
            throw ShowBudgetStoreFailure.loadFailed
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ShowBudgetStoreFailure.loadFailed }
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximumBytes) else {
            throw ShowBudgetStoreFailure.fileTooLarge
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw ShowBudgetStoreFailure.fileTooLarge }
        return data
    }

    private static func writeFile(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Application Support remains included in device backups. Budget and
        // transaction records are user data, not disposable caches.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
