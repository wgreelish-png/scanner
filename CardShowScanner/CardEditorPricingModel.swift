import Foundation
import Observation

/// Pricing for an inventory edit stays in a draft until the user explicitly saves.
@MainActor @Observable final class CardEditorPricingModel {
    var card: CardCandidate
    private(set) var price: String
    private(set) var priceLoading = false
    private(set) var priceMessage: String?
    private(set) var priceConnectionRequired = false
    private let pricing: any MarketPricing
    private let manualPriceAllowed: Bool
    private var lookup: Task<Void, Never>?
    private var requestID = UUID()

    init(card: CardCandidate, pricing: any MarketPricing = SelectedMarketPricing(), manualPriceAllowed: Bool = true) {
        self.card = card
        self.price = CSVExportService.number(card.marketPrice)
        self.pricing = pricing
        self.manualPriceAllowed = manualPriceAllowed
    }

    func changeIdentity(_ change: (inout CardIdentity) -> Void) {
        let previous = Self.priceIdentity(card.identity)
        change(&card.identity)
        if Self.priceIdentity(card.identity) != previous { fetchPrice(forceRefresh: false) }
    }

    func refreshPrice() { fetchPrice(forceRefresh: true) }
    func pricingSourceChanged() { fetchPrice(forceRefresh: true) }

    private func fetchPrice(forceRefresh: Bool) {
        cancelLookup()
        card.marketPrice = nil; card.identity.skuID = nil; card.marketPriceMetadata = nil; price = ""
        priceMessage = nil; priceConnectionRequired = false; priceLoading = true
        let request = requestID
        let requestedCard = card
        DiagnosticLog.shared.record("inventory.pricing_started", ["phase": "editor"])
        lookup = Task { [weak self, pricing] in
            do {
                let details = try await pricing.details(for: requestedCard, candidates: [requestedCard], forceRefresh: forceRefresh)
                guard let self, !Task.isCancelled, self.requestID == request,
                      Self.priceIdentity(self.card.identity) == Self.priceIdentity(requestedCard.identity) else { return }
                let quote = details.quote
                if !details.printings.isEmpty { self.card.printings = details.printings }
                self.card.marketPrice = quote?.marketPrice
                self.card.identity.skuID = quote?.skuID
                self.card.marketPriceMetadata = quote?.marketPrice == nil ? nil : details.metadata
                self.price = CSVExportService.number(quote?.marketPrice)
                self.priceLoading = false
                self.priceMessage = quote?.marketPrice == nil ? "Market value unavailable for this printing and condition." : nil
                DiagnosticLog.shared.record("inventory.pricing_finished", ["phase": "editor", "priced": String(quote?.marketPrice != nil)])
            } catch {
                guard let self, !Task.isCancelled, self.requestID == request,
                      Self.priceIdentity(self.card.identity) == Self.priceIdentity(requestedCard.identity) else { return }
                self.priceLoading = false
                self.priceMessage = (error as? MarketPricingFailure)?.errorDescription
                    ?? (error as? OpenAPIPricingFailure)?.errorDescription ?? (self.manualPriceAllowed
                    ? "Price unavailable. Retry Market Price or enter a price manually."
                    : "Price unavailable. Retry Market Price, or add this card without a market value.")
                var fields = ["phase": "editor", "reason": "lookup_failed"]
                if let failure = error as? MarketPricingFailure, case .accessRejected(let status) = failure {
                    self.priceConnectionRequired = true
                    fields["reason"] = "access_rejected"; fields["code"] = String(status)
                }
                DiagnosticLog.shared.record("inventory.pricing_failed", fields)
            }
        }
    }

    /// Opening an editor refreshes catalog choices without replacing a saved quote.
    func loadPrintingOptions() {
        guard !priceLoading else { return }
        cancelLookup()
        let request = requestID
        let requestedCard = card
        lookup = Task { [weak self, pricing] in
            do {
                let details = try await pricing.details(for: requestedCard, candidates: [requestedCard], forceRefresh: false)
                guard let self, !Task.isCancelled, self.requestID == request,
                      Self.priceIdentity(self.card.identity) == Self.priceIdentity(requestedCard.identity) else { return }
                if !details.printings.isEmpty { self.card.printings = details.printings }
                if self.priceConnectionRequired {
                    self.priceConnectionRequired = false; self.priceMessage = nil
                }
            } catch {
                // The existing draft and printing choices remain usable offline.
                guard let self, !Task.isCancelled, self.requestID == request else { return }
                if let failure = error as? MarketPricingFailure, case .accessRejected = failure {
                    self.priceConnectionRequired = true; self.priceMessage = failure.errorDescription
                }
                DiagnosticLog.shared.record("inventory.pricing_failed", ["phase": "editor", "reason": "printing_options"])
            }
        }
    }

    func setPrice(_ text: String) {
        cancelLookup()
        card.marketPriceMetadata = nil
        price = text
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
        if normalized.range(of: #"^[0-9]+(?:\.[0-9]{1,6})?$"#, options: .regularExpression) != nil,
           let parsed, !parsed.isNaN, parsed >= 0 {
            card.marketPrice = parsed
        } else { card.marketPrice = nil }
        priceMessage = nil; priceConnectionRequired = false
    }

    func setSKU(_ text: String) {
        cancelLookup()
        card.marketPriceMetadata = nil
        card.identity.skuID = text.isEmpty ? nil : text
        priceMessage = nil; priceConnectionRequired = false
    }

    func cancelLookup() {
        lookup?.cancel(); lookup = nil; requestID = UUID(); priceLoading = false
    }

    private static func priceIdentity(_ identity: CardIdentity) -> CardIdentity {
        var key = identity; key.skuID = nil; return key
    }
}
