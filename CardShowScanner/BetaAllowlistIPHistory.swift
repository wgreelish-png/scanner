import Foundation
import Security
import CryptoKit

@MainActor protocol BetaAllowlistIPHistoryStoring {
    func previousIP(for shipperID: String) throws -> String?
    func remember(_ ip: String, for shipperID: String) throws
}

enum BetaAllowlistIPHistoryFailure: LocalizedError, Equatable, Sendable {
    case invalidAccount, invalidAddress, invalidRecord, read, save
    var errorDescription: String? {
        switch self {
        case .invalidAccount, .invalidAddress, .invalidRecord:
            return "This iPhone’s saved IP history could not be verified. Its allowed addresses have been kept."
        case .read:
            return "Unlock this iPhone and retry reading its saved IP history. Its allowed addresses have been kept."
        case .save:
            return "This iPhone’s current IP could not be remembered. Recheck IP access before relying on automatic updates."
        }
    }
}

/// Public addresses are device history, not account-wide ownership. A
/// ThisDeviceOnly record cannot move to another iPhone through backup/iCloud.
/// The native runner writes only after it verifies the provider's saved list.
@MainActor final class BetaAllowlistIPHistoryStore: BetaAllowlistIPHistoryStoring {
    typealias Read = @MainActor ([String: Any]) -> (status: OSStatus, data: Data?)
    typealias Update = @MainActor ([String: Any], [String: Any]) -> OSStatus
    typealias Add = @MainActor ([String: Any]) -> OSStatus

    private struct Record: Codable {
        let version: Int
        let accountDigest: String
        let ip: String
    }
    private let service: String
    private let read: Read
    private let update: Update
    private let add: Add

    init(service: String? = nil, read: Read? = nil, update: Update? = nil, add: Add? = nil) {
        self.service = service ?? ((Bundle.main.bundleIdentifier ?? "com.cardshow.CardShowScanner") + ".beta-device-ip-history")
        self.read = read ?? Self.readKeychain
        self.update = update ?? Self.updateKeychain
        self.add = add ?? Self.addKeychain
    }

    func previousIP(for shipperID: String) throws -> String? {
        let digest = try Self.accountDigest(shipperID)
        var request = query(digest: digest)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = read(request)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else { throw BetaAllowlistIPHistoryFailure.read }
        guard let data = result.data, data.count <= 1024,
              let value = try? JSONDecoder().decode(Record.self, from: data),
              value.version == 1, value.accountDigest == digest,
              let canonical = BetaAllowlistAddress.canonical(value.ip) else {
            throw BetaAllowlistIPHistoryFailure.invalidRecord
        }
        return canonical
    }

    func remember(_ ip: String, for shipperID: String) throws {
        let digest = try Self.accountDigest(shipperID)
        guard let canonical = BetaAllowlistAddress.canonical(ip) else { throw BetaAllowlistIPHistoryFailure.invalidAddress }
        let data = try JSONEncoder().encode(Record(version: 1, accountDigest: digest, ip: canonical))
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let key = query(digest: digest)
        let status = update(key, attributes)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw BetaAllowlistIPHistoryFailure.save }
        var record = key
        record.merge(attributes) { _, value in value }
        guard add(record) == errSecSuccess else { throw BetaAllowlistIPHistoryFailure.save }
    }

    private func query(digest: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: digest,
         kSecAttrSynchronizable as String: false]
    }

    private static func accountDigest(_ raw: String) throws -> String {
        // Match DirectResearchCredentials' account validation without using or
        // retaining the API key. Changing a key does not change phone ownership.
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(value.utf8.count), value.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw BetaAllowlistIPHistoryFailure.invalidAccount
        }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func readKeychain(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        return (status, value as? Data)
    }
    private static func updateKeychain(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    private static func addKeychain(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
