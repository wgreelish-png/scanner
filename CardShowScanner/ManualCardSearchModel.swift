import Foundation
import Observation
import SwiftData

@MainActor @Observable final class ManualCardSearchModel {
    private(set) var query = ""
    private(set) var filters = CardCatalogFilters()
    private(set) var game: String
    private(set) var results: [CardCandidate] = []
    private(set) var isSearching = false
    private(set) var error: String?
    private(set) var isSuspendedForSelection = false
    private let catalog: any CardCatalogSearching
    private let debounce: Duration
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var searchNeededOnReturn = false

    init(game: String, catalog: any CardCatalogSearching = CachedCardCatalog.shared, debounce: Duration = .milliseconds(150)) {
        self.game = game; self.catalog = catalog; self.debounce = debounce
    }
    var hasCriteria: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !filters.isEmpty }
    func load() { scheduleSearch() }
    func changeGame(_ game: String) {
        guard TCGGameRegistry.scannerKey(for: game) != nil, game != self.game else { return }
        self.game = game; results = []; filters = .init(); scheduleSearch()
    }
    func updateQuery(_ value: String) {
        let value = String(value.prefix(256))
        guard value != query else { return }
        query = value; scheduleSearch()
    }
    func updateSetFilter(_ value: String) {
        let value = String(value.prefix(256))
        guard value != filters.set else { return }
        filters.set = value; scheduleSearch()
    }
    func updateNumberFilter(_ value: String) {
        let value = String(value.prefix(64))
        guard value != filters.number else { return }
        filters.number = value; scheduleSearch()
    }
    func clearFilters() { filters = .init(); scheduleSearch() }

    /// A confirmation page needs the chosen snapshot, not live typeahead work.
    /// Keep completed results so Back does not reload an unchanged catalog.
    func suspendForSelection() {
        searchNeededOnReturn = searchNeededOnReturn || isSearching
        isSuspendedForSelection = true
        cancel()
    }
    func resumeAfterSelection() {
        guard isSuspendedForSelection else { return }
        isSuspendedForSelection = false
        if searchNeededOnReturn { searchNeededOnReturn = false; scheduleSearch() }
    }

    private func scheduleSearch() {
        cancel()
        if isSuspendedForSelection { searchNeededOnReturn = true; return }
        error = nil; isSearching = true
        if !hasCriteria { results = [] }
        let query = query, game = game, filters = filters, id = requestID, delay = debounce
        let hasCriteria = hasCriteria
        task = Task { [weak self, catalog] in
            do {
                if hasCriteria { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                let cards = try await catalog.search(query, game: game, limit: 5, filters: filters)
                guard let self, !Task.isCancelled, self.requestID == id, !self.isSuspendedForSelection else { return }
                self.results = Array(cards.prefix(5)); self.isSearching = false; self.task = nil
                DiagnosticLog.shared.record("catalog.search_finished", ["records": String(self.results.count)], sampleEvery: 1)
            } catch {
                guard let self, !Task.isCancelled, self.requestID == id, !self.isSuspendedForSelection else { return }
                self.isSearching = false; self.task = nil
                self.results = []
                self.error = (error as? CardCatalogFailure)?.errorDescription ?? "The saved catalog could not be searched. Retry, or check the database in the scanner."
                DiagnosticLog.shared.failure("catalog.search_failed", error)
            }
        }
    }
    func cancel() { task?.cancel(); task = nil; requestID = UUID(); isSearching = false }
}

/// Search and pricing are drafts. Only an explicit Add commits a quantity-one row.
@MainActor @Observable final class ManualCardAddModel {
    let pricing: CardEditorPricingModel
    private(set) var isSaving = false
    private(set) var isSaved = false
    private(set) var error: String?
    var needsSessionSwitch = false
    private let saveCard: @MainActor (CardCandidate, ScanSession, CardList, ModelContext) throws -> Void

    init(card: CardCandidate, pricing: any MarketPricing = StandardMarketPricing(),
         saveCard: @escaping @MainActor (CardCandidate, ScanSession, CardList, ModelContext) throws -> Void = {
             try SessionService.add($0, session: $1, list: $2, context: $3)
         }) {
        var draft = card; draft.identity.condition = "Near Mint"; draft.marketPrice = nil; draft.identity.skuID = nil; draft.marketPriceMetadata = nil
        self.pricing = CardEditorPricingModel(card: draft, pricing: pricing, manualPriceAllowed: false); self.saveCard = saveCard
    }
    @discardableResult func add(to list: CardList, context: ModelContext, finishingOtherSession: Bool = false,
                               draft: ScanBatchDraft? = nil) -> Bool {
        guard !isSaving, !isSaved, !pricing.priceLoading else { return false }
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            if let draft, !draft.isCommitted {
                guard list.id == draft.list.id else { throw BatchFailure.unavailable }
                try SessionService.commitDraft(draft, card: pricing.card, context: context, saveCard: { card, session, list, context, _ in
                    try self.saveCard(card, session, list, context)
                })
                isSaved = true; needsSessionSwitch = false
                DiagnosticLog.shared.record("catalog.card_added", ["priced": String(pricing.card.marketPrice != nil)])
                return true
            }
            let list = draft?.list ?? list
            if let current = try SessionService.active(context: context), current.listID != list.id, !finishingOtherSession {
                needsSessionSwitch = true
                return false
            }
            let card = pricing.card
            let batch = try SessionService.continueList(list, game: card.identity.game, context: context, finishingOtherSession: finishingOtherSession)
            try SessionService.withScanSave(session: batch, list: list, context: context) {
                try saveCard(card, batch, list, context)
            }
            isSaved = true; needsSessionSwitch = false
            DiagnosticLog.shared.record("catalog.card_added", ["priced": String(card.marketPrice != nil)])
            return true
        } catch {
            self.error = "The card was not added. Your selection is kept; retry Add to List."
            DiagnosticLog.shared.failure("catalog.add_failed", error)
            return false
        }
    }
}
