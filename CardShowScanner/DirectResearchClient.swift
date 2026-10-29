import Foundation
import CryptoKit

/// User-entered credentials for the fixed Beta origin. They are never bundled,
/// included in diagnostic fields, or used as the app-to-server device token.
struct DirectResearchCredentials: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let shipperID: String
    let apiKey: String
    var description: String { "DirectResearchCredentials(<redacted>)" }
    var debugDescription: String { description }

    static func validated(shipperID: String, apiKey: String) throws -> Self {
        let shipperID = shipperID.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(shipperID.utf8.count), (1...512).contains(apiKey.utf8.count),
              [shipperID, apiKey].allSatisfy({ $0.utf8.allSatisfy { (0x21...0x7e).contains($0) } }) else {
            throw ResearchFailure.directNotConfigured
        }
        return Self(shipperID: shipperID, apiKey: apiKey)
    }

    fileprivate var cacheNamespace: String {
        SHA256.hash(data: Data((shipperID + "\0" + apiKey).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Direct access still requires Beta Research entitlement and the phone's
/// current public network IP on the provider's allowlist.
struct DirectResearchClient: ResearchProviding {
    static let maximumSetBytes = 8 * 1_024 * 1_024
    private let credentials: DirectResearchCredentials
    private let resolver: any OpenAPISetResolving
    private let loader: any ResearchHTTPDataLoading
    private let cache: DirectResearchSetCache
    private let now: @Sendable () -> Date

    init(credentials: DirectResearchCredentials,
         resolver: any OpenAPISetResolving = NativeOpenAPISetResolver.shared,
         loader: any ResearchHTTPDataLoading = NativeResearchHTTPDataLoader(maximumBytes: DirectResearchClient.maximumSetBytes),
         cache: DirectResearchSetCache = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials; self.resolver = resolver; self.loader = loader; self.cache = cache; self.now = now
    }

    func research(for card: CardCandidate, forceRefresh: Bool) async throws -> ResearchProductDetails {
        try Task.checkCancellation()
        let checked = try DirectResearchCredentials.validated(shipperID: credentials.shipperID, apiKey: credentials.apiKey)
        guard let category = OpenAPIMarketPricing.categoryID(card.identity.game),
              let productText = OpenAPIMarketPricing.productID(card.identity.productID),
              let product = Int(productText), product > 0 else { throw ResearchFailure.unsupportedCard }
        guard let group = try await resolver.setID(for: card), group > 0 else { throw ResearchFailure.catalogUnavailable }
        try Task.checkCancellation()
        let key = checked.cacheNamespace + ":\(category):\(group)"
        let cached = await cache.entry(for: key)
        try Task.checkCancellation()
        if let cached, now().timeIntervalSince(cached.checkedAt) >= 0,
           now().timeIntervalSince(cached.checkedAt) < 3_600 {
            return try Self.product(from: cached.data, category: category, group: group, product: product)
        }
        var request = Self.request(path: "/v1/\(category)/sets/\(group)/research", credentials: checked)
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if forceRefresh { request.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
        let (data, response) = try await fetch(request)
        if response.statusCode == 304 {
            guard let cached else { throw ResearchFailure.invalidResponse }
            let result = try Self.product(from: cached.data, category: category, group: group, product: product)
            await cache.store(.init(data: cached.data, etag: Self.etag(response) ?? cached.etag, checkedAt: now()), for: key)
            return result
        }
        try Self.checkStatus(response.statusCode)
        // Validate identity even for a legitimately missing product before
        // accepting this set into the hourly, in-memory cache.
        let result: ResearchProductDetails?
        do { result = try Self.product(from: data, category: category, group: group, product: product) }
        catch ResearchFailure.notCovered { result = nil }
        try Task.checkCancellation()
        await cache.store(.init(data: data, etag: Self.etag(response), checkedAt: now()), for: key)
        guard let result else { throw ResearchFailure.notCovered }
        return result
    }

    /// A real authenticated request tests the current phone/network allowlist.
    /// This does not claim any particular product or grade has coverage.
    func testConnection() async throws {
        let checked = try DirectResearchCredentials.validated(shipperID: credentials.shipperID, apiKey: credentials.apiKey)
        let (data, response) = try await fetch(Self.request(path: "/v1/research/meta", credentials: checked))
        try Self.checkStatus(response.statusCode)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["error"] == nil, (object["success"] as? Bool) != false else { throw ResearchFailure.invalidResponse }
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch {
            try Task.checkCancellation()
            throw (error as? ResearchFailure) ?? ResearchFailure.networkUnavailable
        }
        try Task.checkCancellation()
        guard response.url == request.url else { throw ResearchFailure.invalidResponse }
        guard data.count <= Self.maximumSetBytes else { throw ResearchFailure.responseTooLarge }
        return (data, response)
    }

    private static func request(path: String, credentials: DirectResearchCredentials) -> URLRequest {
        // Paths contain only locally validated numeric catalog IDs. Credentials
        // cannot choose an origin, path, query, cookie jar or redirect target.
        var request = URLRequest(url: URL(string: "https://beta.tcgtracking.com" + path)!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credentials.shipperID, forHTTPHeaderField: "X-Shipper-Id")
        request.setValue(credentials.apiKey, forHTTPHeaderField: "X-Api-Key")
        return request
    }

    private static func checkStatus(_ status: Int) throws {
        switch status {
        case 200: return
        case 401: throw ResearchFailure.directAuthorizationRequired
        case 403: throw ResearchFailure.accessDenied
        case 204, 404: throw ResearchFailure.notCovered
        default: throw ResearchFailure.serviceUnavailable(status)
        }
    }

    private static func etag(_ response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: "ETag"), value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private static func product(from data: Data, category: Int, group: Int, product: Int) throws -> ResearchProductDetails {
        guard data.count <= maximumSetBytes else { throw ResearchFailure.responseTooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = root["meta"] as? [String: Any], let products = root["products"] as? [String: Any],
              let metaData = try? JSONSerialization.data(withJSONObject: meta),
              let identity = try? JSONDecoder().decode(ResearchMetadata.self, from: metaData),
              identity.categoryID == category, identity.groupID == group else { throw ResearchFailure.invalidResponse }
        guard let selected = products[String(product)] else { throw ResearchFailure.notCovered }
        guard let selected = selected as? [String: Any],
              let normalized = try? JSONSerialization.data(withJSONObject: ["meta": meta, "product": selected]) else {
            throw ResearchFailure.invalidResponse
        }
        return try ResearchProductDetails.decode(normalized, expectedCategoryID: category, expectedGroupID: group, expectedProductID: product)
    }
}

/// Four set shards, kept in memory for the provider's hourly update cadence.
/// A credential digest separates accounts; nothing is persisted for offline use.
actor DirectResearchSetCache {
    static let shared = DirectResearchSetCache()
    struct Entry: Sendable { let data: Data; let etag: String?; let checkedAt: Date }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    func entry(for key: String) -> Entry? { entries[key] }
    func store(_ entry: Entry, for key: String) {
        entries[key] = entry; order.removeAll { $0 == key }; order.append(key)
        while order.count > 4 { entries.removeValue(forKey: order.removeFirst()) }
    }
    func clear() { entries.removeAll(); order.removeAll() }
}
