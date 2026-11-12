import XCTest
import SwiftData
@testable import CardShowScanner

/// Text hints enter the existing explicit review/save path. They never become
/// a high-confidence visual match or bypass a sheet that already owns review.
@MainActor final class ScannerTextRecognitionFlowTests: XCTestCase {
    private func card(_ number: Int, language: String = "English") -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:\(number)", printing: "Normal", language: language),
            name: "Text hint \(number)", set: "Text recognition fixtures", number: "\(number)/086",
            marketPrice: nil, confidence: 0, printings: ["Normal", "Holofoil", "Reverse Holofoil"],
            requiresPrintingSelection: true)
    }

    private func suggestion(_ candidates: [CardCandidate], same: Bool = false, visible: Bool = true) -> ScanResult {
        var result = ScanResult(id: UUID(), candidates: candidates, accepted: false, same: same, visible: visible)
        result.source = .text
        return result
    }

    private func fixture() throws -> (ModelContainer, ScannerViewModel, ScanSession, CardList) {
        let container = try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        let model = ScannerViewModel(provider: TextFlowScannerProvider(), pricing: TextFlowPricing(), quickActionCooldown: .zero)
        model.start(game: "Pokémon", list: list, context: context, session: session)
        return (container, model, session, list)
    }

    private func waitForIdle(_ model: ScannerViewModel) async throws {
        for _ in 0..<200 {
            if !model.priceLoading && !model.selectionInProgress { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The text suggestion did not finish pricing/confirmation")
        throw URLError(.timedOut)
    }

    func testTextSuggestionNeedsAnExplicitCardTapAndKeepsReviewChoicesWhenSaved() async throws {
        let (container, model, session, list) = try fixture()
        defer { model.stop() }
        let candidates = [card(55), card(56, language: "Japanese")]
        let result = suggestion(candidates)
        model.receive(result)
        try await waitForIdle(model)

        XCTAssertEqual(model.result?.source, .text)
        XCTAssertFalse(try XCTUnwrap(model.result).accepted)
        XCTAssertEqual(model.selected?.confidence, 0, "OCR does not invent a visual match score")
        XCTAssertFalse(model.confirmed, "A text hint cannot confirm its own printing")
        XCTAssertEqual(list.quantity, 0)
        XCTAssertEqual(session.addedQuantity, 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<InventoryCard>()), 0)

        model.choose(candidates[1])
        model.changePrinting("Reverse Holofoil")
        model.changeCondition("Lightly Played")
        try await waitForIdle(model)
        XCTAssertEqual(list.quantity, 0, "Editing a suggested printing or condition is still only review")
        model.selectAndAdd(candidates[1], list: list, context: container.mainContext)
        model.selectAndAdd(candidates[1], list: list, context: container.mainContext)
        try await waitForIdle(model)

        let saved = try XCTUnwrap(list.orderedCards.first).snapshot
        XCTAssertEqual(list.quantity, 1)
        XCTAssertEqual(session.addedQuantity, 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<InventoryCard>()), 1)
        XCTAssertEqual(saved.identity.productID, candidates[1].identity.productID)
        XCTAssertEqual(saved.identity.language, "Japanese")
        XCTAssertEqual(saved.identity.printing, "Reverse Holofoil")
        XCTAssertEqual(saved.identity.condition, "Lightly Played")
        XCTAssertNil(model.selected)
        XCTAssertNil(model.result)
    }

    func testExplicitTextAttemptCanReviewSameCardAfterPreviousSaveWithoutRaisingConfidence() async throws {
        let (container, model, session, list) = try fixture()
        defer { model.stop() }
        var visual = card(55)
        visual.confidence = 96
        visual.requiresPrintingSelection = false
        model.receive(ScanResult(id: UUID(), candidates: [visual], accepted: true, same: false))
        try await waitForIdle(model)
        model.selectAndAdd(visual, list: list, context: container.mainContext)
        try await waitForIdle(model)
        XCTAssertTrue(model.waitingForRemoval)
        XCTAssertEqual(list.quantity, 1)

        // A low-score visual observation still obeys the original settling gate.
        model.receive(ScanResult(id: UUID(), candidates: [card(55)], accepted: false, same: false))
        XCTAssertNil(model.selected)
        XCTAssertTrue(model.waitingForRemoval)

        let text = suggestion([card(55)])
        model.receive(text)
        try await waitForIdle(model)
        XCTAssertEqual(model.result?.id, text.id)
        XCTAssertEqual(model.selected?.identity.productID, "p:55")
        XCTAssertEqual(model.selected?.confidence, 0)
        XCTAssertFalse(model.waitingForRemoval)
        XCTAssertEqual(list.quantity, 1, "An intentional new text review is not another inventory copy")
        XCTAssertEqual(session.addedQuantity, 1)
    }

    func testTextResultsCannotReplaceAnOwnedReviewOrAppearBehindManualEntryPauseOrSave() async throws {
        let (container, model, session, list) = try fixture()
        defer { model.stop() }
        let text = suggestion([card(55)])
        model.paused = true
        model.receive(text)
        XCTAssertNil(model.selected)
        model.paused = false
        XCTAssertTrue(model.suspendForManualSearch())
        model.receive(text)
        XCTAssertNil(model.selected)
        model.resumeAfterManualSearch()
        model.saving = true
        model.receive(text)
        XCTAssertNil(model.selected)
        model.saving = false
        model.receive(suggestion([card(55)], same: true))
        XCTAssertNil(model.selected, "A partial repeat cannot introduce a new text review")
        model.receive(suggestion([card(55)], visible: false))
        XCTAssertNil(model.selected)

        model.receive(text)
        try await waitForIdle(model)
        model.receive(suggestion([card(56)]))
        XCTAssertEqual(model.result?.id, text.id)
        XCTAssertEqual(model.selected?.identity.productID, "p:55")
        XCTAssertEqual(list.quantity, 0)
        XCTAssertEqual(session.addedQuantity, 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<InventoryCard>()), 0)
    }

    func testTextSuggestionsCannotConsumeAnAutomaticRecognitionAddition() {
        var text = suggestion([card(55)])
        var gate = RecognitionGate()
        gate.receive(text)
        XCTAssertFalse(gate.consumeAutomatic(text))
        text.accepted = true; text.candidates[0].confidence = 100; text.candidates[0].requiresPrintingSelection = false
        XCTAssertFalse(gate.consumeAutomatic(text), "Text provenance cannot claim visual automatic confirmation")
        XCTAssertFalse(gate.hasAdded)
    }
}

@MainActor private final class TextFlowScannerProvider: ScannerProvider {
    let label = "Text review fixture"
    let results: AsyncStream<ScanResult> = AsyncStream { _ in }
    func start(game: String) {}
    func stop() {}
    func clearCache() async throws {}
}

private struct TextFlowPricing: MarketPricing {
    func quote(for card: CardCandidate) async throws -> MarketQuote? { nil }
}
