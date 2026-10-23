import Foundation

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
    func quote(for card: CardCandidate) async throws -> MarketQuote?
}

/// Online catalog details expose quotes by exact language and condition.
struct OnlineMarketPricing: MarketPricing {
    static let endpoint = URL(string: "https://tcgtracking.com/newscanplus/api/detail.php")!
    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        guard card.identity.productID.range(of: #"^(p|t|ts|u):[0-9]{1,12}$"#, options: .regularExpression) != nil else { return nil }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refs": [card.identity.productID]])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 2_000_000 else {
            if let http = response as? HTTPURLResponse {
                await MainActor.run { DiagnosticLog.shared.record("pricing.http_failed", ["code": String(http.statusCode)]) }
            }
            throw URLError(.badServerResponse)
        }
        return try Self.parse(data, for: card)
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
