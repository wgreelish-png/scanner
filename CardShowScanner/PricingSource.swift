import Foundation

enum PricingSource: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case tcgTracking = "tcgtracking"
    case openAPI = "openapi"

    static let defaultsKey = "marketPricingSource"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tcgTracking: return "Existing TCGTracking"
        case .openAPI: return "Open API"
        }
    }

    // Retain both Codable cases for historical price provenance. The old
    // preference is intentionally ignored and never rewrites saved card data.
    static var current: PricingSource { .openAPI }
}

struct MarketPriceMetadata: Codable, Hashable, Sendable {
    var source: PricingSource
    var updatedAt: Date? = nil
    var fetchedAt: Date
    var isOffline: Bool? = nil
    var isCached: Bool? = nil

    var summary: String {
        if isOffline == true || isCached == true {
            let date = updatedAt ?? fetchedAt
            let label = updatedAt == nil ? "retrieved " : "data updated "
            let state = isOffline == true ? "cached / offline" : "cached"
            return source.title + " • " + state + " • " + label + date.formatted(date: .abbreviated, time: .shortened)
        }
        guard let updatedAt else { return source.title }
        return source.title + " • data updated " + updatedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// One production provider for scanner, search and saved-card edits. No website
/// browser is constructed, warmed up or used as a fallback for market quotes.
struct StandardMarketPricing: MarketPricing {
    private let provider: any MarketPricing

    init(provider: any MarketPricing = OpenAPIMarketPricing.shared) { self.provider = provider }

    func prepare() async {
        guard !Task.isCancelled else { return }
        await provider.prepare()
    }

    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        try await details(for: card, candidates: [card], forceRefresh: false).quote
    }

    func quote(for card: CardCandidate, candidates: [CardCandidate]) async throws -> MarketQuote? {
        try await details(for: card, candidates: candidates, forceRefresh: false).quote
    }

    func details(for card: CardCandidate, candidates: [CardCandidate], forceRefresh: Bool) async throws -> MarketDetails {
        try Task.checkCancellation()
        var result: MarketDetails
        do {
            result = try await provider.details(for: card, candidates: candidates, forceRefresh: forceRefresh)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        if result.metadata == nil {
            result.metadata = MarketPriceMetadata(source: .openAPI, fetchedAt: Date())
        }
        return result
    }
}
