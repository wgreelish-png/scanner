import Foundation
import Security
import SwiftUI

struct ResearchServerConfiguration: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let baseURL: URL
    let deviceToken: String
    var description: String { "ResearchServerConfiguration(<redacted>)" }
    var debugDescription: String { description }

    static func validated(address: String, token: String) throws -> Self {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), ResearchClient.validBaseURL(url),
              url.path.isEmpty || url.path == "/", url.absoluteString.count <= 2_048,
              (32...512).contains(token.utf8.count),
              token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw ResearchConnectionFailure.invalidConfiguration
        }
        guard let origin = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let normalized = URL(string: "https://" + (origin.percentEncodedHost ?? "") + (origin.port.map { ":\($0)" } ?? "")) else {
            throw ResearchConnectionFailure.invalidConfiguration
        }
        return Self(baseURL: normalized, deviceToken: token)
    }
}

enum ResearchConnectionFailure: LocalizedError {
    case invalidConfiguration, storage, invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Enter your server’s HTTPS origin, such as https://research.example.com, and its device access token (at least 32 characters). Do not enter a TCGTracking or PSA API key."
        case .storage: return "Research connection settings could not be read or saved. Unlock this iPhone and retry."
        case .invalidResponse: return "The server did not return the expected research connection response."
        }
    }
}

/// Own-server credentials only, bound to their origin in one device-only record.
struct ResearchConnectionStore: Sendable {
    private let service: String
    init(service: String? = nil) {
        self.service = service ?? ((Bundle.main.bundleIdentifier ?? "com.cardshow.CardShowScanner") + ".research-connection")
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "ResearchServer", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> ResearchServerConfiguration? {
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let decoded = try? JSONDecoder().decode(ResearchServerConfiguration.self, from: data) else {
            throw ResearchConnectionFailure.storage
        }
        return try .validated(address: decoded.baseURL.absoluteString, token: decoded.deviceToken)
    }
    func save(_ configuration: ResearchServerConfiguration) throws {
        let checked = try ResearchServerConfiguration.validated(address: configuration.baseURL.absoluteString, token: configuration.deviceToken)
        let data = try JSONEncoder().encode(checked)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ResearchConnectionFailure.storage }
        var item = query; item.merge(attributes) { _, value in value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ResearchConnectionFailure.storage }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ResearchConnectionFailure.storage }
    }
}

struct ConfiguredResearchProvider: ResearchProviding {
    func research(for card: CardCandidate, forceRefresh: Bool) async throws -> ResearchProductDetails {
        guard let connection = try ResearchConnectionStore().load() else { throw ResearchFailure.notConfigured }
        return try await ResearchClient(baseURL: connection.baseURL, token: connection.deviceToken)
            .research(for: card, forceRefresh: forceRefresh)
    }
}

struct ResearchServerHealth: Decodable, Sendable {
    let status: String
    let researchConfigured: Bool
    let psaConfigured: Bool
}

struct ResearchConnectionView: View {
    @State private var address = ""
    @State private var token = ""
    @State private var message: String?
    @State private var busy = false
    @State private var probe: Task<Void, Never>?
    @State private var probeID = UUID()
    @State private var tokenOrigin: String?
    private let store = ResearchConnectionStore()

    var body: some View {
        Form {
            Section("Research server") {
                TextField("HTTPS server address", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(busy)
                    .accessibilityIdentifier("researchConnection.address")
                SecureField("Device access token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(busy)
                    .accessibilityIdentifier("researchConnection.token")
                Text("Use the device token issued by your own server. TCGTracking and PSA account keys stay on that server.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save Connection") { save() }.disabled(busy)
                    .accessibilityIdentifier("researchConnection.save")
                Button(busy ? "Checking…" : "Test Connection") { test() }.disabled(busy)
                    .accessibilityIdentifier("researchConnection.test")
                Button("Forget Connection", role: .destructive) {
                    probe?.cancel()
                    do { try store.delete(); address = ""; token = ""; message = "Research connection removed." }
                    catch { message = error.localizedDescription }
                }.disabled(busy)
            }
            if let message { Section { Text(message).accessibilityIdentifier("researchConnection.status") } }
            Section("Research and PSA slabs") {
                Text("Research shows catalog-linked sales, population and valuation estimates. Coverage varies by product, printing, language and grade.")
                Text("PSA barcode lookup also requires your server’s authorized certification lookup adapter. When that is unavailable, enter the card’s metadata and confirm a catalog match manually.")
                Text("Research is separate from inventory market pricing and saved offers.")
            }
        }.navigationTitle("Research Connection").navigationBarTitleDisplayMode(.inline)
            .onAppear { load() }
            .onDisappear { probeID = UUID(); probe?.cancel(); probe = nil; busy = false }
            .onChange(of: address) { _, value in
                if let tokenOrigin, value != tokenOrigin {
                    token = ""; self.tokenOrigin = nil
                    message = "Enter the device token for this server address."
                }
            }
    }

    private func load() {
        do {
            if let connection = try store.load() {
                tokenOrigin = connection.baseURL.absoluteString
                address = connection.baseURL.absoluteString; token = connection.deviceToken
            }
        } catch { message = error.localizedDescription }
    }
    private func save() {
        do {
            let configuration = try ResearchServerConfiguration.validated(address: address, token: token)
            try store.save(configuration)
            tokenOrigin = configuration.baseURL.absoluteString; address = configuration.baseURL.absoluteString
            message = "Research connection saved on this iPhone."
            DiagnosticLog.shared.record("research.connection_saved")
        } catch { message = error.localizedDescription }
    }
    private func test() {
        let connection: ResearchServerConfiguration
        do { connection = try .validated(address: address, token: token) }
        catch { message = error.localizedDescription; return }
        probe?.cancel()
        let requestID = UUID(); probeID = requestID
        busy = true; message = nil
        probe = Task { @MainActor in
            defer { if probeID == requestID { busy = false; probe = nil } }
            do {
                var request = URLRequest(url: connection.baseURL.appendingPathComponent("api/v1/health"), timeoutInterval: 25)
                request.setValue("Bearer " + connection.deviceToken, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await NativeResearchHTTPDataLoader().data(for: request)
                try Task.checkCancellation()
                guard probeID == requestID else { return }
                guard response.url == request.url else { throw ResearchConnectionFailure.invalidResponse }
                if response.statusCode == 401 { throw ResearchFailure.authorizationRequired }
                guard response.statusCode == 200, let health = try? JSONDecoder().decode(ResearchServerHealth.self, from: data), health.status == "ok" else {
                    throw ResearchConnectionFailure.invalidResponse
                }
                message = "Connected. Research: \(health.researchConfigured ? "configured" : "needs server credentials"). PSA lookup: \(health.psaConfigured ? "configured" : "not configured"). Save Connection to use these settings."
                DiagnosticLog.shared.record("research.connection_checked", ["research_configured": String(health.researchConfigured), "psa_configured": String(health.psaConfigured)])
            } catch {
                guard !Task.isCancelled, probeID == requestID else { return }
                message = (error as? LocalizedError)?.errorDescription ?? "The research server could not be reached."
                DiagnosticLog.shared.record("research.connection_check_failed")
            }
        }
    }
}
