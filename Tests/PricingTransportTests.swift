import XCTest
import WebKit
@testable import CardShowScanner

@MainActor final class PricingTransportTests: XCTestCase {
    private func card(_ ref: String) -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: ref, printing: "Normal"),
            name: "Fixture", set: "Fixture", number: "1", marketPrice: nil, imageURL: nil, confidence: 95, printings: ["Normal"])
    }
    func testOnlyTheActualUnlinkedPublicQuickPageIsAllowed() async {
        XCTAssertTrue(PublicPricingPagePolicy.allows(URL(string: "https://tcgtracking.com/newscanplus/quick")))
        XCTAssertTrue(PublicPricingPagePolicy.allows(URL(string: "https://tcgtracking.com:443/newscanplus/quick/")))
        for text in ["http://tcgtracking.com/newscanplus/quick", "https://tcgtracking.com.evil/newscanplus/quick",
                     "https://other.tcgtracking.com/newscanplus/quick", "https://user:secret@tcgtracking.com/newscanplus/quick",
                     "https://tcgtracking.com:444/newscanplus/quick", "https://tcgtracking.com/account",
                     "https://tcgtracking.com/newscanplus/quick?link=private"] {
            XCTAssertFalse(PublicPricingPagePolicy.allows(URL(string: text)))
        }
        XCTAssertFalse(PublicPricingPagePolicy.allows(nil))
    }
    func testUnknownServerTextNeverBecomesADiagnosticReason() async {
        XCTAssertEqual(PublicPricingPagePolicy.safeReason("origin_rejected"), "origin_rejected")
        XCTAssertEqual(PublicPricingPagePolicy.safeReason("none"), "none")
        for text in [nil, "private-token-value", "{\"error\":\"private\"}", "origin_rejected\nprivate"] {
            XCTAssertEqual(PublicPricingPagePolicy.safeReason(text), "unknown_http_error")
        }
    }
    func testConnectionBrowserAllowsWebsiteSignInAndVerificationFrames() async {
        XCTAssertEqual(TCGTrackingConnectionPolicy.startURL.absoluteString, "https://tcgtracking.com/")
        for text in ["https://tcgtracking.com/", "https://tcgtracking.com/login.php?return=/newscanplus/quick",
                     "https://www.tcgtracking.com/account", "https://tcgtracking.com:443/newscanplus/quick"] {
            XCTAssertTrue(TCGTrackingConnectionPolicy.allows(URL(string: text)))
        }
        for text in ["http://tcgtracking.com/", "https://tcgtracking.com.evil/", "https://other.tcgtracking.com/",
                     "https://user:secret@tcgtracking.com/", "https://tcgtracking.com:444/",
                     "javascript:alert(1)", "data:text/html,login", "about:blank", "about:srcdoc", "scanner://callback"] {
            XCTAssertFalse(TCGTrackingConnectionPolicy.allows(URL(string: text)))
        }
        XCTAssertFalse(TCGTrackingConnectionPolicy.allows(nil))
        XCTAssertTrue(TCGTrackingConnectionPolicy.allowsSubframe(URL(string: "https://challenges.cloudflare.com/")))
        XCTAssertTrue(TCGTrackingConnectionPolicy.allowsSubframe(URL(string: "about:blank")))
        XCTAssertTrue(TCGTrackingConnectionPolicy.allowsSubframe(URL(string: "about:srcdoc")))
        for text in ["http://example.com/", "data:text/html,login", "javascript:alert(1)",
                     "https://user:secret@example.com/", "https://example.com:444/"] {
            XCTAssertFalse(TCGTrackingConnectionPolicy.allowsSubframe(URL(string: text)))
        }
    }
    func testRealQuickScanCandidateBatchPreservesTheSelectedNidoran() async {
        let refs = ["p:84922", "p:86027", "p:87718", "p:87727", "p:89273"]
        let cards = refs.map(card)
        XCTAssertEqual(OnlineMarketPricing.references(for: cards[2], candidates: cards), refs)
    }
    func testBatchDeduplicatesUntrustedRefsAndNeverDropsSelectedCard() async {
        let selected = card("p:7")
        let cards = [card("bad"), card("p:1"), card("p:1")] + (2...8).map { card("p:\($0)") }
        let refs = OnlineMarketPricing.references(for: selected, candidates: cards)
        XCTAssertEqual(refs.count, 5); XCTAssertEqual(Set(refs).count, 5)
        XCTAssertTrue(refs.contains("p:7")); XCTAssertFalse(refs.contains("bad"))
        XCTAssertEqual(OnlineMarketPricing.references(for: card("bad"), candidates: cards), [])
        XCTAssertEqual(OnlineMarketPricing.references(for: selected, candidates: []), ["p:7"])
    }
    func testLegacyPricingProviderStillWorksThroughBatchProtocol() async throws {
        let provider: any MarketPricing = LegacyPricing()
        let quote = try await provider.quote(for: card("p:1"), candidates: [card("p:1"), card("p:2")])
        XCTAssertEqual(quote, MarketQuote(marketPrice: 0, skuID: "10"))
    }
    func testPricingContentRuleCompilesInActualWebKit() async throws {
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "PricingTransportTests.NoRecognition", encodedContentRuleList: PublicPricingPagePolicy.contentRules) { list, error in
                if let error { continuation.resume(throwing: error) }
                else if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: URLError(.cannotParseResponse)) }
            }
        }
        XCTAssertEqual(list.identifier, "PricingTransportTests.NoRecognition")
    }

    private func capturedCatalog() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "quickscan-detail", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    func testCatalogTypesAreAvailableEvenWhenSelectedPrintingHasNoQuote() async throws {
        var selected = card("p:87718")
        selected.identity.printing = "Legacy printing"
        let details = try OnlineMarketPricing.parseDetails(capturedCatalog(), for: selected)
        XCTAssertEqual(details.printings, ["Normal", "Reverse Holofoil"])
        XCTAssertNil(details.quote, "Do not replace an unsupported printing with a Normal quote")
    }
    func testConditionAndPrintingChangesReuseExactReturnedCatalogQuotes() async throws {
        let loader = CapturedCatalogLoader(data: try capturedCatalog())
        let pricing = OnlineMarketPricing(load: { try await loader.load($0) })
        var selected = card("p:87718")
        let nm = try await pricing.details(for: selected, candidates: [selected])
        XCTAssertEqual(nm.printings, ["Normal", "Reverse Holofoil"])
        XCTAssertEqual(nm.quote, MarketQuote(marketPrice: Decimal(string: "0.28"), skuID: "1193687"))
        selected.identity.condition = "Lightly Played"
        let lp = try await pricing.quote(for: selected)
        XCTAssertEqual(lp, MarketQuote(marketPrice: Decimal(string: "0.27"), skuID: "1201033"))
        selected.identity.printing = "Reverse Holofoil"; selected.identity.condition = "Near Mint"
        let reverse = try await pricing.quote(for: selected)
        XCTAssertEqual(reverse, MarketQuote(marketPrice: Decimal(string: "1.84"), skuID: "1261658"))
        let cachedCount = await loader.calls
        XCTAssertEqual(cachedCount, 1, "Changing condition/type uses the real quotes from the same catalog response")
        _ = try await pricing.details(for: selected, candidates: [selected], forceRefresh: true)
        let refreshedCount = await loader.calls
        XCTAssertEqual(refreshedCount, 2, "Explicit retry fetches a fresh catalog response")
    }
    func testScannerLoadsCatalogTypesAndConditionPriceWithoutRepeatedRequests() async throws {
        let loader = CapturedCatalogLoader(data: try capturedCatalog())
        let pricing = OnlineMarketPricing(load: { try await loader.load($0) })
        let model = ScannerViewModel(provider: PricingTestScanner(), pricing: pricing)
        model.receive(ScanResult(id: UUID(), candidates: [card("p:87718")], accepted: true, same: false))
        await waitForPrice { model.priceLoading }
        XCTAssertEqual(model.selected?.printings, ["Normal", "Reverse Holofoil"])
        model.changeCondition("Lightly Played")
        XCTAssertNil(model.selected?.marketPrice); XCTAssertNil(model.selected?.identity.skuID)
        await waitForPrice { model.priceLoading }
        XCTAssertEqual(model.selected?.marketPrice, Decimal(string: "0.27"))
        XCTAssertEqual(model.selected?.identity.skuID, "1201033")
        model.changePrinting("Reverse Holofoil")
        await waitForPrice { model.priceLoading }
        XCTAssertEqual(model.selected?.marketPrice, Decimal(string: "1.74"))
        XCTAssertEqual(model.selected?.identity.skuID, "1261659")
        let calls = await loader.calls
        XCTAssertEqual(calls, 1)
        model.scanNextCard()
    }
    func testEditorCatalogLoadPreservesSavedQuoteThenPricesSelectedConditionAndType() async throws {
        let loader = CapturedCatalogLoader(data: try capturedCatalog())
        var saved = card("p:87718"); saved.marketPrice = 10; saved.identity.skuID = "999"
        let model = CardEditorPricingModel(card: saved, pricing: OnlineMarketPricing(load: { try await loader.load($0) }))
        model.loadPrintingOptions()
        for _ in 0..<100 {
            if model.card.printings.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.card.printings, ["Normal", "Reverse Holofoil"])
        XCTAssertEqual(model.card.marketPrice, 10); XCTAssertEqual(model.card.identity.skuID, "999")
        model.changeIdentity { $0.condition = "Lightly Played" }
        await waitForPrice { model.priceLoading }
        XCTAssertEqual(model.price, "0.27"); XCTAssertEqual(model.card.identity.skuID, "1201033")
        model.changeIdentity { $0.printing = "Reverse Holofoil" }
        await waitForPrice { model.priceLoading }
        XCTAssertEqual(model.price, "1.74"); XCTAssertEqual(model.card.identity.skuID, "1261659")
        let calls = await loader.calls
        XCTAssertEqual(calls, 1)
        model.cancelLookup()
    }
    func testForcedRefreshFailureCannotResurrectCachedPrice() async throws {
        let loader = CapturedCatalogLoader(data: try capturedCatalog())
        let pricing = OnlineMarketPricing(load: { try await loader.load($0) })
        let selected = card("p:87718")
        _ = try await pricing.quote(for: selected)
        await loader.reject()
        do {
            _ = try await pricing.details(for: selected, candidates: [selected], forceRefresh: true)
            XCTFail("Rejected refresh must throw")
        } catch { XCTAssertEqual(error as? MarketPricingFailure, .accessRejected(401)) }
        do {
            _ = try await pricing.quote(for: selected)
            XCTFail("The rejected refresh must invalidate the old response")
        } catch { XCTAssertEqual(error as? MarketPricingFailure, .accessRejected(401)) }
        let calls = await loader.calls
        XCTAssertEqual(calls, 3)
    }
    private func waitForPrice(_ loading: () -> Bool) async {
        for _ in 0..<100 {
            if !loading() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Price lookup did not complete")
    }
}
private struct LegacyPricing: MarketPricing {
    func quote(for card: CardCandidate) async throws -> MarketQuote? { MarketQuote(marketPrice: 0, skuID: "10") }
}

private actor CapturedCatalogLoader {
    let data: Data
    private(set) var calls = 0
    private var status = 200
    init(data: Data) { self.data = data }
    func reject() { status = 401 }
    func load(_ refs: [String]) throws -> (status: Int, data: Data) {
        calls += 1
        return (status, data)
    }
}
@MainActor private final class PricingTestScanner: ScannerProvider {
    let label = "Test"
    let results: AsyncStream<ScanResult> = AsyncStream { _ in }
    func start(game: String) {}
    func stop() {}
    func clearCache() async throws {}
}
