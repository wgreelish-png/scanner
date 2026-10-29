import Foundation

protocol ResearchProviding: Sendable {
    func research(for card: CardCandidate, forceRefresh: Bool) async throws -> ResearchProductDetails
}

protocol ResearchHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Only the user's research server receives this request. TCGTracking and PSA
/// account credentials belong on that server, never in this client.
struct ResearchClient: ResearchProviding {
    let baseURL: URL
    private let token: String?
    private let resolver: any OpenAPISetResolving
    private let loader: any ResearchHTTPDataLoading

    init(baseURL: URL, token: String? = nil,
         resolver: any OpenAPISetResolving = NativeOpenAPISetResolver.shared,
         loader: any ResearchHTTPDataLoading = NativeResearchHTTPDataLoader()) {
        self.baseURL = baseURL; self.token = token; self.resolver = resolver; self.loader = loader
    }

    func research(for card: CardCandidate, forceRefresh: Bool) async throws -> ResearchProductDetails {
        try Task.checkCancellation()
        guard Self.validBaseURL(baseURL) else { throw ResearchFailure.notConfigured }
        guard let category = OpenAPIMarketPricing.categoryID(card.identity.game),
              let productText = OpenAPIMarketPricing.productID(card.identity.productID),
              let product = Int(productText), product > 0 else { throw ResearchFailure.unsupportedCard }
        guard let group = try await resolver.setID(for: card), group > 0 else { throw ResearchFailure.catalogUnavailable }
        try Task.checkCancellation()
        let url = baseURL.appendingPathComponent("api/v1/research/\(category)/\(group)/\(product)")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if forceRefresh { request.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
        if let token, !token.isEmpty {
            guard token.count <= 4_096, !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ResearchFailure.notConfigured
            }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch {
            try Task.checkCancellation()
            if let failure = error as? ResearchFailure { throw failure }
            throw ResearchFailure.networkUnavailable
        }
        try Task.checkCancellation()
        guard response.url == url else { throw ResearchFailure.invalidResponse }
        switch response.statusCode {
        case 200: return try ResearchProductDetails.decode(data, expectedCategoryID: category, expectedGroupID: group, expectedProductID: product)
        case 401: throw ResearchFailure.authorizationRequired
        case 403: throw ResearchFailure.accessDenied
        case 204, 404: throw ResearchFailure.notCovered
        default: throw ResearchFailure.serviceUnavailable(response.statusCode)
        }
    }

    static func validBaseURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || (1...65_535).contains(url.port!),
              url.path.isEmpty || url.path == "/" else { return false }
        return true
    }
}

final class NativeResearchHTTPDataLoader: ResearchHTTPDataLoading, @unchecked Sendable {
    static let maximumBytes = 2 * 1_024 * 1_024
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: ResearchSessionDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw ResearchFailure.notConfigured }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == url else { throw ResearchFailure.invalidResponse }
        guard response.expectedContentLength <= Int64(Self.maximumBytes) else { throw ResearchFailure.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumBytes else { throw ResearchFailure.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
    private final class ResearchSessionDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }
}
