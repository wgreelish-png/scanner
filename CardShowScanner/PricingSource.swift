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

    static var current: PricingSource {
        guard let value = UserDefaults.standard.string(forKey: defaultsKey),
              let source = PricingSource(rawValue: value) else { return .tcgTracking }
        return source
    }
}

struct MarketPriceMetadata: Codable, Hashable, Sendable {
    var source: PricingSource
    var updatedAt: Date? = nil
    var fetchedAt: Date

    var summary: String {
        guard let updatedAt else { return source.title }
        return source.title + " • data updated " + updatedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Routes each lookup to one provider. Providers retain their own caches and
/// errors; changing the setting invalidates replies from the previous source.
struct SelectedMarketPricing: MarketPricing {
    private let legacy: any MarketPricing
    private let openAPI: any MarketPricing
    private let source: @Sendable () -> PricingSource

    init(legacy: any MarketPricing = OnlineMarketPricing(),
         openAPI: any MarketPricing = OpenAPIMarketPricing.shared,
         source: @escaping @Sendable () -> PricingSource = { .current }) {
        self.legacy = legacy
        self.openAPI = openAPI
        self.source = source
    }

    private func provider(for source: PricingSource) -> any MarketPricing {
        switch source {
        case .tcgTracking: return legacy
        case .openAPI: return openAPI
        }
    }

    func prepare() async {
        guard !Task.isCancelled else { return }
        await provider(for: source()).prepare()
    }

    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        try await details(for: card, candidates: [card], forceRefresh: false).quote
    }

    func quote(for card: CardCandidate, candidates: [CardCandidate]) async throws -> MarketQuote? {
        try await details(for: card, candidates: candidates, forceRefresh: false).quote
    }

    func details(for card: CardCandidate, candidates: [CardCandidate], forceRefresh: Bool) async throws -> MarketDetails {
        try Task.checkCancellation()
        let selected = source()
        var result: MarketDetails
        do {
            result = try await provider(for: selected).details(for: card, candidates: candidates, forceRefresh: forceRefresh)
        } catch {
            try validateSelection(selected)
            throw error
        }
        try validateSelection(selected)
        if result.metadata == nil {
            result.metadata = MarketPriceMetadata(source: selected, fetchedAt: Date())
        }
        return result
    }

    private func validateSelection(_ selected: PricingSource) throws {
        try Task.checkCancellation()
        guard source() == selected else { throw CancellationError() }
    }
}
