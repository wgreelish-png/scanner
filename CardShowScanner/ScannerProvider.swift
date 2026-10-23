import Foundation
import WebKit

@MainActor protocol ScannerProvider {
    var label: String { get }
    var results: AsyncStream<ScanResult> { get }
    func start(game: String)
    func stop()
    func clearCache() async throws
}

@MainActor final class MockScannerProvider: ScannerProvider {
    let label = "MOCK SCANNER • No camera or live prices"
    private(set) var results: AsyncStream<ScanResult>
    private var continuation: AsyncStream<ScanResult>.Continuation
    private var task: Task<Void, Never>?
    init() {
        let pair = AsyncStream<ScanResult>.makeStream(bufferingPolicy: .bufferingNewest(1))
        results = pair.stream; continuation = pair.continuation
    }
    static func samples(game: String, index: Int) -> [CardCandidate] {
        let names: [String]
        switch game {
        case "Magic: The Gathering": names = ["Lightning Bolt", "Counterspell", "Sol Ring", "Opt", "Island"]
        case "Yu-Gi-Oh!": names = ["Dark Magician", "Blue-Eyes White Dragon", "Kuriboh", "Celtic Guardian", "Summoned Skull"]
        default: names = ["Glass Trumpet", "Pikachu", "Charizard", "Eevee", "Squirtle"]
        }
        return (0..<5).map { offset in
            let n = (index + offset) % names.count
            return CardCandidate(identity: CardIdentity(game: game, productID: "mock:\(game):\(n)", printing: "Normal"),
                name: names[n], set: "Demo Set", number: "\(n + 1)/142",
                marketPrice: n == 3 ? nil : Decimal(n + 1) * Decimal(string: "1.25")!,
                confidence: offset == 0 ? (index % 3 == 0 ? 96 : (index % 3 == 1 ? 62 : 35)) : Double(60 - offset * 8),
                printings: ["Normal", "Holofoil", "Reverse Holofoil"])
        }
    }
    func start(game: String) {
        stop()
        let pair = AsyncStream<ScanResult>.makeStream(bufferingPolicy: .bufferingNewest(1))
        results = pair.stream; continuation = pair.continuation
        task = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                guard let self else { return }
                let id = UUID()
                let cards = Self.samples(game: game, index: index)
                self.continuation.yield(ScanResult(id: id, candidates: cards, accepted: index % 3 == 0, same: false))
                for _ in 0..<3 {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    self.continuation.yield(ScanResult(id: id, candidates: cards, accepted: index % 3 == 0, same: true))
                }
                index = (index + 1) % 6 // Wraps to exercise intentional duplicate inventory.
            }
        }
    }
    func stop() { task?.cancel(); task = nil; continuation.finish() }
    func clearCache() async throws { /* Synthetic results have no disk cache. */ }
}

struct MarketQuote: Equatable, Sendable {
    var marketPrice: Decimal?
    var skuID: String?
}

protocol MarketPricing: Sendable {
    func prepare() async
    func quote(for card: CardCandidate) async throws -> MarketQuote?
}

extension MarketPricing { func prepare() async {} }

enum MarketPricingFailure: LocalizedError, Equatable {
    case accessRejected(Int), publicPageUnavailable
    var errorDescription: String? {
        switch self {
        case .accessRejected(let status): return "TCGTracking rejected the public price request (\(status)). Retry Market Price. You can still save this card unpriced."
        case .publicPageUnavailable: return "TCGTracking Quick Scan could not open for pricing. Retry when your connection is available. You can still save this card unpriced."
        }
    }
}

