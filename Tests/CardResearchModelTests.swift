import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class CardResearchModelTests: XCTestCase {
    private func model(_ service: CombinedResearchService, section: CardResearchSection = .market,
                       card: CardCandidate = CombinedResearchFixtures.card) -> CardResearchModel {
        CardResearchModel(card: card, initialSection: section, grader: "PSA", grade: "9",
            publicPricing: service, opportunities: service, research: service)
    }

    func testOnlyVisibleModeLoadsAndCompletedModesAreReused() async throws {
        let service = CombinedResearchService()
        let research = model(service)
        var stats = await service.counts()
        XCTAssertEqual(stats.0, 0); XCTAssertEqual(stats.1, 0); XCTAssertEqual(stats.2, 0)
        research.start(); try await idle(research)
        stats = await service.counts()
        XCTAssertEqual(stats.0, 1); XCTAssertEqual(stats.1, 1); XCTAssertEqual(stats.2, 0)
        research.selectSection(.graded); try await idle(research)
        stats = await service.counts()
        XCTAssertEqual(stats.2, 1)
        XCTAssertEqual(research.graded.selectedGrade?.grade, "9")
        research.selectSection(.market); research.selectSection(.graded)
        await settle()
        stats = await service.counts()
        XCTAssertEqual(stats.0, 1); XCTAssertEqual(stats.1, 1); XCTAssertEqual(stats.2, 1)
    }

    func testSharedSelectionsRetireOldQuoteAndLoadOnlyActiveMode() async throws {
        let service = CombinedResearchService()
        let page = model(service)
        page.selectSection(.graded)
        page.selectPrinting("Normal"); page.selectLanguage("Japanese")
        await settle()
        var stats = await service.counts()
        XCTAssertEqual(stats.0, 0); XCTAssertEqual(stats.2, 0)
        page.start(); try await idle(page)
        let requests = await service.researchRequests
        XCTAssertEqual(requests.first?.0.identity.printing, "Normal")
        XCTAssertEqual(requests.first?.0.identity.language, "Japanese")
        XCTAssertNil(page.graded.selectedVariant, "An English Holofoil result must not become Japanese Normal research")
        page.selectSection(.market); try await idle(page)
        page.selectCondition("Lightly Played")
        XCTAssertNil(page.market.publicDetails)
        XCTAssertNil(page.card.marketPrice); XCTAssertNil(page.card.identity.skuID)
        try await idle(page)
        let prices = await service.priceRequests
        XCTAssertEqual(prices.last?.0.identity.condition, "Lightly Played")
        XCTAssertEqual(prices.last?.0.identity.language, "Japanese")
        XCTAssertEqual(prices.last?.0.identity.printing, "Normal")
        stats = await service.counts()
        XCTAssertEqual(stats.2, 1, "Changing a Market selection must not start a hidden Research request")
    }

    func testAmbiguousPrintingRequiresExplicitSelectionEvenForTheCurrentLabel() async throws {
        let service = CombinedResearchService()
        var card = CombinedResearchFixtures.card; card.requiresPrintingSelection = true
        let page = model(service, section: .graded, card: card)
        page.start(); try await idle(page)
        XCTAssertNil(page.graded.selectedVariant)
        page.selectPrinting(card.identity.printing); try await idle(page)
        XCTAssertEqual(page.card.requiresPrintingSelection, false)
        XCTAssertEqual(page.graded.selectedVariant?.finish, "Holofoil")
        XCTAssertEqual(page.graded.selectedGrade?.grade, "9")
    }

    func testWindowGradeAndCardSelectionSurviveModeChanges() async throws {
        let service = CombinedResearchService()
        let page = model(service)
        page.start(); try await idle(page)
        page.selectCondition("Lightly Played"); try await idle(page)
        page.marketWindow = 90
        page.selectSection(.graded); try await idle(page)
        page.graded.selectGrade(grader: "PSA", grade: "10")
        page.selectSection(.market)
        XCTAssertEqual(page.card.identity.condition, "Lightly Played")
        XCTAssertEqual(page.marketWindow, 90)
        XCTAssertEqual(page.market.publicDetails?.quote?.marketPrice, 5)
        page.selectSection(.graded)
        XCTAssertEqual(page.graded.selectedGrade?.grade, "10")
        let stats = await service.counts()
        XCTAssertEqual(stats.0, 2); XCTAssertEqual(stats.2, 1)
    }

    func testSwitchingModesCancelsAndRejectsLatePublicReply() async throws {
        let service = CombinedResearchService(holdPrices: true)
        let research = model(service)
        research.start(); try await service.waitForPrices(1)
        research.selectSection(.graded); try await idle(research)
        await service.finishPrice(0, price: 999); await settle()
        XCTAssertNil(research.market.publicDetails)
        research.selectSection(.market); try await service.waitForPrices(2)
        await service.finishPrice(1, price: 7); try await idle(research)
        XCTAssertEqual(research.market.publicDetails?.quote?.marketPrice, 7)
    }

    func testInactivePageCannotRefreshAndLateResearchCannotPublish() async throws {
        let service = CombinedResearchService(holdResearch: true)
        let page = model(service, section: .graded)
        page.start(); try await service.waitForResearch(1)
        page.stop(); page.refresh(); page.selectSection(.market)
        try await service.finishResearch(0); await settle()
        XCTAssertNil(page.graded.details)
        var stats = await service.counts()
        XCTAssertEqual(stats.0, 0); XCTAssertEqual(stats.2, 1)
        page.start(); try await idle(page)
        stats = await service.counts()
        XCTAssertEqual(stats.0, 1); XCTAssertEqual(stats.2, 1)
    }

    func testResearchFailureDoesNotReplaceUsablePublicPrice() async throws {
        let service = CombinedResearchService(researchFailure: .notCovered)
        let page = model(service)
        page.start(); try await idle(page)
        XCTAssertEqual(page.market.publicDetails?.quote?.marketPrice, 10)
        page.selectSection(.graded); try await idle(page)
        XCTAssertNotNil(page.graded.message); XCTAssertNil(page.graded.details)
        page.selectSection(.market)
        XCTAssertEqual(page.market.publicDetails?.quote?.marketPrice, 10)
        XCTAssertNil(page.market.publicMessage)
    }

    func testExplicitRefreshTargetsOnlyTheSelectedServiceFamily() async throws {
        let service = CombinedResearchService()
        let page = model(service)
        page.start(); try await idle(page)
        page.refresh(); try await idle(page)
        var stats = await service.counts()
        XCTAssertEqual(stats.0, 2); XCTAssertEqual(stats.2, 0)
        page.selectSection(.graded); try await idle(page)
        page.refresh(); try await idle(page)
        stats = await service.counts()
        XCTAssertEqual(stats.0, 2); XCTAssertEqual(stats.1, 2); XCTAssertEqual(stats.2, 2)
        let prices = await service.priceRequests, research = await service.researchRequests
        XCTAssertEqual(prices.map { $0.1 }, [false, true])
        XCTAssertEqual(research.map { $0.1 }, [false, true])
    }

    func testReturningFromConnectionRetriesVisibleModeWithoutHiddenResearchRequest() async throws {
        let service = CombinedResearchService()
        let page = model(service)
        page.start(); try await idle(page)
        page.stop(); page.connectionDidChange()
        var stats = await service.counts()
        XCTAssertEqual(stats.0, 1); XCTAssertEqual(stats.2, 0)
        page.start(); try await idle(page)
        stats = await service.counts()
        XCTAssertEqual(stats.0, 2); XCTAssertEqual(stats.1, 2); XCTAssertEqual(stats.2, 0)
        page.selectSection(.graded); try await idle(page)
        XCTAssertEqual(page.graded.selectedGrade?.grade, "9")
    }

    func testResearchSelectionsNeverEditSavedRowsQuantitiesOrOfferData() async throws {
        let container = try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext, list = CardList(name: "Research stays read-only")
        context.insert(list)
        try CardListService.add(CombinedResearchFixtures.card, to: list, context: context)
        let item = try XCTUnwrap(list.orderedCards.first)
        item.quantity = 3; item.cashOverrideText = "4"; item.tradeOverrideText = "6"; item.maximumOverrideText = "5"
        let session = ScanSession(listName: list.name); session.listID = list.id
        session.savedOffersData = Data("[]".utf8); context.insert(session); try context.save()
        let saved = item.data, id = item.id, addedAt = item.addedAt, offers = session.savedOffersData
        let service = CombinedResearchService()
        let research = model(service, card: item.snapshot)
        research.start(); try await idle(research)
        research.selectCondition("Lightly Played"); try await idle(research)
        research.selectSection(.graded); try await idle(research)
        research.graded.selectGrade(grader: "PSA", grade: "10")
        XCTAssertEqual(item.data, saved); XCTAssertEqual(item.id, id); XCTAssertEqual(item.addedAt, addedAt)
        XCTAssertEqual(item.quantity, 3); XCTAssertEqual(item.cashOverrideText, "4")
        XCTAssertEqual(item.tradeOverrideText, "6"); XCTAssertEqual(item.maximumOverrideText, "5")
        XCTAssertEqual(session.savedOffersData, offers); XCTAssertEqual(list.cards.count, 1)
        XCTAssertFalse(context.hasChanges)
    }

    private func idle(_ page: CardResearchModel) async throws {
        for _ in 0..<200 {
            if !page.market.publicLoading && !page.market.activityLoading && !page.graded.loading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Combined research did not finish"); throw URLError(.timedOut)
    }
    private func settle() async { for _ in 0..<30 { await Task.yield() } }
}

private enum CombinedResearchFixtures {
    static var card: CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:42", skuID: "100", printing: "Holofoil"),
            name: "Fixture card", set: "Fixture set", number: "42", marketPrice: 7,
            confidence: 100, printings: ["Holofoil", "Normal"])
    }
    static func research() throws -> ResearchProductDetails {
        let body: [String: Any] = [
            "meta": ["category_id": 3, "group_id": 1430, "schema_version": "2.0-testing", "status": "in_testing"],
            "product": ["product_id": 42, "name": "Fixture card", "variants": [
                "EN:Holofoil": ["language": "EN", "finish": "Holofoil", "grades": [
                    ["grader": "PSA", "grade": "9", "guide_value": "12.50", "sales": 3],
                    ["grader": "PSA", "grade": "10", "guide_value": "25", "sales": 2]
                ]]
            ]]
        ]
        return try ResearchProductDetails.decode(JSONSerialization.data(withJSONObject: body),
            expectedCategoryID: 3, expectedGroupID: 1430, expectedProductID: 42)
    }
}

