import XCTest
import Security
@testable import CardShowScanner

@MainActor final class BetaAllowlistIPHistoryTests: XCTestCase {
    @MainActor private final class Keychain {
        var values: [String: Data] = [:]
        var readStatus: OSStatus?
        var updateStatus: OSStatus?
        var addStatus: OSStatus?
        var reads = 0
        var updates = 0
        var adds = 0
        var lastQuery: [String: Any] = [:]
        var lastAttributes: [String: Any] = [:]

        private func key(_ query: [String: Any]) -> String {
            (query[kSecAttrService as String] as? String ?? "") + "\0" + (query[kSecAttrAccount as String] as? String ?? "")
        }
        func store(service: String = "CardShowScannerTests.device-history") -> BetaAllowlistIPHistoryStore {
            BetaAllowlistIPHistoryStore(service: service, read: { query in
                self.reads += 1; self.lastQuery = query
                if let status = self.readStatus { return (status, nil) }
                guard let data = self.values[self.key(query)] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data)
            }, update: { query, attributes in
                self.updates += 1; self.lastQuery = query; self.lastAttributes = attributes
                if let status = self.updateStatus { return status }
                let key = self.key(query)
                guard self.values[key] != nil else { return errSecItemNotFound }
                self.values[key] = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            }, add: { attributes in
                self.adds += 1; self.lastQuery = attributes; self.lastAttributes = attributes
                if let status = self.addStatus { return status }
                guard let data = attributes[kSecValueData as String] as? Data else { return errSecDecode }
                self.values[self.key(attributes)] = data
                return errSecSuccess
            })
        }
    }

    func testFirstRunHasNoInferredPreviousAddressAndWritesNothing() throws {
        let keychain = Keychain(), store = keychain.store()
        XCTAssertNil(try store.previousIP(for: "123"))
        XCTAssertEqual(keychain.reads, 1); XCTAssertEqual(keychain.updates, 0); XCTAssertEqual(keychain.adds, 0)
        XCTAssertTrue(keychain.values.isEmpty)
    }

    func testCanonicalAddressSurvivesStoreRecreationAndKeyRotationForSameShipper() throws {
        let keychain = Keychain()
        try keychain.store().remember("2001:4860:4860:0000:0000:0000:0000:8888", for: "123")
        XCTAssertEqual(try keychain.store().previousIP(for: "123"), "2001:4860:4860::8888")
        // This interface deliberately contains no API key, so rotating the key
        // does not reset ownership for the same account on this iPhone.
        try keychain.store().remember("::ffff:8.8.8.8", for: " 123 ")
        XCTAssertEqual(try keychain.store().previousIP(for: "123"), "8.8.8.8")
        XCTAssertEqual(keychain.values.count, 1)
    }

    func testAccountsAndServicesHaveIndependentHistory() throws {
        let keychain = Keychain(), first = keychain.store(), other = keychain.store(service: "OtherApp.device-history")
        try first.remember("8.8.8.8", for: "123")
        XCTAssertNil(try first.previousIP(for: "456")); XCTAssertNil(try other.previousIP(for: "123"))
        try first.remember("1.1.1.1", for: "456")
        try other.remember("9.9.9.9", for: "123")
        try first.remember("8.8.4.4", for: "123")
        XCTAssertEqual(try first.previousIP(for: "123"), "8.8.4.4")
        XCTAssertEqual(try first.previousIP(for: "456"), "1.1.1.1")
        XCTAssertEqual(try other.previousIP(for: "123"), "9.9.9.9")
    }

    func testHistoryUsesThisDeviceOnlyAndNeverSynchronizesOrExposesAccountInMetadata() throws {
        let keychain = Keychain(), store = keychain.store()
        try store.remember("8.8.8.8", for: "private-shipper")
        XCTAssertEqual(keychain.lastAttributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(keychain.lastQuery[kSecAttrSynchronizable as String] as? Bool, false)
        let account = try XCTUnwrap(keychain.lastQuery[kSecAttrAccount as String] as? String)
        XCTAssertEqual(account.count, 64); XCTAssertFalse(account.contains("private-shipper"))
        XCTAssertFalse(account.contains("8.8.8.8"))
        let data = try XCTUnwrap(keychain.lastAttributes[kSecValueData as String] as? Data)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-shipper"))
    }

    func testMalformedUnsupportedOversizedAndWrongAccountRecordsFailClosed() throws {
        let keychain = Keychain(), store = keychain.store()
        try store.remember("8.8.8.8", for: "123")
        let sourceKey = try XCTUnwrap(keychain.values.keys.first)
        let original = try XCTUnwrap(keychain.values[sourceKey])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var badVersion = body; badVersion["version"] = 2
        var privateIP = body; privateIP["ip"] = "10.0.0.1"
        var wrongAccount = body; wrongAccount["accountDigest"] = String(repeating: "0", count: 64)
        let cases = [Data("invalid JSON".utf8), Data(repeating: 32, count: 1025),
            try JSONSerialization.data(withJSONObject: badVersion),
            try JSONSerialization.data(withJSONObject: privateIP),
            try JSONSerialization.data(withJSONObject: wrongAccount)]
        let writes = keychain.updates + keychain.adds
        for data in cases {
            keychain.values[sourceKey] = data
            XCTAssertThrowsError(try store.previousIP(for: "123")) {
                XCTAssertEqual($0 as? BetaAllowlistIPHistoryFailure, .invalidRecord)
            }
        }
        XCTAssertEqual(keychain.updates + keychain.adds, writes)
    }

    func testReadAndWriteKeychainFailuresDoNotOverwriteRememberedHistory() throws {
        let keychain = Keychain(), store = keychain.store()
        try store.remember("8.8.8.8", for: "123")
        let saved = keychain.values, writes = keychain.updates + keychain.adds
        keychain.readStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.previousIP(for: "123")) {
            XCTAssertEqual($0 as? BetaAllowlistIPHistoryFailure, .read)
        }
        XCTAssertEqual(keychain.updates + keychain.adds, writes)
        keychain.readStatus = nil; keychain.updateStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.remember("1.1.1.1", for: "123")) {
            XCTAssertEqual($0 as? BetaAllowlistIPHistoryFailure, .save)
        }
        XCTAssertEqual(keychain.values, saved)
        keychain.updateStatus = nil; keychain.addStatus = errSecNotAvailable
        XCTAssertThrowsError(try store.remember("9.9.9.9", for: "456")) {
            XCTAssertEqual($0 as? BetaAllowlistIPHistoryFailure, .save)
        }
        XCTAssertEqual(keychain.values, saved)
    }

    func testInvalidAccountsAndAddressesAreRejectedBeforeKeychainMutation() throws {
        let keychain = Keychain(), store = keychain.store()
        for account in ["", " ", "bad account", "bad\naccount", String(repeating: "x", count: 129), "é"] {
            XCTAssertThrowsError(try store.previousIP(for: account))
            XCTAssertThrowsError(try store.remember("8.8.8.8", for: account))
        }
        for ip in ["10.0.0.1", "127.0.0.1", "8.8.8.0/24", "https://8.8.8.8", "not an IP", ""] {
            XCTAssertThrowsError(try store.remember(ip, for: "123"))
        }
        XCTAssertTrue(keychain.values.isEmpty); XCTAssertEqual(keychain.reads, 0)
        XCTAssertEqual(keychain.updates, 0); XCTAssertEqual(keychain.adds, 0)
    }
}
