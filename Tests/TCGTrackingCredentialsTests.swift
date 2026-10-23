import XCTest
import Security
@testable import CardShowScanner

@MainActor final class TCGTrackingCredentialsTests: XCTestCase {
    func testDeviceKeychainRoundTripUpdatesAndDeletesOnlyItsOwnRecord() async throws {
        let service = "CardShowScannerTests.signin." + UUID().uuidString
        let otherService = service + ".other"
        let store = TCGTrackingCredentialStore(service: service)
        let other = TCGTrackingCredentialStore(service: otherService)
        defer { try? store.delete(); try? other.delete() }
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.delete(), "Deleting a missing saved sign-in is idempotent")

        let first = TCGTrackingCredentials(username: "fixture+é@example.test", password: "fixture-密碼-🔐")
        let updated = TCGTrackingCredentials(username: "updated@example.test", password: "second-fixture-password")
        try store.save(first)
        XCTAssertEqual(try TCGTrackingCredentialStore(service: service).load(), first)
        XCTAssertNil(try other.load())
        try other.save(first)
        try store.save(updated)
        XCTAssertEqual(try store.load(), updated)
        XCTAssertEqual(try other.load(), first)

        // Inspect attributes of this test-only record, never production values.
        var attributes: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "TCGTracking",
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &attributes), errSecSuccess)
        let stored = try XCTUnwrap(attributes as? [String: Any])
        XCTAssertEqual(stored[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertFalse(stored[kSecAttrSynchronizable as String] as? Bool ?? false)

        try store.delete()
        XCTAssertNil(try store.load())
        XCTAssertEqual(try other.load(), first, "Removing one app-scoped record must not affect another service")
        XCTAssertEqual(String(describing: updated), "TCGTrackingCredentials(<redacted>)")
        XCTAssertEqual(String(reflecting: updated), "TCGTrackingCredentials(<redacted>)")
    }
}
