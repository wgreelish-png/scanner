import Foundation
import CryptoKit

protocol OpportunitiesProviding: Sendable {
    func opportunities(for card: CardCandidate, forceRefresh: Bool) async throws -> OpportunitiesDetails
}

struct ConfiguredOpportunitiesProvider: OpportunitiesProviding {
    func opportunities(for card: CardCandidate, forceRefresh: Bool) async throws -> OpportunitiesDetails {
        try Task.checkCancellation()
        let store = ResearchConnectionStore()
        let method = try ResearchAccessMethod.selected(store: store)
        await ServiceDiagnosticFields.record("opportunities.provider_selected", method: method, phase: .setup)
        switch method {
        case .direct:
            guard let credentials = try store.loadDirect() else { throw OpportunitiesFailure.directNotConfigured }
            return try await DirectOpportunitiesClient(credentials: credentials).opportunities(for: card, forceRefresh: forceRefresh)
        case .server:
            guard let connection = try store.load() else { throw OpportunitiesFailure.notConfigured }
            return try await OpportunitiesClient(baseURL: connection.baseURL, token: connection.deviceToken)
                .opportunities(for: card, forceRefresh: forceRefresh)
        }
    }
}

/// A fixed Beta origin and separate OppsV2 endpoint; Research coverage is irrelevant.
struct DirectOpportunitiesClient: OpportunitiesProviding {
    static let maximumSetBytes = OpportunitiesDetails.maximumBytes
    private let credentials: DirectResearchCredentials
    private let resolver: any OpenAPISetResolving
    private let loader: any ResearchHTTPDataLoading
    private let cache: OpportunitiesSetCache
    private let now: @Sendable () -> Date

    init(credentials: DirectResearchCredentials,
         resolver: any OpenAPISetResolving = NativeOpenAPISetResolver.shared,
         loader: any ResearchHTTPDataLoading = NativeResearchHTTPDataLoader(maximumBytes: DirectOpportunitiesClient.maximumSetBytes),
         cache: OpportunitiesSetCache = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials; self.resolver = resolver; self.loader = loader; self.cache = cache; self.now = now
    }

    func opportunities(for card: CardCandidate, forceRefresh: Bool) async throws -> OpportunitiesDetails {
        try Task.checkCancellation()
        let checked = try checkedCredentials()
        let identity = try await OpportunitiesRequestIdentity.resolve(card, using: resolver)
        let account = OpportunitiesTransport.namespace(["direct", checked.shipperID, checked.apiKey])
        let request = Self.request(path: "/v1/\(identity.category)/sets/\(identity.group)", credentials: checked)
        return try await OpportunitiesTransport.load(request: request, key: account + ":\(identity.category):\(identity.group)",
            account: account, forceRefresh: forceRefresh, method: .direct, loader: loader, cache: cache, now: now) { data in
                try OpportunitiesDetails.decodeSet(data, for: card, expectedCategoryID: identity.category,
                    expectedGroupID: identity.group, expectedProductID: identity.product)
            }
    }

    /// Authenticated OppsV2 metadata checks this service's entitlement/allowlist.
    /// A successful response says nothing about coverage for an individual SKU.
    func testConnection() async throws {
        try Task.checkCancellation()
        let checked = try checkedCredentials()
        let account = OpportunitiesTransport.namespace(["direct", checked.shipperID, checked.apiKey])
        try await cache.checkCooldown(account: account, now: now())
        let (data, response) = try await OpportunitiesTransport.fetch(Self.request(path: "/v1/meta", credentials: checked),
            loader: loader, method: .direct, phase: .opportunitiesMeta)
        try await OpportunitiesTransport.checkStatus(response, method: .direct, account: account, cache: cache, now: now())
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["error"] == nil, (object["success"] as? Bool) != false,
              object["categories"] is [String: Any] else { throw OpportunitiesFailure.invalidResponse }
        try Task.checkCancellation()
    }

    private func checkedCredentials() throws -> DirectResearchCredentials {
        do { return try .validated(shipperID: credentials.shipperID, apiKey: credentials.apiKey) }
        catch { throw OpportunitiesFailure.directNotConfigured }
    }

    private static func request(path: String, credentials: DirectResearchCredentials) -> URLRequest {
        // Every path segment is locally generated from validated numeric IDs.
        var request = URLRequest(url: URL(string: "https://beta.tcgtracking.com" + path)!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credentials.shipperID, forHTTPHeaderField: "X-Shipper-Id")
        request.setValue(credentials.apiKey, forHTTPHeaderField: "X-Api-Key")
        return request
    }
}

/// Own-server access uses only the origin-bound device token, never Beta keys.
struct OpportunitiesClient: OpportunitiesProviding {
    let baseURL: URL
    private let token: String
    private let resolver: any OpenAPISetResolving
    private let loader: any ResearchHTTPDataLoading
    private let cache: OpportunitiesSetCache
    private let now: @Sendable () -> Date

