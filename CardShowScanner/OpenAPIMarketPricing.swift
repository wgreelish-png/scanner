import Foundation

/// Public OpenAPI errors never imply that signing into the website is needed.
enum OpenAPIPricingFailure: LocalizedError, Equatable {
    case httpStatus(Int), invalidResponse, responseTooLarge, unsupportedCard, catalogUnavailable
    var errorDescription: String? {
        switch self {
        case .unsupportedCard: return "Public pricing supports only TCGplayer products in Pokémon, Magic, and Yu-Gi-Oh! Choose Existing TCGTracking for other cards."
        case .catalogUnavailable: return "The saved catalog cannot locate this card’s set. Refresh the card database or choose Existing TCGTracking."
        case .httpStatus(let status): return "Public pricing is unavailable (HTTP \(status)). Retry Market Price or save this card unpriced."
        case .invalidResponse: return "Public pricing returned an unsupported response. Retry Market Price or save this card unpriced."
        case .responseTooLarge: return "This public pricing response is too large. You can save this card unpriced."
        }
    }
}

protocol OpenAPIHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// A separate, credential-free session; a redirect is never followed.
final class NativeOpenAPIHTTPDataLoader: OpenAPIHTTPDataLoading, @unchecked Sendable {
    static let maximumBytes = 8 * 1_024 * 1_024
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: PublicOnlyDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard Self.allows(request.url) else { throw OpenAPIPricingFailure.invalidResponse }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw OpenAPIPricingFailure.invalidResponse }
        guard response.expectedContentLength <= Int64(Self.maximumBytes) else { throw OpenAPIPricingFailure.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumBytes else { throw OpenAPIPricingFailure.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
    static func allows(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == "openapi.tcgtracking.com" && (url.port == nil || url.port == 443) &&
            url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
            url.path.range(of: #"^/v1/(?:[123]/sets/[1-9][0-9]*/skus|products/[1-9][0-9]{0,11})\z"#, options: .regularExpression) != nil
    }
    private final class PublicOnlyDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }
}

struct OpenAPIMarketPricing: MarketPricing {
    static let shared = OpenAPIMarketPricing()
    private let resolver: any OpenAPISetResolving
    private let loader: any OpenAPIHTTPDataLoading
    private let now: @Sendable () -> Date
    private let cache: OpenAPISetPriceCache
    init(resolver: any OpenAPISetResolving = CatalogOpenAPISetResolver.shared,
         loader: any OpenAPIHTTPDataLoading = NativeOpenAPIHTTPDataLoader(),
         now: @escaping @Sendable () -> Date = { Date() },
         cacheDirectory: URL? = OpenAPIPriceDiskCache.defaultDirectory) {
        self.resolver = resolver; self.loader = loader; self.now = now
        self.cache = OpenAPISetPriceCache(directory: cacheDirectory)
    }
    func quote(for card: CardCandidate) async throws -> MarketQuote? { try await quote(for: card, candidates: [card]) }
    func quote(for card: CardCandidate, candidates: [CardCandidate]) async throws -> MarketQuote? {
        try await details(for: card, candidates: candidates, forceRefresh: false).quote
    }
    func details(for card: CardCandidate, candidates: [CardCandidate], forceRefresh: Bool) async throws -> MarketDetails {
        try Task.checkCancellation()
        guard Self.productID(card.identity.productID) != nil, let category = Self.categoryID(card.identity.game) else { throw OpenAPIPricingFailure.unsupportedCard }
        guard let set = try await resolver.setID(for: card), set > 0 else { throw OpenAPIPricingFailure.catalogUnavailable }
        let url = URL(string: "https://openapi.tcgtracking.com/v1/\(category)/sets/\(set)/skus")!
        let entry = try await cache.entry(for: url, forceRefresh: forceRefresh, loader: loader, now: now, expectedSetID: set)
        try Task.checkCancellation()
        return try Self.parseDetails(entry.data, for: card, candidates: candidates, fetchedAt: entry.fetchedAt, expectedSetID: set, isOffline: entry.isOffline)
    }
    static func categoryID(_ game: String) -> Int? {
        switch game { case "Pokémon": return 3; case "Magic: The Gathering": return 1; case "Yu-Gi-Oh!": return 2; default: return nil }
    }
    static func productID(_ reference: String) -> String? {
        guard reference.hasPrefix("p:") else { return nil }
        let value = String(reference.dropFirst(2))
        guard numericID(value, maximumLength: 12) else { return nil }
        return value
    }
    private static func numericID(_ value: String, maximumLength: Int) -> Bool {
        (1...maximumLength).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
    static func parseDetails(_ data: Data, for card: CardCandidate, candidates: [CardCandidate] = [],
                             fetchedAt: Date = Date(), expectedSetID: Int? = nil, isOffline: Bool = false) throws -> MarketDetails {
        let body: SKUSet
        do { body = try JSONDecoder().decode(SKUSet.self, from: data) }
        catch { throw OpenAPIPricingFailure.invalidResponse }
        guard expectedSetID == nil || body.set_id == expectedSetID else { throw OpenAPIPricingFailure.invalidResponse }
        guard let product = productID(card.identity.productID), categoryID(card.identity.game) != nil else { return MarketDetails(quote: nil) }
        var choices: [String: [String]] = [:]
        for candidate in [card] + candidates where candidate.identity.game == card.identity.game {
            guard let id = productID(candidate.identity.productID), let rows = body.products[id] else { continue }
            choices[candidate.identity.productID] = Array(Set(rows.values.map(\.variant).filter { !$0.isEmpty && $0.count <= 1_000 })).sorted()
        }
        let printings = choices[card.identity.productID] ?? []
        guard let rows = body.products[product] else { return MarketDetails(quote: nil, printingsByProduct: choices) }
        let metadata = MarketPriceMetadata(source: .openAPI, updatedAt: timestamp(body.updated), fetchedAt: fetchedAt, isOffline: isOffline ? true : nil)
        var result = MarketDetails(quote: nil, printings: printings, printingsByProduct: choices, metadata: metadata)
        let languages = ["english": "EN", "japanese": "JP", "french": "FR", "german": "DE", "italian": "IT", "spanish": "ES",
                         "portuguese": "PT", "russian": "RU", "korean": "KO", "simplified chinese": "CS", "traditional chinese": "CT"]
        let conditions = ["near mint": "NM", "lightly played": "LP", "moderately played": "MP", "heavily played": "HP", "damaged": "DMG"]
        let languageInput = normalized(card.identity.language), conditionInput = normalized(card.identity.condition)
        let language = languages[languageInput] ?? (Set(languages.values).contains(languageInput.uppercased()) ? languageInput.uppercased() : nil)
        let condition = conditions[conditionInput] ?? (Set(conditions.values).contains(conditionInput.uppercased()) ? conditionInput.uppercased() : nil)
        guard let language, let condition else { return result }
        let matches = rows.filter { sku, row in
            numericID(sku, maximumLength: 20) &&
            row.language == language && row.condition == condition && normalized(row.variant) == normalized(card.identity.printing)
        }
        // Even equal prices do not make two different SKU identities interchangeable.
        guard matches.count == 1, let match = matches.first else { return result }
        result.quote = MarketQuote(marketPrice: match.value.market.value, skuID: match.key)
        let row = match.value
        if row.low.value != nil || row.high.value != nil || row.count.value != nil {
            result.context = MarketPriceContext(lowPrice: row.low.value, highPrice: row.high.value, listingCount: row.count.value)
        }
        return result
    }
    static func validate(_ data: Data, expectedSetID: Int, now: Date? = nil) throws {
        guard let body = try? JSONDecoder().decode(SKUSet.self, from: data), body.set_id == expectedSetID else { throw OpenAPIPricingFailure.invalidResponse }
        if let now, let updated = timestamp(body.updated), updated > now { throw OpenAPIPricingFailure.invalidResponse }
    }
    private static func timestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }
    private struct SKUSet: Decodable { var set_id: Int; var updated: String?; var products: [String: [String: Row]] }
    private struct Row: Decodable {
        var condition: String; var variant: String; var language: String; var market: Price
        var low: Price; var high: Price; var count: ListingCount
        enum CodingKeys: String, CodingKey {
            case condition = "cnd", variant = "var", language = "lng", market = "mkt"
            case low, high = "hi", count = "cnt"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            condition = try c.decode(String.self, forKey: .condition); variant = try c.decode(String.self, forKey: .variant)
            language = try c.decode(String.self, forKey: .language)
            market = try c.decodeIfPresent(Price.self, forKey: .market) ?? Price(value: nil)
            low = (try? c.decodeIfPresent(Price.self, forKey: .low)) ?? Price(value: nil)
            high = (try? c.decodeIfPresent(Price.self, forKey: .high)) ?? Price(value: nil)
            count = (try? c.decodeIfPresent(ListingCount.self, forKey: .count)) ?? ListingCount(value: nil)
        }
    }
    private struct ListingCount: Decodable {
        var value: Int?
        init(value: Int?) { self.value = value }
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() || (try? c.decode(Bool.self)) != nil { value = nil; return }
            if let text = try? c.decode(String.self), text.range(of: #"^[0-9]+\z"#, options: .regularExpression) != nil { value = Int(text) }
            else { value = try? c.decode(Int.self) }
            if value.map({ $0 < 0 }) == true { value = nil }
        }
    }
    private struct Price: Decodable {
        var value: Decimal?
        init(value: Decimal?) { self.value = value }
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() || (try? c.decode(Bool.self)) != nil { value = nil; return }
            if let string = try? c.decode(String.self) {
                guard string.range(of: #"^-?[0-9]+(\.[0-9]+)?\z"#, options: .regularExpression) != nil else { value = nil; return }
                value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
            } else { value = try? c.decode(Decimal.self) }
            if value.map({ $0.isNaN || $0 < 0 }) == true { value = nil }
        }
    }
}

/// A brief memory cache backed by four bounded public set bodies on disk.
/// Connectivity fallback keeps the original fetch and provider timestamps.
/// A newer request or cancellation always supersedes an older response.
private actor OpenAPISetPriceCache {
    struct Entry: Sendable {
        var data: Data; var etag: String?; var fetchedAt: Date; var validatedAt: Date
        var isOffline = false
        var saved: OpenAPIPriceDiskCache.Entry {
            .init(data: data, etag: etag, fetchedAt: fetchedAt, validatedAt: validatedAt)
        }
    }
    private let disk: OpenAPIPriceDiskCache
    private var entries: [URL: Entry] = [:]
    private var requests: [URL: UUID] = [:]
    private var waiters: [URL: [UUID: CheckedContinuation<Entry, Error>]] = [:]
    init(directory: URL?) { disk = OpenAPIPriceDiskCache(directory: directory) }

    func entry(for url: URL, forceRefresh: Bool, loader: any OpenAPIHTTPDataLoading,
               now: @Sendable () -> Date, expectedSetID: Int) async throws -> Entry {
        try Task.checkCancellation()
        let current = now()
        if !forceRefresh, let entry = entries[url], fresh(entry, at: current) { return entry }
        if !forceRefresh, requests[url] != nil {
            do {
                let result = try await joinRequest(for: url)
                try Task.checkCancellation()
                return result
            } catch is CancellationError {
                try Task.checkCancellation()
                return try await entry(for: url, forceRefresh: false, loader: loader, now: now, expectedSetID: expectedSetID)
            }
        }
        let requestID = UUID(); requests[url] = requestID
        defer { if requests[url] == requestID { requests[url] = nil } }
        var previous = entries[url]
        if previous != nil { entries[url]?.validatedAt = .distantPast }
        do {
            if previous == nil, let saved = disk.entry(for: url, now: current) {
                try Task.checkCancellation()
                guard requests[url] == requestID else { throw CancellationError() }
                let restored = Entry(data: saved.data, etag: saved.etag, fetchedAt: saved.fetchedAt, validatedAt: saved.validatedAt)
                previous = restored
                // A process restart revalidates even a recent disk body. Only
                // a connectivity failure can turn disk data into an offline reply.
            }
            try Task.checkCancellation()
            guard requests[url] == requestID else { throw CancellationError() }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let etag = previous?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            let (data, response) = try await loader.data(for: request)
            try Task.checkCancellation()
            guard requests[url] == requestID else { throw CancellationError() }
            guard response.url == url else { throw OpenAPIPricingFailure.invalidResponse }
            guard data.count <= NativeOpenAPIHTTPDataLoader.maximumBytes else { throw OpenAPIPricingFailure.responseTooLarge }
            let fetchedAt = now()
            let result: Entry
            switch response.statusCode {
            case 200:
                // Invalid JSON and future provider dates cannot become reusable responses.
                try OpenAPIMarketPricing.validate(data, expectedSetID: expectedSetID, now: fetchedAt)
                result = Entry(data: data, etag: response.value(forHTTPHeaderField: "ETag"), fetchedAt: fetchedAt, validatedAt: fetchedAt)
            case 304:
                guard var previous else { throw OpenAPIPricingFailure.invalidResponse }
                previous.fetchedAt = fetchedAt; previous.validatedAt = fetchedAt; previous.isOffline = false; result = previous
            default: throw OpenAPIPricingFailure.httpStatus(response.statusCode)
            }
            // Synchronous persistence keeps the generation check and cache
            // publication together; a forced request cannot supersede mid-write.
            disk.store(result.saved, for: url, now: fetchedAt)
            try Task.checkCancellation()
            guard requests[url] == requestID else { throw CancellationError() }
            retain(result, for: url)
            finishWaiters(for: url, with: .success(result))
            return result
        } catch {
            let failure: Error = Task.isCancelled ? CancellationError() : error
            guard requests[url] == requestID else { throw CancellationError() }
            if OpenAPIConnectivityFailure.allowsOfflineFallback(failure), var previous,
               previous.fetchedAt <= current,
               (try? OpenAPIMarketPricing.validate(previous.data, expectedSetID: expectedSetID, now: current)) != nil {
                // Do not mark this as newly fetched/validated: retry online next time.
                previous.isOffline = true
                retain(previous, for: url)
                finishWaiters(for: url, with: .success(previous))
                return previous
            }
            finishWaiters(for: url, with: .failure(failure))
            throw failure
        }
    }
    private func fresh(_ entry: Entry, at date: Date) -> Bool {
        !entry.isOffline && date >= entry.fetchedAt && date >= entry.validatedAt && date < entry.validatedAt.addingTimeInterval(15 * 60)
    }
    private func retain(_ entry: Entry, for url: URL) {
        if entries[url] == nil, entries.count >= 4, let oldest = entries.min(by: { $0.value.validatedAt < $1.value.validatedAt })?.key { entries[oldest] = nil }
        entries[url] = entry
    }
    private func joinRequest(for url: URL) async throws -> Entry {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Entry, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiters[url, default: [:]][id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, for: url) }
        }
    }
    private func cancelWaiter(_ id: UUID, for url: URL) {
        let continuation = waiters[url]?.removeValue(forKey: id)
        if waiters[url]?.isEmpty == true { waiters[url] = nil }
        continuation?.resume(throwing: CancellationError())
    }
    private func finishWaiters(for url: URL, with result: Result<Entry, Error>) {
        let pending = waiters.removeValue(forKey: url) ?? [:]
        for continuation in pending.values { continuation.resume(with: result) }
    }
}
