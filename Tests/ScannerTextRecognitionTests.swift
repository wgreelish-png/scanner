import XCTest
@testable import CardShowScanner

final class ScannerTextRecognitionTests: XCTestCase {
    private func row(_ text: String, x: Double = 0.1, y: Double = 0.8, width: Double = 0.5,
                     confidence: Float = 0.95) -> ScannerTextObservation {
        ScannerTextObservation(text: text, confidence: confidence, x: x, y: y, width: width, height: 0.03)
    }

    func testKrookodileTitleAndCollectorSurviveStickerDamageAndNeighboringCard() {
        let hints = ScannerTextHintParser.hints(from: [
            row("BASIC", y: 0.87), row("Krookodile ex 230 HP"), row("2 for 1", x: 0.7, y: 0.82, width: 0.2),
            row("Corner 80", y: 0.42), row("Strong Bite 140+", y: 0.32),
            row("CRI 055/086 ★", y: 0.19), row("Arcanine ex", y: 0.08)
        ])
        XCTAssertEqual(hints, [ScannerTextHint(name: "Krookodile ex", number: "055/086")])
    }

    func testAlphanumericCollectorsAndSetCodesKeepTheirFullIdentity() {
        XCTAssertEqual(ScannerTextHintParser.hints(from: [row("Pikachu"), row("TG05 / TG30", y: 0.15)]).first?.number, "TG05/TG30")
        XCTAssertEqual(ScannerTextHintParser.hints(from: [row("Blue-Eyes White Dragon"), row("RA03-EN055", y: 0.3)]).first?.number, "RA03-EN055")
        XCTAssertEqual(ScannerTextHintParser.hints(from: [row("Charizard ex"), row("GG01/GG70", y: 0.1)]).first?.number, "GG01/GG70")
    }

    func testBareNumbersAndPriceStickersCannotBecomeCollectorsOrTitles() {
        let hints = ScannerTextHintParser.hints(from: [row("Krookodile ex"), row("80", y: 0.2), row("140+", y: 0.3),
            row("$2", y: 0.85), row("2/1", y: 0.12), row("2 FOR 1", y: 0.9)])
        XCTAssertEqual(hints, [ScannerTextHint(name: "Krookodile ex", number: "")])
        XCTAssertTrue(ScannerTextHintParser.hints(from: [row("80"), row("HP 230"), row("2 for 1"), row("055/086", y: 0.15)]).isEmpty)
    }

    func testCollectorInAnotherColumnDoesNotAttachToNarrowTitle() {
        let hints = ScannerTextHintParser.hints(from: [row("Pikachu", x: 0.02, width: 0.2),
            row("055/086", x: 0.7, y: 0.15, width: 0.2)])
        XCTAssertEqual(hints, [ScannerTextHint(name: "Pikachu", number: "")])
    }

    func testGenericTypeHeadersAreIgnoredWithoutRejectingRealTrainerCardNames() {
        let hints = ScannerTextHintParser.hints(from: [row("TRAINER", y: 0.9), row("Pokémon Catcher", y: 0.8),
            row("Damage Pump", y: 0.7), row("123/198", y: 0.15)])
        XCTAssertEqual(hints.map(\.name), ["Pokémon Catcher", "Damage Pump"])
    }

    func testInvalidLowConfidenceAndUnboundedObservationsAreIgnored() {
        let observations = [row("Pikachu", confidence: 0.1), row("Charizard", x: .nan),
            row("Squirtle", y: 0.4), row(String(repeating: "a", count: 201)), row("Eevee", x: 0.9)]
        XCTAssertTrue(ScannerTextHintParser.hints(from: observations).isEmpty)
        XCTAssertLessThanOrEqual(ScannerTextHintParser.hints(from: (0..<30).map { row("Card \($0)") }).count, 3)
    }

