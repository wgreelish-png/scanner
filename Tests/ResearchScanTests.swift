import XCTest
@testable import CardShowScanner

@MainActor final class ResearchScanTests: XCTestCase {
    private func card(_ ref: String = "p:512035") -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: ref, printing: "Holofoil"),
            name: "Charmander", set: "SV: Scarlet & Violet Promo Cards", number: "044",
            marketPrice: nil, confidence: 95, printings: ["Holofoil"])
    }

    private func scan(_ cards: [CardCandidate], same: Bool = false, visible: Bool = true) -> ScanResult {
        ScanResult(id: UUID(), candidates: cards, accepted: true, same: same, visible: visible)
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    private func waitForResult(_ model: ResearchScanModel) async throws {
        for _ in 0..<100 {
            if model.result != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Research scanner did not receive its result")
    }

    func testDefaultsToLiveWithoutStartingCaptureOrUsingMock() {
        let model = ResearchScanModel()
        XCTAssertNotNil(model.liveProvider)
        XCTAssertNil(model.result)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(model.isScanning)
    }

    func testUnsupportedGameDoesNotStartCapture() {
        let provider = ResearchFixtureScanner(), model = ResearchScanModel(provider: provider)
        model.start(game: "Unsupported")
        XCTAssertTrue(provider.startedGames.isEmpty)
        XCTAssertFalse(model.isScanning)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.choose(card()))
    }

    func testFirstUsableResultFreezesCandidatesAndStopsCamera() async throws {
        let provider = ResearchFixtureScanner(), model = ResearchScanModel(provider: provider)
        model.start(game: "Pokémon")
        provider.emit(scan([card()], same: true))
        provider.emit(scan([card()], visible: false))
        provider.emit(scan([]))
        await settle()
        XCTAssertNil(model.result)
        XCTAssertTrue(model.isScanning)

        var first = scan([card(), card("p:512036")])
        first.capturedImageData = Data([1, 2, 3])
        provider.emit(first)
        try await waitForResult(model)
        XCTAssertEqual(model.result?.id, first.id)
        XCTAssertEqual(model.candidates, first.candidates)
        XCTAssertEqual(model.result?.capturedImageData, first.capturedImageData)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(provider.stops, 1)
        provider.emit(scan([card("p:999")]))
        provider.emit(scan([], visible: false))
        await settle()
        XCTAssertEqual(model.result?.id, first.id)
        XCTAssertEqual(model.candidates, first.candidates)
    }

    func testBoundsFrozenCandidatesAndOnlyReturnsAnUnmodifiedMemberOnce() async throws {
        let provider = ResearchFixtureScanner(), model = ResearchScanModel(provider: provider)
        let cards = (0..<10).map { card("p:\(512035 + $0)") }
        model.start(game: "Pokémon")
        provider.emit(scan(cards))
        try await waitForResult(model)
        XCTAssertEqual(model.candidates, Array(cards.prefix(5)))
        XCTAssertNil(model.choose(cards[5]))
        var edited = cards[0]; edited.identity.printing = "Normal"
        XCTAssertNil(model.choose(edited))
        let chosen = try XCTUnwrap(model.choose(cards[0]))
        XCTAssertEqual(chosen, cards[0])
        XCTAssertEqual(chosen.identity.condition, "Near Mint")
        XCTAssertNil(chosen.identity.skuID)
        XCTAssertNil(chosen.marketPrice)
        XCTAssertNil(model.choose(cards[0]))
    }

    func testChoiceResetsConditionWithoutReusingAnotherConditionsQuote() async throws {
        let provider = ResearchFixtureScanner(), model = ResearchScanModel(provider: provider)
        var source = card()
        source.identity.condition = "Lightly Played"
        source.identity.skuID = "7354292"
        source.marketPrice = Decimal(string: "42.70")
        source.printingQuotes = [CardPrinting(label: "Holofoil", skuID: "7354292", marketPrice: source.marketPrice)]
        source.requiresPrintingSelection = true
        model.start(game: "Pokémon")
        provider.emit(scan([source]))
        try await waitForResult(model)
        let chosen = try XCTUnwrap(model.choose(source))
        XCTAssertEqual(chosen.identity.condition, "Near Mint")
        XCTAssertEqual(chosen.identity.printing, source.identity.printing)
        XCTAssertEqual(chosen.printings, source.printings)
        XCTAssertEqual(chosen.requiresPrintingSelection, true)
        XCTAssertNil(chosen.identity.skuID)
        XCTAssertNil(chosen.marketPrice)
        XCTAssertNil(chosen.printingQuotes)
        XCTAssertEqual(model.candidates, [source])
    }

    func testPendingResultSurvivesBackgroundWithoutRestartingCapture() async throws {
        let provider = ResearchFixtureScanner(), model = ResearchScanModel(provider: provider)
        model.start(game: "Pokémon")
        let first = scan([card()])
        provider.emit(first)
        try await waitForResult(model)
        model.stop()
        model.start(game: "Pokémon")
        XCTAssertEqual(provider.startedGames, ["Pokémon"])
        XCTAssertEqual(model.result?.id, first.id)
        XCTAssertFalse(model.isScanning)
        XCTAssertNotNil(model.choose(first.candidates[0]))
    }

    func testScanAgainUsesFreshStreamAndDoesNotStartWhileOffscreen() async throws {
        let provider = ResearchFixtureScanner(), model = ResearchScanModel(provider: provider)
        model.start(game: "Pokémon")
        let oldContinuation = provider.continuation
        provider.emit(scan([card()]))
        try await waitForResult(model)
        model.scanAgain()
        XCTAssertNil(model.result)
        XCTAssertEqual(provider.startedGames.count, 2)
        XCTAssertTrue(model.isScanning)
        oldContinuation.yield(scan([card("p:111")]))
        provider.emit(scan([card("p:222")]))
        try await waitForResult(model)
        XCTAssertEqual(model.candidates.first?.identity.productID, "p:222")
        model.stop()
        model.scanAgain()
        XCTAssertNil(model.result)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(provider.startedGames.count, 2)
        model.start(game: "Pokémon")
        XCTAssertEqual(provider.startedGames.count, 3)
        XCTAssertTrue(model.isScanning)
        model.stop()
    }

    func testForegroundRestartBeforeAnyMatchReplacesFinishedStream() async throws {
        let provider = ResearchFixtureScanner(), model = ResearchScanModel(provider: provider)
        model.start(game: "Pokémon")
        model.start(game: "Pokémon")
        XCTAssertEqual(provider.startedGames.count, 1)
        model.stop()
        XCTAssertEqual(provider.stops, 1)
        model.start(game: "Pokémon")
        provider.emit(scan([card()]))
        try await waitForResult(model)
        XCTAssertEqual(provider.startedGames.count, 2)
        XCTAssertEqual(model.candidates, [card()])
        XCTAssertNil(model.error)
    }

    func testUnexpectedStreamEndKeepsLiveProviderAndAllowsExplicitRetry() async {
        let provider = ResearchFixtureScanner(), model = ResearchScanModel(provider: provider)
        model.start(game: "Pokémon")
        provider.continuation.finish()
        await settle()
        XCTAssertFalse(model.isScanning)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.result)
        model.scanAgain()
        XCTAssertEqual(provider.startedGames.count, 2)
        XCTAssertTrue(model.isScanning)
        XCTAssertNil(model.error)
        model.stop()
    }
}

@MainActor private final class ResearchFixtureScanner: ScannerProvider {
    let label = "Research scan fixture"
    private(set) var results: AsyncStream<ScanResult>
    private(set) var continuation: AsyncStream<ScanResult>.Continuation
    private(set) var startedGames: [String] = []
    private(set) var stops = 0

    init() {
        let pair = AsyncStream<ScanResult>.makeStream()
        results = pair.stream; continuation = pair.continuation
    }
    func start(game: String) {
        continuation.finish()
        let pair = AsyncStream<ScanResult>.makeStream()
        results = pair.stream; continuation = pair.continuation
        startedGames.append(game)
    }
    func stop() { stops += 1; continuation.finish() }
    func clearCache() async throws {}
    func emit(_ result: ScanResult) { continuation.yield(result) }
}
