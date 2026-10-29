import XCTest
import Security
@testable import CardShowScanner

@MainActor final class ResearchConnectionTests: XCTestCase {
    private let token = String(repeating: "fixture-device-token-", count: 3)

    func testConnectionAcceptsOnlyHTTPSOriginsAndBoundedTokens() async throws {
        let configuration = try ResearchServerConfiguration.validated(address: " https://research.example.com/ ", token: token)
        XCTAssertEqual(configuration.baseURL.absoluteString, "https://research.example.com")
        for address in ["http://research.example.com", "https://user:password@research.example.com", "https://research.example.com/api", "https://research.example.com?key=test", "https://research.example.com#token", "file:///tmp/research", "", "research.example.com"] {
            XCTAssertThrowsError(try ResearchServerConfiguration.validated(address: address, token: token))
        }
        for invalidToken in ["", String(repeating: "x", count: 31), String(repeating: "x", count: 513), token + "\r\nheader", token + " space", token + "é"] {
            XCTAssertThrowsError(try ResearchServerConfiguration.validated(address: "https://research.example.com", token: invalidToken))
        }
        XCTAssertNoThrow(try ResearchServerConfiguration.validated(address: "https://research.example.com", token: String(repeating: "x", count: 512)))
    }

    func testConnectionDescriptionsNeverExposeAddressOrToken() async throws {
        let configuration = try ResearchServerConfiguration.validated(address: "https://private.example.com", token: token)
        for rendered in [String(describing: configuration), String(reflecting: configuration), configuration.debugDescription] {
            XCTAssertFalse(rendered.contains(token)); XCTAssertFalse(rendered.contains("private.example.com"))
        }
    }

    func testKeychainStoresOriginAndItsTokenTogetherAndCanForgetIt() async throws {
        let store = ResearchConnectionStore(service: "ResearchConnectionTests." + UUID().uuidString)
        defer { try? store.delete() }
        XCTAssertNil(try store.load())
        let original = try ResearchServerConfiguration.validated(address: "https://first.example.com", token: token)
        try store.save(original); XCTAssertEqual(try store.load(), original)
        let replacement = try ResearchServerConfiguration.validated(address: "https://second.example.com", token: token + "replacement")
        try store.save(replacement); XCTAssertEqual(try store.load(), replacement)
        try store.delete(); XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.delete())
    }

    func testMalformedKeychainRecordFailsWithoutExposingItsContents() async throws {
        let service = "ResearchConnectionTests." + UUID().uuidString
        let store = ResearchConnectionStore(service: service)
        defer { try? store.delete() }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "ResearchServer",
            kSecAttrSynchronizable as String: false, kSecValueData as String: Data("broken-secret-record".utf8)]
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertFalse(error.localizedDescription.contains("broken-secret-record"))
        }
    }
}
