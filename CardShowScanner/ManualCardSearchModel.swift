import Foundation
import Observation
import SwiftData

@MainActor @Observable final class ManualCardSearchModel {
    private(set) var query = ""
    private(set) var game: String
    private(set) var results: [CardCandidate] = []
    private(set) var isSearching = false
    private(set) var error: String?
    private let catalog: any CardCatalogSearching
    private let debounce: Duration
    private var task: Task<Void, Never>?
    private var requestID = UUID()

    init(game: String, catalog: any CardCatalogSearching = CachedCardCatalog.shared, debounce: Duration = .milliseconds(150)) {
        self.game = game; self.catalog = catalog; self.debounce = debounce
    }
    func load() { updateQuery(query) }
    func changeGame(_ game: String) {
        guard CatalogOptions.games.contains(game), game != self.game else { return }
        self.game = game; results = []; updateQuery(query)
    }
    func updateQuery(_ value: String) {
        task?.cancel(); requestID = UUID()
        query = String(value.prefix(256)); error = nil; isSearching = true
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { results = [] }
        let query = query, game = game, id = requestID, delay = debounce
        task = Task { [weak self, catalog] in
            do {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                let cards = try await catalog.search(query, game: game, limit: 5)
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                self.results = Array(cards.prefix(5)); self.isSearching = false
                DiagnosticLog.shared.record("catalog.search_finished", ["records": String(self.results.count)], sampleEvery: 1)
            } catch {
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                self.isSearching = false
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

    init(card: CardCandidate, pricing: any MarketPricing = SelectedMarketPricing(),
         saveCard: @escaping @MainActor (CardCandidate, ScanSession, CardList, ModelContext) throws -> Void = {
             try SessionService.add($0, session: $1, list: $2, context: $3)
         }) {
        var draft = card; draft.identity.condition = "Near Mint"; draft.marketPrice = nil; draft.identity.skuID = nil; draft.marketPriceMetadata = nil
        self.pricing = CardEditorPricingModel(card: draft, pricing: pricing, manualPriceAllowed: false); self.saveCard = saveCard
    }
    @discardableResult func add(to list: CardList, context: ModelContext, finishingOtherSession: Bool = false) -> Bool {
        guard !isSaving, !isSaved, !pricing.priceLoading else { return false }
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
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
