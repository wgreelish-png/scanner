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
    private let log: DiagnosticLog
    private var generation = UUID()
    private var currentLoader: (any CardShowInventoryHTTPDataLoading)?

    init(cookies: @escaping @MainActor () async -> [HTTPCookie] = {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }, makeLoader: @escaping @MainActor ([HTTPCookie]) -> any CardShowInventoryHTTPDataLoading = {
        NativeCardShowInventoryHTTPDataLoader(cookies: $0)
    }, isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
       now: @escaping @MainActor () -> Date = Date.init, log: DiagnosticLog? = nil) {
        self.cookies = cookies; self.makeLoader = makeLoader; self.isActive = isActive; self.now = now
        self.log = log ?? .shared
    }

    func fetch(expectedLocationID: Int?) async throws -> CardShowInventorySnapshot {
        cancel()
        let id = generation
        try checkCurrent(id)
        let savedCookies = await cookies()
        try checkCurrent(id)
        let scoped = Self.accountCookies(savedCookies, now: now())
        guard !scoped.isEmpty else {
            log.record("card_show_inventory.rejected", ["phase": "session", "stage": "session", "reason": "missing_session"])
            throw CardShowInventoryFailure.signInRequired
        }
        let loader = makeLoader(scoped)
        currentLoader = loader
        let deadline = now().addingTimeInterval(120)
        defer {
            loader.cancel()
            if generation == id { currentLoader = nil }
        }
        return try await withTaskCancellationHandler {
            var phase = "locations"
            var requestedPage: Int?
            do {
                let locations = try await load(Self.locationsURL, phase: "locations", loader: loader, id: id, deadline: deadline)
                let location = try CardShowInventoryDecoder.location(locations, expectedID: expectedLocationID)
                log.record("card_show_inventory.location_decoded", ["phase": "locations", "records": "1"])
                phase = "stock"; requestedPage = 1
                let firstBody = try await load(Self.stockURL(locationID: location.id, page: 1), phase: "stock", loader: loader,
                                               id: id, deadline: deadline)
                let first = try CardShowInventoryDecoder.page(firstBody, location: location, requestedPage: 1)
                recordPage(first)
                var rows = first.rows
                var seen = Set(rows.map(\.inventoryID))
                if first.pages > 1 {
                    for page in 2...first.pages {
                        requestedPage = page
                        let body = try await load(Self.stockURL(locationID: location.id, page: page), phase: "stock", loader: loader,
                                                  id: id, deadline: deadline)
                        let result = try CardShowInventoryDecoder.page(body, location: location, requestedPage: page)
                        guard result.total == first.total, result.pages == first.pages else {
                            throw CardShowInventoryValidationFailure(.pagination, .changingTotals, page: page)
                        }
                        recordPage(result)
                        for row in result.rows {
                            guard seen.insert(row.inventoryID).inserted else {
                                throw CardShowInventoryValidationFailure(.snapshot, .duplicateInventory, page: page)
                            }
                            rows.append(row)
                        }
                    }
                }
                try checkCurrent(id)
                guard rows.count == first.total else { throw CardShowInventoryValidationFailure(.snapshot, .finalCount) }
                log.record("card_show_inventory.snapshot_decoded", ["phase": "stock", "records": String(rows.count), "total": String(first.total)])
                return .init(location: location, rows: rows, fetchedAt: now())
            } catch {
                try checkCurrent(id)
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if let rejection = error as? CardShowInventoryValidationFailure {
                    var fields = rejection.diagnosticFields
                    fields["phase"] = phase
                    if fields["page"] == nil, let requestedPage { fields["page"] = String(requestedPage) }
                    log.record("card_show_inventory.rejected", fields)
                    throw rejection.failure
                }
                let failure = error as? CardShowInventoryFailure ?? .networkUnavailable
                var fields = ["phase": phase, "stage": phase == "locations" ? "locations" : "response", "reason": failure.diagnosticReason]
                if let requestedPage { fields["page"] = String(requestedPage) }
                log.record("card_show_inventory.rejected", fields)
                throw failure
            }
        } onCancel: {
            loader.cancel()
        }
    }

    private func recordPage(_ page: CardShowInventoryDecoder.Page) {
        log.record("card_show_inventory.page_decoded", ["phase": "stock", "page": String(page.page),
            "records": String(page.rows.count), "total": String(page.total)])
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
        log.record("card_show_inventory.http_response", ["phase": phase, "code": String(response.statusCode)])
        guard response.url == url else { throw CardShowInventoryValidationFailure(.response, .responseURL) }
        switch response.statusCode {
        case 200: break
        case 301...399, 401, 403:
            throw CardShowInventoryValidationFailure(.response, .httpAuthentication, failure: .signInRequired)
        case 429: throw CardShowInventoryValidationFailure(.response, .rateLimited, failure: .rateLimited)
        default: throw CardShowInventoryValidationFailure(.response, .httpStatus, failure: .networkUnavailable)
        }
        guard response.mimeType?.lowercased() == "application/json" else {
            throw CardShowInventoryValidationFailure(.response, .contentType, failure: .signInRequired)
        }
        guard data.count <= CardShowInventoryDecoder.maximumPageBytes else {
            throw CardShowInventoryValidationFailure(.response, .responseTooLarge, failure: .responseTooLarge)
        }
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
