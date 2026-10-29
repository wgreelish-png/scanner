import Foundation
import Observation

/// Read-only details for a captured card value. Each service can finish or fail
/// independently; neither response is applied to the card or its saved offers.
@MainActor @Observable final class MarketInsightsModel {
    private(set) var card: CardCandidate
    private(set) var publicDetails: MarketDetails?
    private(set) var activityDetails: OpportunitiesDetails?
    private(set) var publicLoading = false
    private(set) var activityLoading = false
    private(set) var publicMessage: String?
    private(set) var activityMessage: String?

    private let publicPricing: any MarketPricing
    private let opportunities: any OpportunitiesProviding
    private var publicLookup: Task<Void, Never>?
    private var activityLookup: Task<Void, Never>?
    private var publicRequestID = UUID()
    private var activityRequestID = UUID()

    init(card: CardCandidate, publicPricing: any MarketPricing = OpenAPIMarketPricing.shared,
         opportunities: any OpportunitiesProviding = ConfiguredOpportunitiesProvider()) {
        self.card = card
        self.publicPricing = publicPricing
        self.opportunities = opportunities
    }

    func refresh(forceRefresh: Bool = true) {
        refreshPublic(forceRefresh: forceRefresh)
        refreshActivity(forceRefresh: forceRefresh)
    }

    func refreshPublic(forceRefresh: Bool = true) {
        cancelPublic()
        publicDetails = nil; publicMessage = nil; publicLoading = true
        let requestedCard = card, requestID = publicRequestID
        DiagnosticLog.shared.record("market_details.public_started", ["phase": "openapi"])
        publicLookup = Task { [weak self, publicPricing] in
            do {
                let details = try await publicPricing.details(for: requestedCard, candidates: [requestedCard], forceRefresh: forceRefresh)
                guard let self, !Task.isCancelled, self.publicRequestID == requestID else { return }
                self.publicDetails = details
                self.publicLoading = false; self.publicLookup = nil
                DiagnosticLog.shared.record("market_details.public_finished", ["phase": "openapi",
                    "priced": String(details.quote?.marketPrice != nil), "cache": details.metadata?.isOffline == true ? "offline" : (details.metadata?.isCached == true ? "cached" : "online")])
            } catch {
                guard let self, !Task.isCancelled, self.publicRequestID == requestID else { return }
                self.publicLoading = false; self.publicLookup = nil
                self.publicMessage = (error as? OpenAPIPricingFailure)?.errorDescription
                    ?? "Public market details could not connect. Check your connection and retry."
                DiagnosticLog.shared.record("market_details.public_failed", ServiceDiagnosticFields.failure(error)
                    .merging(["phase": "openapi"]) { _, value in value })
            }
        }
    }

    func refreshActivity(forceRefresh: Bool = true) {
        cancelActivity()
        activityDetails = nil; activityMessage = nil; activityLoading = true
        let requestedCard = card, requestID = activityRequestID
        DiagnosticLog.shared.record("market_details.activity_started", ["phase": "opportunities"])
        activityLookup = Task { [weak self, opportunities] in
            do {
                let details = try await opportunities.opportunities(for: requestedCard, forceRefresh: forceRefresh)
                guard let self, !Task.isCancelled, self.activityRequestID == requestID else { return }
                self.activityDetails = details
                self.activityLoading = false; self.activityLookup = nil
                DiagnosticLog.shared.record("market_details.activity_finished", ["phase": "opportunities"])
            } catch {
                guard let self, !Task.isCancelled, self.activityRequestID == requestID else { return }
                self.activityLoading = false; self.activityLookup = nil
                self.activityMessage = (error as? OpportunitiesFailure)?.errorDescription
                    ?? "Market activity could not connect. Check your connection and retry."
                DiagnosticLog.shared.record("market_details.activity_failed", ServiceDiagnosticFields.failure(error)
                    .merging(["phase": "opportunities"]) { _, value in value })
            }
        }
    }

    func changeCard(_ card: CardCandidate) {
        cancel()
        self.card = card
        refresh(forceRefresh: false)
    }

    func cancel() { cancelPublic(); cancelActivity() }

    private func cancelPublic() {
        publicRequestID = UUID(); publicLookup?.cancel(); publicLookup = nil; publicLoading = false
    }

    private func cancelActivity() {
        activityRequestID = UUID(); activityLookup?.cancel(); activityLookup = nil; activityLoading = false
    }
}