    func testExactCollectorSearchPrecedesNameFallbackAndDoesNotInventVisualConfidence() async throws {
        let catalog = TextCatalogFixture(exact: [card("p:1", name: "Krookodile ex")], broad: [card("p:2", name: "Other")])
        let results = try await ScannerTextCatalogMatcher(catalog: catalog).candidates(from: [row("Krookodile ex"), row("055/086", y: 0.12)], game: "Pokémon")
        XCTAssertEqual(results.map(\.identity.productID), ["p:1"])
        XCTAssertEqual(results.first?.confidence, 0)
        XCTAssertEqual(results.first?.requiresPrintingSelection, true)
        XCTAssertNil(results.first?.marketPrice)
        XCTAssertNil(results.first?.identity.skuID)
        let calls = await catalog.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.query, "Krookodile ex")
        XCTAssertEqual(calls.first?.number, "055/086")
    }

    func testUnreadableOrMismatchedCollectorFallsBackToNameOnlySuggestions() async throws {
        let catalog = TextCatalogFixture(exact: [], broad: [card("p:1", name: "Krookodile ex")])
        let results = try await ScannerTextCatalogMatcher(catalog: catalog).candidates(from: [row("Krookodile ex"), row("055/088", y: 0.12)], game: "Pokémon")
        XCTAssertEqual(results.count, 1)
        let calls = await catalog.calls
        XCTAssertEqual(calls.map(\.number), ["055/088", ""])
    }

    func testNoUsefulTitleDoesNotOpenCatalogAndCandidatesRemainBounded() async throws {
        let catalog = TextCatalogFixture(exact: [], broad: (0..<20).map { card("p:\($0)", name: "Pikachu") })
        let matcher = ScannerTextCatalogMatcher(catalog: catalog)
        let empty = try await matcher.candidates(from: [row("055/086", y: 0.2)], game: "Pokémon")
        XCTAssertTrue(empty.isEmpty)
        let initial = await catalog.calls
        XCTAssertTrue(initial.isEmpty)
        let results = try await matcher.candidates(from: [row("Pikachu")], game: "Pokémon")
        XCTAssertEqual(results.count, 5)
        let calls = await catalog.calls
        XCTAssertTrue(calls.allSatisfy { $0.limit == 5 && !$0.query.isEmpty })
    }

    func testCancellationBeforeCatalogAndAfterAQueuedCatalogResponseIsHonored() async {
        let catalog = TextCatalogFixture(exact: [], broad: [card("p:1", name: "Pikachu")], delay: true)
        let matcher = ScannerTextCatalogMatcher(catalog: catalog)
        let observations = [row("Pikachu")]
        let task = Task { try await matcher.candidates(from: observations, game: "Pokémon") }
        for _ in 0..<100 {
            if !(await catalog.calls).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let calls = await catalog.calls
        XCTAssertFalse(calls.isEmpty, "The fixture must reach its bounded catalog delay")
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled catalog responses must not become review candidates") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testOCRRejectsInvalidAndOversizedImageDataBeforeVisionExecution() async {
        for image in [Data(), Data("not-a-jpeg".utf8), Data(repeating: 0, count: 2_000_001)] {
            do { _ = try await ScannerTextRecognizer().recognize(image); XCTFail("Invalid image must not be decoded") }
            catch { XCTAssertTrue(error is ScannerTextRecognitionFailure) }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ScannerTextRecognizer().recognize(Data())
        }
        do { _ = try await task.value; XCTFail("Cancellation must win") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func card(_ ref: String, name: String) -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: ref, skuID: "123", printing: "Holofoil"),
            name: name, set: "Chaos Rising", number: "055/086", marketPrice: 12, imageURL: nil, confidence: 98, printings: ["Holofoil", "Reverse Holofoil"])
    }
}

private actor TextCatalogFixture: CardCatalogSearching {
    struct Call: Sendable { var query: String; var number: String; var limit: Int }
    private let exact: [CardCandidate]
    private let broad: [CardCandidate]
    private let delay: Bool
    private(set) var calls: [Call] = []
    init(exact: [CardCandidate], broad: [CardCandidate], delay: Bool = false) {
        self.exact = exact; self.broad = broad; self.delay = delay
    }
    func search(_ query: String, game: String, limit: Int) async throws -> [CardCandidate] {
        try await search(query, game: game, limit: limit, filters: CardCatalogFilters())
    }
    func search(_ query: String, game: String, limit: Int, filters: CardCatalogFilters) async throws -> [CardCandidate] {
        calls.append(Call(query: query, number: filters.number, limit: limit))
        if delay { try await Task.sleep(for: .milliseconds(50)) }
        return filters.number.isEmpty ? broad : exact
    }
}

final class ScannerTextRecognitionStateTests: XCTestCase {
    func testTextCaptureRequiresEnabledReadyForegroundScannerWithoutReview() {
        XCTAssertTrue(allows())
        XCTAssertFalse(allows(enabled: false))
        XCTAssertFalse(allows(busy: true))
        XCTAssertFalse(allows(active: false))
        XCTAssertFalse(allows(foreground: false))
        XCTAssertFalse(allows(manual: true))
        XCTAssertFalse(allows(cooling: true))
        XCTAssertFalse(allows(documentReady: false))
        XCTAssertFalse(allows(reviewing: true))
    }

    func testAutomaticPhotoFallbackOnlyFollowsNoMatch() {
        for state in PhotoScanState.allCases {
            XCTAssertEqual(allows(mode: .photo, photoState: state), state == .noMatch)
            XCTAssertTrue(allows(mode: .live, photoState: state))
        }
    }

    private func allows(enabled: Bool = true, busy: Bool = false, mode: ScannerCaptureMode = .live,
                        photoState: PhotoScanState = .off, active: Bool = true, foreground: Bool = true,
                        manual: Bool = false, cooling: Bool = false, documentReady: Bool = true,
                        reviewing: Bool = false) -> Bool {
        ScannerTextRecognitionPolicy.allows(enabled: enabled, busy: busy, mode: mode, photoState: photoState,
            active: active, foreground: foreground, manual: manual, cooling: cooling,
            documentReady: documentReady, reviewing: reviewing)
    }
}

@MainActor final class ScannerTextProviderPreferenceTests: XCTestCase {
    func testTextOptionSurvivesProviderStopWithoutEnablingAnUnreadyCapture() {
        let provider = TCGTrackingScannerProvider()
        XCTAssertFalse(provider.textRecognitionEnabled)
        XCTAssertFalse(provider.canReadCardText)
        provider.setTextRecognitionEnabled(true)
        XCTAssertTrue(provider.textRecognitionEnabled)
        XCTAssertFalse(provider.canReadCardText)
        provider.stop()
        XCTAssertTrue(provider.textRecognitionEnabled)
        XCTAssertFalse(provider.canReadCardText)
        provider.setTextRecognitionEnabled(false)
        XCTAssertFalse(provider.textRecognitionEnabled)
    }
}