private actor CombinedResearchService: MarketPricing, OpportunitiesProviding, ResearchProviding {
    let holdPrices: Bool
    let holdResearch: Bool
    let researchFailure: ResearchFailure?
    private(set) var priceRequests: [(CardCandidate, Bool)] = []
    private(set) var researchRequests: [(CardCandidate, Bool)] = []
    private var activityCalls = 0
    private var pendingPrices: [CheckedContinuation<MarketDetails, Error>?] = []
    private var pendingResearch: [CheckedContinuation<ResearchProductDetails, Error>?] = []
    init(holdPrices: Bool = false, holdResearch: Bool = false, researchFailure: ResearchFailure? = nil) {
        self.holdPrices = holdPrices; self.holdResearch = holdResearch; self.researchFailure = researchFailure
    }
    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        try await details(for: card, candidates: [card], forceRefresh: false).quote
    }
    func details(for card: CardCandidate, candidates: [CardCandidate], forceRefresh: Bool) async throws -> MarketDetails {
        priceRequests.append((card, forceRefresh))
        if holdPrices { return try await withCheckedThrowingContinuation { pendingPrices.append($0) } }
        return MarketDetails(quote: MarketQuote(marketPrice: card.identity.condition == "Lightly Played" ? 5 : 10,
                                               skuID: card.identity.condition == "Lightly Played" ? "200" : "100"),
                             printings: ["Holofoil", "Normal"])
    }
    func opportunities(for card: CardCandidate, forceRefresh: Bool) async throws -> OpportunitiesDetails {
        activityCalls += 1; throw OpportunitiesFailure.notCovered
    }
    func research(for card: CardCandidate, forceRefresh: Bool) async throws -> ResearchProductDetails {
        researchRequests.append((card, forceRefresh))
        if let researchFailure { throw researchFailure }
        if holdResearch { return try await withCheckedThrowingContinuation { pendingResearch.append($0) } }
        return try CombinedResearchFixtures.research()
    }
    func counts() -> (Int, Int, Int) { (priceRequests.count, activityCalls, researchRequests.count) }
    func finishPrice(_ index: Int, price: Decimal) {
        let continuation = pendingPrices[index]; pendingPrices[index] = nil
        continuation?.resume(returning: MarketDetails(quote: MarketQuote(marketPrice: price, skuID: "100")))
    }
    func finishResearch(_ index: Int) throws {
        let continuation = pendingResearch[index]; pendingResearch[index] = nil
        continuation?.resume(returning: try CombinedResearchFixtures.research())
    }
    func waitForPrices(_ count: Int) async throws {
        for _ in 0..<200 {
            if priceRequests.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
    func waitForResearch(_ count: Int) async throws {
        for _ in 0..<200 {
            if researchRequests.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
}