/// Uses the same real first-party browser context as the public Quick Scan page.
/// The recognition camera/engine continue to run separately from bundled local assets.
@MainActor private final class PublicMarketBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = PublicMarketBrowser()
    private static let page = URL(string: "https://tcgtracking.com/newscanplus/quick")!
    private let webView: WKWebView
    private var ready = false
    private var startup: Task<Void, Error>?
    private var startupID = UUID()
    private var pendingLoad: CheckedContinuation<Void, Error>?
    private var navigation: WKNavigation?
    private var watchdog: Task<Void, Never>?
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Only the bundled native-invoked pricing function executes. The website's
        // camera/recognition scripts are not needed to establish its document origin.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
    }
    private static func permitted(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == "tcgtracking.com" && (url.port == nil || url.port == 443) &&
            url.user == nil && url.password == nil && (url.path == page.path || url.path == page.path + "/")
    }
    func prepare() async throws {
        if ready && Self.permitted(webView.url) { return }
        if let startup { return try await startup.value }
        let id = UUID(); startupID = id
        let task = Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pendingLoad = continuation
                var request = URLRequest(url: Self.page)
                request.timeoutInterval = 4
                navigation = webView.load(request)
                guard navigation != nil else { finishLoad(MarketPricingFailure.publicPageUnavailable); return }
                DiagnosticLog.shared.record("pricing.page_loading")
                watchdog = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    guard let self, self.startupID == id, self.pendingLoad != nil else { return }
                    self.finishLoad(URLError(.timedOut)); self.webView.stopLoading()
                }
            }
        }
        startup = task
        do { try await task.value; if startupID == id { startup = nil } }
        catch { if startupID == id { startup = nil }; throw error }
    }
    private func finishLoad(_ error: Error? = nil, navigation completed: WKNavigation? = nil) {
        if let completed, completed !== navigation { return }
        guard let continuation = pendingLoad else { return }
        pendingLoad = nil; navigation = nil; watchdog?.cancel(); watchdog = nil
        ready = error == nil
        if let error { continuation.resume(throwing: error) }
        else { DiagnosticLog.shared.record("pricing.page_ready"); continuation.resume() }
    }
    func detail(ref: String) async throws -> (status: Int, data: Data) {
        try await prepare(); try Task.checkCancellation()
        guard Self.permitted(webView.url),
              let resource = Bundle.main.url(forResource: "PricingRequest", withExtension: "js") else { throw MarketPricingFailure.publicPageUnavailable }
        let script = try String(contentsOf: resource, encoding: .utf8)
        let result = try await webView.callAsyncJavaScript(script, arguments: ["refs": [ref]], in: nil, contentWorld: .defaultClient)
        try Task.checkCancellation()
        guard let reply = result as? [String: Any], let status = reply["status"] as? Int, (100...599).contains(status),
              let body = reply["body"] as? String, let data = body.data(using: .utf8), data.count <= 2_000_000 else { throw URLError(.cannotParseResponse) }
        return (status, data)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame == true, Self.permitted(action.request.url) else {
            if action.targetFrame?.isMainFrame == true { finishLoad(MarketPricingFailure.publicPageUnavailable) }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didCommit completed: WKNavigation!) {
        // A committed public document supplies the genuine origin; ancillary page
        // resources must not delay or control market lookup readiness.
        finishLoad(Self.permitted(webView.url) ? nil : MarketPricingFailure.publicPageUnavailable, navigation: completed)
    }
    func webView(_ webView: WKWebView, didFinish completed: WKNavigation!) {
        finishLoad(Self.permitted(webView.url) ? nil : MarketPricingFailure.publicPageUnavailable, navigation: completed)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation completed: WKNavigation!, withError error: Error) { finishLoad(error, navigation: completed) }
    func webView(_ webView: WKWebView, didFail completed: WKNavigation!, withError error: Error) { finishLoad(error, navigation: completed) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; finishLoad(MarketPricingFailure.publicPageUnavailable)
        DiagnosticLog.shared.record("pricing.page_terminated")
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}

/// Online catalog details expose quotes by exact language and condition.
struct OnlineMarketPricing: MarketPricing {
    static let endpoint = URL(string: "https://tcgtracking.com/newscanplus/api/detail.php")!
    func prepare() async {
        do { try await PublicMarketBrowser.shared.prepare() }
        catch { await MainActor.run { DiagnosticLog.shared.failure("pricing.page_warmup_failed", error) } }
    }
    static func validate(status: Int) throws {
        if status == 401 || status == 403 { throw MarketPricingFailure.accessRejected(status) }
        guard status == 200 else { throw URLError(.badServerResponse) }
    }
    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        guard card.identity.productID.range(of: #"^(p|t|ts|u):[0-9]{1,12}$"#, options: .regularExpression) != nil else { return nil }
        let response = try await PublicMarketBrowser.shared.detail(ref: card.identity.productID)
        if response.status != 200 {
            await MainActor.run { DiagnosticLog.shared.record("pricing.http_failed", ["code": String(response.status)]) }
        }
        try Self.validate(status: response.status)
        return try Self.parse(response.data, for: card)
    }
    static func parse(_ data: Data, for card: CardCandidate) throws -> MarketQuote? {
        let reply = try JSONDecoder().decode(DetailReply.self, from: data)
        guard let item = reply.items[card.identity.productID],
              let printing = item.printings.first(where: { $0.label == card.identity.printing || $0.key == card.identity.printing }),
              let quote = printing.quotes?[card.identity.language + "|" + card.identity.condition] else { return nil }
        let value = quote.market_price
        guard value.map({ !$0.isNaN && $0 >= 0 }) ?? true else { return nil }
        return MarketQuote(marketPrice: value, skuID: quote.sku_id?.value)
    }
    private struct DetailReply: Decodable { var items: [String: Detail] }
    private struct Detail: Decodable { var printings: [Printing] }
    private struct Printing: Decodable {
        var key: String?; var label: String?; var quotes: [String: Quote]?
    }
    private struct Quote: Decodable { var market_price: Decimal?; var sku_id: SKU? }
    private struct SKU: Decodable {
        var value: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { value = s }
            else { value = String(try c.decode(Int64.self)) }
            guard value.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid SKU")
            }
        }
    }
}