    init(baseURL: URL, token: String,
         resolver: any OpenAPISetResolving = NativeOpenAPISetResolver.shared,
         loader: any ResearchHTTPDataLoading = NativeResearchHTTPDataLoader(maximumBytes: OpportunitiesDetails.maximumBytes),
         cache: OpportunitiesSetCache = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL; self.token = token; self.resolver = resolver; self.loader = loader; self.cache = cache; self.now = now
    }

    func opportunities(for card: CardCandidate, forceRefresh: Bool) async throws -> OpportunitiesDetails {
        try Task.checkCancellation()
        let configuration: ResearchServerConfiguration
        do { configuration = try .validated(address: baseURL.absoluteString, token: token) }
        catch { throw OpportunitiesFailure.notConfigured }
        let identity = try await OpportunitiesRequestIdentity.resolve(card, using: resolver)
        let account = OpportunitiesTransport.namespace(["server", configuration.baseURL.absoluteString, configuration.deviceToken])
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("api/v1/opportunities/\(identity.category)/\(identity.group)/\(identity.product)"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + configuration.deviceToken, forHTTPHeaderField: "Authorization")
        return try await OpportunitiesTransport.load(request: request,
            key: account + ":\(identity.category):\(identity.group):\(identity.product)", account: account,
            forceRefresh: forceRefresh, method: .server, loader: loader, cache: cache, now: now) { data in
                try OpportunitiesDetails.decode(data, for: card, expectedCategoryID: identity.category,
                    expectedGroupID: identity.group, expectedProductID: identity.product)
            }
    }
}

private struct OpportunitiesRequestIdentity: Sendable {
    let category: Int
    let group: Int
    let product: Int
    static func resolve(_ card: CardCandidate, using resolver: any OpenAPISetResolving) async throws -> Self {
        guard card.requiresPrintingSelection != true,
              let category = OpenAPIMarketPricing.categoryID(card.identity.game),
              let product = OpenAPIMarketPricing.productID(card.identity.productID).flatMap(Int.init), product > 0,
              (1...250).contains(card.identity.printing.count), !OpportunitiesIdentity.normalized(card.identity.printing).isEmpty,
              OpportunitiesIdentity.language(card.identity.language) != nil,
              OpportunitiesIdentity.condition(card.identity.condition) != nil else { throw OpportunitiesFailure.unsupportedCard }
        let group: Int?
        do { group = try await resolver.setID(for: card) }
        catch { try Task.checkCancellation(); throw OpportunitiesFailure.catalogUnavailable }
        try Task.checkCancellation()
        guard let group, group > 0 else { throw OpportunitiesFailure.catalogUnavailable }
        return Self(category: category, group: group, product: product)
    }
}

