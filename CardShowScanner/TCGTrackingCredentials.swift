import Foundation
import Security

/// Credentials are supplied by the user in this app, never by diagnostics or
/// copied browser cookies. Keep descriptions redacted even during debugging.
struct TCGTrackingCredentials: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var username: String
    var password: String
    var description: String { "TCGTrackingCredentials(<redacted>)" }
    var debugDescription: String { description }
}

enum TCGTrackingCredentialStoreFailure: LocalizedError {
    case read, save, delete

    var errorDescription: String? {
        switch self {
        case .read: return "Saved sign-in could not be read. Unlock the iPhone and try again, or enter your details again."
        case .save: return "Sign-in details could not be saved on this iPhone. You can still sign in without remembering them."
        case .delete: return "Saved sign-in details could not be removed. Unlock the iPhone and try again."
        }
    }
}

/// One opt-in sign-in record, scoped to this app and device. The username stays
/// inside the encrypted value rather than appearing in Keychain item metadata.
struct TCGTrackingCredentialStore {
    private let service: String
    private let account = "TCGTracking"

    init(service: String? = nil) {
        self.service = service ?? ((Bundle.main.bundleIdentifier ?? "com.cardshow.CardShowScanner") + ".tcgtracking-signin")
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> TCGTrackingCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credentials = try? JSONDecoder().decode(TCGTrackingCredentials.self, from: data) else {
            throw TCGTrackingCredentialStoreFailure.read
        }
        return credentials
    }

    func save(_ credentials: TCGTrackingCredentials) throws {
        guard let data = try? JSONEncoder().encode(credentials) else { throw TCGTrackingCredentialStoreFailure.save }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw TCGTrackingCredentialStoreFailure.save }
        var record = query
        record.merge(attributes) { _, new in new }
        guard SecItemAdd(record as CFDictionary, nil) == errSecSuccess else {
            throw TCGTrackingCredentialStoreFailure.save
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TCGTrackingCredentialStoreFailure.delete
        }
    }
}
