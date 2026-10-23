import XCTest
import WebKit
@testable import CardShowScanner

@MainActor final class PricingTransportTests: XCTestCase {
    private func card(_ ref: String) -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: ref, printing: "Normal"),
            name: "Fixture", set: "Fixture", number: "1", marketPrice: nil, imageURL: nil, confidence: 95, printings: ["Normal"])
    }
    func testOnlyTheActualUnlinkedPublicQuickPageIsAllowed() {
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
    func testUnknownServerTextNeverBecomesADiagnosticReason() {
        XCTAssertEqual(PublicPricingPagePolicy.safeReason("origin_rejected"), "origin_rejected")
        XCTAssertEqual(PublicPricingPagePolicy.safeReason("none"), "none")
        for text in [nil, "private-token-value", "{\"error\":\"private\"}", "origin_rejected\nprivate"] {
            XCTAssertEqual(PublicPricingPagePolicy.safeReason(text), "unknown_http_error")
        }
    }
    func testRealQuickScanCandidateBatchPreservesTheSelectedNidoran() {
        let refs = ["p:84922", "p:86027", "p:87718", "p:87727", "p:89273"]
        let cards = refs.map(card)
        XCTAssertEqual(OnlineMarketPricing.references(for: cards[2], candidates: cards), refs)
    }
    func testBatchDeduplicatesUntrustedRefsAndNeverDropsSelectedCard() {
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
}
private struct LegacyPricing: MarketPricing {
    func quote(for card: CardCandidate) async throws -> MarketQuote? { MarketQuote(marketPrice: 0, skuID: "10") }
}