private enum OpportunitiesTransport {
    static func namespace(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func load(request: URLRequest, key: String, account: String, forceRefresh: Bool,
                     method: ResearchAccessMethod, loader: any ResearchHTTPDataLoading, cache: OpportunitiesSetCache,
                     now: @Sendable () -> Date,
                     decode: @Sendable (Data) throws -> OpportunitiesDetails) async throws -> OpportunitiesDetails {
        try Task.checkCancellation()
        let lookup = try await cache.lookup(key: key, account: account, now: now())
        try Task.checkCancellation()
        switch lookup {
        case .fresh(let entry):
            let result = try decode(entry.data)
            try Task.checkCancellation()
            return result
        case .request(let ticket):
            do {
                var request = request
                if let etag = ticket.previous?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                if forceRefresh { request.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
                let (body, response) = try await fetch(request, loader: loader, method: method, phase: .opportunitiesProduct)
                try await cache.requireCurrent(ticket)
                let data: Data
                if response.statusCode == 304 {
                    guard let previous = ticket.previous else { throw OpportunitiesFailure.invalidResponse }
                    data = previous.data
                } else {
                    if response.statusCode == 404 || response.statusCode == 204 { try await cache.invalidate(ticket) }
                    try await checkStatus(response, method: method, account: account, cache: cache, now: now())
                    data = body
                }
                // A valid shard can be cached when this product/SKU lacks coverage.
                // All other decode failures are rejected before any cache mutation.
                let result: Result<OpportunitiesDetails, OpportunitiesFailure>
                do { result = .success(try decode(data)) }
                catch OpportunitiesFailure.notCovered {
                    // The direct decoder validates metadata/products before reporting missing product.
                    result = .failure(.notCovered)
                } catch OpportunitiesFailure.skuNotCovered { result = .failure(.skuNotCovered) }
                try Task.checkCancellation()
                try await cache.store(.init(data: data, etag: etag(response) ?? (response.statusCode == 304 ? ticket.previous?.etag : nil),
                                            checkedAt: now()), ticket: ticket)
                try Task.checkCancellation()
                return try result.get()
            } catch {
                await cache.finish(ticket)
                try Task.checkCancellation()
                throw error
            }
        }
    }

    static func fetch(_ request: URLRequest, loader: any ResearchHTTPDataLoading,
                      method: ResearchAccessMethod, phase: ServiceDiagnosticFields.Phase) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let started = Date()
        await ServiceDiagnosticFields.record("opportunities.http_started", method: method, phase: phase)
        try Task.checkCancellation()
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch {
            try Task.checkCancellation()
            let failure: OpportunitiesFailure
            if let typed = error as? OpportunitiesFailure { failure = typed }
            else if error as? ResearchFailure == .responseTooLarge { failure = .responseTooLarge }
            else if error as? ResearchFailure == .invalidResponse { failure = .invalidResponse }
            else { failure = .networkUnavailable }
            await ServiceDiagnosticFields.record("opportunities.http_failed", method: method, phase: phase, started: started, error: failure)
            throw failure
        }
        try Task.checkCancellation()
        await ServiceDiagnosticFields.record("opportunities.http_response", method: method, phase: phase,
                                             status: response.statusCode, started: started)
        try Task.checkCancellation()
        guard response.url == request.url else { throw OpportunitiesFailure.invalidResponse }
        guard data.count <= OpportunitiesDetails.maximumBytes else { throw OpportunitiesFailure.responseTooLarge }
        return (data, response)
    }

    static func checkStatus(_ response: HTTPURLResponse, method: ResearchAccessMethod, account: String,
                            cache: OpportunitiesSetCache, now: Date) async throws {
        switch response.statusCode {
        case 200: return
        case 401: throw method == .direct ? OpportunitiesFailure.directAuthorizationRequired : .authorizationRequired
        case 403: throw OpportunitiesFailure.accessDenied
        case 204, 404: throw OpportunitiesFailure.notCovered
        case 429:
            await cache.coolDown(account: account, until: now.addingTimeInterval(retryAfter(response, now: now)))
            throw OpportunitiesFailure.rateLimited
        default:
            if response.statusCode == 503, response.value(forHTTPHeaderField: "Retry-After") != nil {
                await cache.coolDown(account: account, until: now.addingTimeInterval(retryAfter(response, now: now)), failure: .serviceUnavailable(503))
            }
            throw OpportunitiesFailure.serviceUnavailable(response.statusCode)
        }
    }

    private static func retryAfter(_ response: HTTPURLResponse, now: Date) -> TimeInterval {
        guard let text = response.value(forHTTPHeaderField: "Retry-After"), text.count <= 128 else { return 60 }
        if let seconds = Double(text), seconds.isFinite, seconds >= 0 { return min(86_400, max(1, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: text) else { return 60 }
        return min(86_400, max(1, date.timeIntervalSince(now)))
    }

    private static func etag(_ response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: "ETag"), value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
}

/// Four bounded in-memory bodies. Account digests include method, origin and
/// credential material; a clear/newer request invalidates every older ticket.
/// Fresh bodies honor the provider's hourly cadence even on explicit refresh.
actor OpportunitiesSetCache {
    static let shared = OpportunitiesSetCache()
    struct Entry: Sendable { let data: Data; let etag: String?; let checkedAt: Date }
    struct Ticket: Sendable { let key: String; let generation: UUID; let epoch: UUID; let previous: Entry? }
    enum Lookup: Sendable { case fresh(Entry), request(Ticket) }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var requests: [String: UUID] = [:]
    private var epoch = UUID()
    private struct Cooldown: Sendable { let until: Date; let failure: OpportunitiesFailure }
    private var cooldowns: [String: Cooldown] = [:]
    var cachedEntryCount: Int { entries.count }

    func lookup(key: String, account: String, now: Date) throws -> Lookup {
        if let entry = entries[key], now >= entry.checkedAt, now.timeIntervalSince(entry.checkedAt) < 3_600 { return .fresh(entry) }
        try checkCooldown(account: account, now: now)
        let generation = UUID(); requests[key] = generation
        return .request(Ticket(key: key, generation: generation, epoch: epoch, previous: entries[key]))
    }
    func requireCurrent(_ ticket: Ticket) throws {
        guard epoch == ticket.epoch, requests[ticket.key] == ticket.generation else { throw CancellationError() }
    }
    func store(_ entry: Entry, ticket: Ticket) throws {
        try Task.checkCancellation()
        try requireCurrent(ticket)
        entries[ticket.key] = entry; order.removeAll { $0 == ticket.key }; order.append(ticket.key)
        requests[ticket.key] = nil
        while order.count > 4 { entries[order.removeFirst()] = nil }
    }
    func finish(_ ticket: Ticket) {
        if epoch == ticket.epoch, requests[ticket.key] == ticket.generation { requests[ticket.key] = nil }
    }
    func invalidate(_ ticket: Ticket) throws {
        try requireCurrent(ticket)
        entries[ticket.key] = nil; order.removeAll { $0 == ticket.key }
    }
    func checkCooldown(account: String, now: Date) throws {
        if let cooldown = cooldowns[account], cooldown.until > now { throw cooldown.failure }
        cooldowns[account] = nil
    }
    func coolDown(account: String, until: Date, failure: OpportunitiesFailure = .rateLimited) {
        if (cooldowns[account]?.until ?? .distantPast) <= until { cooldowns[account] = Cooldown(until: until, failure: failure) }
        if cooldowns.count > 16, let oldest = cooldowns.min(by: { $0.value.until < $1.value.until })?.key { cooldowns[oldest] = nil }
    }
    func clear() {
        epoch = UUID(); entries.removeAll(); order.removeAll(); requests.removeAll(); cooldowns.removeAll()
    }
}
