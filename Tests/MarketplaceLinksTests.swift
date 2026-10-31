import XCTest
@testable import CardShowScanner

final class MarketplaceLinksTests: XCTestCase {
    func testCatalogAndNumericReferencesOpenTheSameCanonicalProductPage() {
        for reference in ["p:512035", "512035", "p:000512035"] {
            XCTAssertEqual(MarketplaceLinks.tcgplayerProduct(reference)?.absoluteString,
                           "https://www.tcgplayer.com/product/512035")
        }
    }

    func testMockOtherProvidersAndMalformedReferencesCannotBecomeLinks() {
        for reference in ["", "p:", "p:0", "0", "-1", "p:-1", "p:42\n", " 42", "p:٤٢",
                          "p:42/other", "p:42?condition=private", "p:42#fragment", "p:42@evil.example",
                          "https://evil.example/42", "https://www.tcgplayer.com/product/42", "mock:42", "mp:42",
                          "p:1234567890123", "1234567890123"] {
            XCTAssertNil(MarketplaceLinks.tcgplayerProduct(reference), reference)
        }
    }

    func testLinksContainOnlyTheFixedPublicHTTPSProductDestination() {
        let url = MarketplaceLinks.tcgplayerProduct("p:42")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "www.tcgplayer.com")
        XCTAssertEqual(url?.path, "/product/42")
        XCTAssertNil(url?.user); XCTAssertNil(url?.password)
        XCTAssertNil(url?.port); XCTAssertNil(url?.query); XCTAssertNil(url?.fragment)
    }
}
