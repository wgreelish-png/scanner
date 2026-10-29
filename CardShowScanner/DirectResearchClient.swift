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
    private let cadence: BetaAPICadence?

    init(credentials: DirectResearchCredentials,
         resolver: any OpenAPISetResolving = NativeOpenAPISetResolver.shared,
         loader: any ResearchHTTPDataLoading = NativeResearchHTTPDataLoader(maximumBytes: DirectResearchClient.maximumSetBytes),
         cache: DirectResearchSetCache = .shared, now: @escaping @Sendable () -> Date = { Date() },
         cadence: BetaAPICadence? = .shared) {
        self.credentials = credentials; self.resolver = resolver; self.loader = loader; self.cache = cache; self.now = now
        self.cadence = cadence
    }

    func research(for card: CardCandidate, forceRefresh: Bool) async throws -> ResearchProductDetails {
        try Task.checkCancellation()
        let checked = try DirectResearchCredentials.validated(shipperID: credentials.shipperID, apiKey: credentials.apiKey)
        guard let category = OpenAPIMarketPricing.categoryID(card.identity.game),
              let productText = OpenAPIMarketPricing.productID(card.identity.productID),
              let product = Int(productText), product > 0 else { throw ResearchFailure.unsupportedCard }
        guard let group = try await resolver.setID(for: card), group > 0 else { throw ResearchFailure.catalogUnavailable }
        try Task.checkCancellation()
        let key = BetaAPICadence.account(for: checked) + ":\(category):\(group)"
        let cached = await cache.entry(for: key, now: now())
        try Task.checkCancellation()
        let info: BetaAPISetInfo?
        do {
            info = try await cadence?.setInfo(family: .research, category: category, group: group,
                forceRefresh: forceRefresh, credentials: checked, loader: loader)
        } catch {
            try Task.checkCancellation()
            throw Self.safeFailure(error)
        }
        try Task.checkCancellation()
        if let cached {
            let dataHash = Self.dataETag(in: cached.data)
            if let expected = info?.dataETag, let actual = dataHash {
                if expected == actual {
                    let result = try Self.product(from: cached.data, category: category, group: group, product: product)
                    if let checkedAt = info?.checkedAt, checkedAt > cached.checkedAt {
                        await cache.revalidated(cached, for: key, checkedAt: checkedAt)
                        try Task.checkCancellation()
                    }
                    return result
                }
                // A changed provider data hash bypasses the time fallback.
            } else if now().timeIntervalSince(cached.checkedAt) >= 0,
                      now().timeIntervalSince(cached.checkedAt) < (cadence == nil ? 3_600 : BetaAPICadence.indexLifetime) {
                return try Self.product(from: cached.data, category: category, group: group, product: product)
            }
        }
        var request = Self.request(path: "/v1/\(category)/sets/\(group)/research", credentials: checked)
        // The shard HTTP validator is deliberately separate from meta.etag.
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if forceRefresh { request.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
        let requestID = await cache.beginRequest(for: key)
        do {
            let (data, response) = try await fetch(request, credentials: checked)
            let body: Data
            let httpETag: String?
            if response.statusCode == 304 {
                guard let cached else { throw ResearchFailure.invalidResponse }
                body = cached.data; httpETag = Self.etag(response) ?? cached.etag
            } else {
                try Self.checkStatus(response.statusCode)
                body = data; httpETag = Self.etag(response)
            }
            // Never accept a 304 or racing old shard that contradicts a known
            // index data hash. HTTP body hashes are not provider data hashes.
            if let expected = info?.dataETag, let actual = Self.dataETag(in: body), expected != actual {
                throw ResearchFailure.invalidResponse
            }
            let result: ResearchProductDetails?
            do { result = try Self.product(from: body, category: category, group: group, product: product) }
            catch ResearchFailure.notCovered { result = nil }
            try Task.checkCancellation()
            guard await cache.store(.init(data: body, etag: httpETag, checkedAt: now()), for: key, requestID: requestID) else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            guard let result else { throw ResearchFailure.notCovered }
            return result
        } catch {
            await cache.finishRequest(requestID, for: key)
            try Task.checkCancellation()
            throw error
        }
    }

    /// A real authenticated request tests the current phone/network allowlist.
    /// This does not claim any particular product or grade has coverage.
    func testConnection() async throws {
        let checked = try DirectResearchCredentials.validated(shipperID: credentials.shipperID, apiKey: credentials.apiKey)
        let (data, response) = try await fetch(Self.request(path: "/v1/research/meta", credentials: checked), credentials: checked)
        try Self.checkStatus(response.statusCode)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["error"] == nil, (object["success"] as? Bool) != false else { throw ResearchFailure.invalidResponse }
    }

    private func fetch(_ request: URLRequest, credentials: DirectResearchCredentials) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let started = Date()
        let phase: ServiceDiagnosticFields.Phase = request.url?.path == "/v1/research/meta" ? .researchMeta : .researchProduct
        await ServiceDiagnosticFields.record("research.http_started", method: .direct, phase: phase)
        try Task.checkCancellation()
        let data: Data, response: HTTPURLResponse
        do {
            if let cadence { (data, response) = try await cadence.send(request, credentials: credentials, loader: loader) }
            else { (data, response) = try await loader.data(for: request) }
        }
        catch {
            try Task.checkCancellation()
            await ServiceDiagnosticFields.record("research.http_failed", method: .direct, phase: phase, started: started, error: error)
            throw Self.safeFailure(error)
        }
        try Task.checkCancellation()
        await ServiceDiagnosticFields.record("research.http_response", method: .direct, phase: phase, status: response.statusCode, started: started)
        try Task.checkCancellation()
        guard response.url == request.url else { throw ResearchFailure.invalidResponse }
        guard data.count <= Self.maximumSetBytes else { throw ResearchFailure.responseTooLarge }
        return (data, response)
    }

    private static func safeFailure(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let failure = error as? ResearchFailure { return failure }
        if let failure = error as? BetaAPICadenceFailure {
            switch failure {
            case .httpStatus(let status):
                do { try checkStatus(status) } catch { return error }
                return ResearchFailure.invalidResponse
            case .responseTooLarge: return ResearchFailure.responseTooLarge
            case .networkUnavailable: return ResearchFailure.networkUnavailable
            case .invalidRequest, .invalidResponse: return ResearchFailure.invalidResponse
            }
        }
        return ResearchFailure.networkUnavailable
    }

    fileprivate static func dataETag(in data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = root["meta"] as? [String: Any], let value = meta["etag"] as? String,
              !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
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

/// Four account-separated set shards. Production persists them through the
/// shared Beta cache; explicitly created test caches keep memory only.
actor DirectResearchSetCache {
    static let shared = DirectResearchSetCache(disk: .shared)
    struct Entry: Sendable { let data: Data; let etag: String?; let checkedAt: Date }
    private let disk: BetaAPIDiskCache?
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var requests: [String: UUID] = [:]
    init(disk: BetaAPIDiskCache? = nil) { self.disk = disk }

    func entry(for key: String, now: Date = Date()) async -> Entry? {
        if let entry = entries[key], entry.checkedAt <= now { return entry }
        entries[key] = nil; order.removeAll { $0 == key }
        guard let saved = await disk?.entry(for: key, kind: .research), !Task.isCancelled else { return nil }
        // An actor hop to disk may overlap a newer successful shard response.
        if let entry = entries[key] { return entry }
        guard saved.checkedAt.timeIntervalSince1970.isFinite, saved.checkedAt <= now,
              Self.valid(saved.data, for: key) else {
            await disk?.remove(for: key, kind: .research)
            return nil
        }
        let entry = Entry(data: saved.data, etag: saved.httpETag, checkedAt: saved.checkedAt)
        retain(entry, for: key)
        return entry
    }
    func beginRequest(for key: String) -> UUID {
        let id = UUID(); requests[key] = id; return id
    }
    func finishRequest(_ id: UUID, for key: String) {
        if requests[key] == id { requests[key] = nil }
    }
    func revalidated(_ previous: Entry, for key: String, checkedAt: Date) async {
        // An old index check cannot overwrite a newer shard response while
        // marking unchanged data as verified.
        guard requests[key] == nil, entries[key]?.data == previous.data,
              checkedAt > previous.checkedAt else { return }
        _ = await store(.init(data: previous.data, etag: previous.etag, checkedAt: checkedAt), for: key)
    }
    @discardableResult func store(_ entry: Entry, for key: String, requestID: UUID? = nil) async -> Bool {
        guard !Task.isCancelled, Self.valid(entry.data, for: key),
              entry.checkedAt.timeIntervalSince1970.isFinite,
              requestID == nil || requests[key] == requestID else { return false }
        let previousData = entries[key]?.data
        await disk?.store(.init(data: entry.data, httpETag: entry.etag,
            dataETag: DirectResearchClient.dataETag(in: entry.data), checkedAt: entry.checkedAt), for: key, kind: .research)
        guard !Task.isCancelled, requestID == nil || requests[key] == requestID else { return false }
        if requestID == nil, entries[key]?.data != previousData { return false }
        if requestID == nil, let current = entries[key], current.checkedAt > entry.checkedAt { return false }
        retain(entry, for: key)
        if let requestID { finishRequest(requestID, for: key) }
        return true
    }
    private func retain(_ entry: Entry, for key: String) {
        entries[key] = entry; order.removeAll { $0 == key }; order.append(key)
        while order.count > 4 { entries.removeValue(forKey: order.removeFirst()) }
    }
    private static func valid(_ data: Data, for key: String) -> Bool {
        let fields = key.split(separator: ":")
        guard fields.count == 3, fields[0].count == 64,
              let category = Int(fields[1]), let group = Int(fields[2]),
              data.count <= DirectResearchClient.maximumSetBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = root["meta"] as? [String: Any], root["products"] is [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: meta),
              let identity = try? JSONDecoder().decode(ResearchMetadata.self, from: encoded) else { return false }
        return identity.categoryID == category && identity.groupID == group && category > 0 && group > 0
    }
    func clear() async {
        entries.removeAll(); order.removeAll(); requests.removeAll()
        await disk?.clear()
    }
}
