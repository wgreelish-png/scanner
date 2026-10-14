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
