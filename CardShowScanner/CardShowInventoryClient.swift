import Foundation
import UIKit
import WebKit

@MainActor protocol CardShowInventoryProviding {
    func fetch(expectedLocationID: Int?) async throws -> CardShowInventorySnapshot
    func cancel()
}

protocol CardShowInventoryHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func cancel()
}
extension CardShowInventoryHTTPDataLoading { func cancel() {} }

/// A foreground, read-only bridge to the existing website account session.
/// Cookies enter an ephemeral, fixed-host HTTP session and never enter logs,
/// list data, Keychain API credentials, exports or the shared URLSession store.
@MainActor final class CardShowInventoryWebsiteClient: CardShowInventoryProviding {
    private let cookies: @MainActor () async -> [HTTPCookie]
    private let makeLoader: @MainActor ([HTTPCookie]) -> any CardShowInventoryHTTPDataLoading
    private let isActive: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private var generation = UUID()
    private var currentLoader: (any CardShowInventoryHTTPDataLoading)?

    init(cookies: @escaping @MainActor () async -> [HTTPCookie] = {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }, makeLoader: @escaping @MainActor ([HTTPCookie]) -> any CardShowInventoryHTTPDataLoading = {
        NativeCardShowInventoryHTTPDataLoader(cookies: $0)
    }, isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
       now: @escaping @MainActor () -> Date = Date.init) {
        self.cookies = cookies; self.makeLoader = makeLoader; self.isActive = isActive; self.now = now
    }

    func fetch(expectedLocationID: Int?) async throws -> CardShowInventorySnapshot {
        cancel()
        let id = generation
        try checkCurrent(id)
        let savedCookies = await cookies()
        try checkCurrent(id)
        let scoped = Self.accountCookies(savedCookies, now: now())
        guard !scoped.isEmpty else { throw CardShowInventoryFailure.signInRequired }
        let loader = makeLoader(scoped)
        currentLoader = loader
        let deadline = now().addingTimeInterval(120)
        defer {
            loader.cancel()
            if generation == id { currentLoader = nil }
        }
        return try await withTaskCancellationHandler {
            do {
                let locations = try await load(Self.locationsURL, phase: "locations", loader: loader, id: id, deadline: deadline)
                let location = try CardShowInventoryDecoder.location(locations, expectedID: expectedLocationID)
                let firstBody = try await load(Self.stockURL(locationID: location.id, page: 1), phase: "stock", loader: loader,
                                               id: id, deadline: deadline)
                let first = try CardShowInventoryDecoder.page(firstBody, location: location, requestedPage: 1)
                var rows = first.rows
                var seen = Set(rows.map(\.inventoryID))
                if first.pages > 1 {
                    for page in 2...first.pages {
                        let body = try await load(Self.stockURL(locationID: location.id, page: page), phase: "stock", loader: loader,
                                                  id: id, deadline: deadline)
                        let result = try CardShowInventoryDecoder.page(body, location: location, requestedPage: page)
                        guard result.total == first.total, result.pages == first.pages else { throw CardShowInventoryFailure.invalidResponse }
                        for row in result.rows {
                            guard seen.insert(row.inventoryID).inserted else { throw CardShowInventoryFailure.invalidResponse }
                            rows.append(row)
                        }
                    }
                }
                try checkCurrent(id)
                guard rows.count == first.total else { throw CardShowInventoryFailure.invalidResponse }
                return .init(location: location, rows: rows, fetchedAt: now())
            } catch {
                try checkCurrent(id)
                if let failure = error as? CardShowInventoryFailure { throw failure }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw CardShowInventoryFailure.networkUnavailable
            }
        } onCancel: {
            loader.cancel()
        }
    }

    func cancel() {
        generation = UUID(); currentLoader?.cancel(); currentLoader = nil
    }

    private func checkCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard generation == id, isActive() else { throw CancellationError() }
    }

    private func load(_ url: URL, phase: String, loader: any CardShowInventoryHTTPDataLoading,
                      id: UUID, deadline: Date) async throws -> Data {
        try checkCurrent(id)
        guard now() <= deadline else { throw CardShowInventoryFailure.networkUnavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("https://tcgtracking.com/dashboard.php?tab=inventory", forHTTPHeaderField: "Referer")
        let (data, response) = try await loader.data(for: request)
        try checkCurrent(id)
        DiagnosticLog.shared.record("card_show_inventory.http_response", ["phase": phase, "code": String(response.statusCode)])
        guard response.url == url else { throw CardShowInventoryFailure.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 301...399, 401, 403: throw CardShowInventoryFailure.signInRequired
        case 429: throw CardShowInventoryFailure.rateLimited
        default: throw CardShowInventoryFailure.networkUnavailable
        }
        guard response.mimeType?.lowercased() == "application/json" else { throw CardShowInventoryFailure.signInRequired }
        guard data.count <= CardShowInventoryDecoder.maximumPageBytes else { throw CardShowInventoryFailure.responseTooLarge }
        return data
    }

    static let locationsURL = URL(string: "https://tcgtracking.com/dash/controllers/ajax/inventory-locations.php?action=list")!
    static func stockURL(locationID: Int, page: Int) -> URL {
        var url = URLComponents(string: "https://tcgtracking.com/dash/controllers/ajax/inventory-stock.php")!
        url.queryItems = [URLQueryItem(name: "action", value: "list"), URLQueryItem(name: "location_ids", value: String(locationID)),
                          URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: String(CardShowInventoryDecoder.pageLimit)),
                          URLQueryItem(name: "sort", value: "live_desc")]
        return url.url!
    }

    static func accountCookies(_ cookies: [HTTPCookie], now: Date) -> [HTTPCookie] {
        cookies.filter {
            let domain = $0.domain.lowercased()
            return (domain == "tcgtracking.com" || domain == ".tcgtracking.com") &&
                ($0.expiresDate == nil || $0.expiresDate! > now)
        }
    }
}

final class NativeCardShowInventoryHTTPDataLoader: CardShowInventoryHTTPDataLoading, @unchecked Sendable {
    private let session: URLSession
    init(cookies: [HTTPCookie]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = true
        for cookie in cookies { configuration.httpCookieStorage?.setCookie(cookie) }
        session = URLSession(configuration: configuration, delegate: SessionDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func cancel() { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, Self.allowed(url), request.httpMethod == "GET" else {
            throw CardShowInventoryFailure.invalidResponse
        }
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse, response.url == url else { throw CardShowInventoryFailure.invalidResponse }
        guard response.expectedContentLength <= Int64(CardShowInventoryDecoder.maximumPageBytes) else {
            throw CardShowInventoryFailure.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < CardShowInventoryDecoder.maximumPageBytes else { throw CardShowInventoryFailure.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }

    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "tcgtracking.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.queryItems,
              Set(query.map(\.name)).count == query.count else { return false }
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        if url.path == "/dash/controllers/ajax/inventory-locations.php" { return values == ["action": "list"] }
        guard url.path == "/dash/controllers/ajax/inventory-stock.php", values.count == 5,
              values["action"] == "list", values["sort"] == "live_desc", values["limit"] == "500",
              let location = values["location_ids"].flatMap(Int.init), location > 0,
              let page = values["page"].flatMap(Int.init), (1...CardShowInventoryDecoder.maximumPages).contains(page) else { return false }
        return values.keys.allSatisfy { ["action", "location_ids", "page", "limit", "sort"].contains($0) }
    }

    private final class SessionDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                              ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }
}
