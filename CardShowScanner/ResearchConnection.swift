import Foundation
import Security
import SwiftUI

enum ResearchAccessMethod: String, CaseIterable, Identifiable, Sendable {
    case direct, server
    static let defaultsKey = "researchAccessMethod"
    var id: Self { self }
    var label: String { self == .direct ? "Direct TCGTracking" : "My Server" }
    static func selected(defaults: UserDefaults = .standard, store: ResearchConnectionStore = .init()) throws -> Self {
        if let value = defaults.string(forKey: defaultsKey), let method = Self(rawValue: value) { return method }
        return try store.load() == nil ? .direct : .server
    }
}

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
        case .storage: return "TCGTracking API connection settings could not be read or saved. Unlock this iPhone and retry."
        case .invalidResponse: return "The server did not return the expected API connection response."
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

    private var directQuery: [String: Any] {
        var value = query; value[kSecAttrAccount as String] = "ResearchDirect"; return value
    }
    func loadDirect() throws -> DirectResearchCredentials? {
        var request = directQuery
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let decoded = try? JSONDecoder().decode(DirectResearchCredentials.self, from: data) else {
            throw ResearchConnectionFailure.storage
        }
        return try .validated(shipperID: decoded.shipperID, apiKey: decoded.apiKey)
    }
    func saveDirect(_ credentials: DirectResearchCredentials) throws {
        let checked = try DirectResearchCredentials.validated(shipperID: credentials.shipperID, apiKey: credentials.apiKey)
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(checked),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(directQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ResearchConnectionFailure.storage }
        var item = directQuery; item.merge(attributes) { _, value in value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ResearchConnectionFailure.storage }
    }
    func deleteDirect() throws {
        let status = SecItemDelete(directQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ResearchConnectionFailure.storage }
    }
}

struct ConfiguredResearchProvider: ResearchProviding {
    func research(for card: CardCandidate, forceRefresh: Bool) async throws -> ResearchProductDetails {
        let store = ResearchConnectionStore()
        let method = try ResearchAccessMethod.selected(store: store)
        await ServiceDiagnosticFields.record("research.provider_selected", method: method, phase: .setup)
        switch method {
        case .direct:
            guard let credentials = try store.loadDirect() else { throw ResearchFailure.directNotConfigured }
            return try await DirectResearchClient(credentials: credentials).research(for: card, forceRefresh: forceRefresh)
        case .server:
            guard let connection = try store.load() else { throw ResearchFailure.notConfigured }
            return try await ResearchClient(baseURL: connection.baseURL, token: connection.deviceToken)
                .research(for: card, forceRefresh: forceRefresh)
        }
    }
}

struct ResearchServerHealth: Decodable, Sendable {
    let status: String
    let researchConfigured: Bool
    let psaConfigured: Bool
    let opportunitiesConfigured: Bool?

    var marketActivityStatus: String {
        switch opportunitiesConfigured {
        case .some(true): return "configured"
        case .some(false): return "needs server credentials"
        case .none: return "not reported by this server"
        }
    }
}

struct ResearchConnectionView: View {
    private enum Field: Hashable { case shipperID, apiKey, address, token }
    @FocusState private var focusedField: Field?
    @State private var method: ResearchAccessMethod = .direct
    @State private var shipperID = ""
    @State private var apiKey = ""
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
            Section("Access method") {
                Picker("Beta API requests", selection: $method) {
                    ForEach(ResearchAccessMethod.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.menu).disabled(busy).accessibilityIdentifier("researchConnection.method")
                Text("Save Connection applies this access method to raw market activity and graded research. Public Open API pricing works without these credentials. Saved prices and offers are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if method == .direct {
                Section("TCGTracking Beta API") {
                    TextField("Shipper ID", text: $shipperID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
                        .focused($focusedField, equals: .shipperID)
                        .accessibilityIdentifier("researchConnection.shipperID")
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
                        .focused($focusedField, equals: .apiKey)
                        .accessibilityIdentifier("researchConnection.apiKey")
                    Text("Requests go directly to beta.tcgtracking.com. Your entered credentials stay in this iPhone’s device-only Keychain and are sent only to that service.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Your subscription must permit the requested Beta API and this phone’s public network IP must be on TCGTracking’s allowlist. Changing Wi-Fi or cellular networks may require updating that allowlist.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("My API server") {
                    TextField("HTTPS server address", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
                        .focused($focusedField, equals: .address)
                        .accessibilityIdentifier("researchConnection.address")
                    SecureField("Device access token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
                        .focused($focusedField, equals: .token)
                        .accessibilityIdentifier("researchConnection.token")
                    Text("Use the device token issued by your own server. The server stores your TCGTracking and PSA provider keys and uses its allowlisted outbound IP.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Save Connection") { save() }.disabled(busy).accessibilityIdentifier("researchConnection.save")
                Button("Test Market Activity") { test(marketActivity: true) }.disabled(busy)
                    .accessibilityIdentifier("researchConnection.testMarketActivity")
                Button("Test Graded Research") { test() }.disabled(busy).accessibilityIdentifier("researchConnection.test")
                if busy { ProgressView("Checking access…") }
                Button("Forget This Connection", role: .destructive) { forget() }.disabled(busy)
                Text("The tests check each API independently with the entered settings. You can save valid credentials without running either test. A successful test does not guarantee coverage for a particular card.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Section { Text(message).accessibilityIdentifier("researchConnection.status") } }
            Section("Raw market activity (OppsV2)") {
                Text("Market Details can show exact-condition reported sales and comparable listings from active opportunities. This optional Beta API does not cover every card; missing coverage does not mean zero sales or listings.")
                Text("Market Details is read-only. Browsing activity preserves saved inventory prices and offers.")
            }
            Section("Graded Research (experimental)") {
                Text("Research shows catalog-linked sales, population and valuation estimates. This API remains experimental. Coverage varies by product, printing, language and grade.")
                Text("Automatic PSA certificate lookup uses your saved server connection and its authorized certification adapter, even if research requests use Direct TCGTracking. Without that adapter, find the card and select its grade manually.")
                Text("Research is separate from inventory market pricing and saved offers.")
            }
        }.navigationTitle("TCGTracking API Connection").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }.accessibilityIdentifier("researchConnection.keyboardDone")
                }
            }
            .onAppear { load() }
            .onDisappear { cancelProbe() }
            .onChange(of: method) { _, _ in cancelProbe(); message = nil }
            .onChange(of: address) { _, value in
                if let tokenOrigin, value != tokenOrigin {
                    token = ""; self.tokenOrigin = nil
                    message = "Enter the device token for this server address."
                }
            }
    }

    private func load() {
        do {
            method = try ResearchAccessMethod.selected(store: store)
            if let connection = try store.load() {
                tokenOrigin = connection.baseURL.absoluteString
                address = connection.baseURL.absoluteString; token = connection.deviceToken
            }
            if let credentials = try store.loadDirect() { shipperID = credentials.shipperID; apiKey = credentials.apiKey }
        } catch { message = error.localizedDescription }
    }
    private func save() {
        focusedField = nil
        do {
            switch method {
            case .direct:
                try store.saveDirect(.validated(shipperID: shipperID, apiKey: apiKey))
                Task { await DirectResearchSetCache.shared.clear() }
            case .server:
                let configuration = try ResearchServerConfiguration.validated(address: address, token: token)
                try store.save(configuration)
                tokenOrigin = configuration.baseURL.absoluteString; address = configuration.baseURL.absoluteString
            }
            Task { await OpportunitiesSetCache.shared.clear() }
            UserDefaults.standard.set(method.rawValue, forKey: ResearchAccessMethod.defaultsKey)
            message = method.label + " connection saved on this iPhone."
            DiagnosticLog.shared.record("research.connection_saved", ["method": method.rawValue])
        } catch { message = error.localizedDescription }
    }
    private func forget() {
        cancelProbe()
        do {
            switch method {
            case .direct:
                try store.deleteDirect(); shipperID = ""; apiKey = ""
                Task { await DirectResearchSetCache.shared.clear() }
            case .server:
                try store.delete(); tokenOrigin = nil; address = ""; token = ""
            }
            Task { await OpportunitiesSetCache.shared.clear() }
            message = method.label + " connection removed."
        } catch { message = error.localizedDescription }
    }
    private func cancelProbe() { probeID = UUID(); probe?.cancel(); probe = nil; busy = false }
    private func test(marketActivity: Bool = false) {
        focusedField = nil
        let target: ResearchConnectionProbe
        let diagnosticPrefix = marketActivity ? "opportunities" : "research"
        do {
            switch method {
            case .direct: target = .direct(try .validated(shipperID: shipperID, apiKey: apiKey))
            case .server: target = .server(try .validated(address: address, token: token))
            }
        } catch {
            message = error.localizedDescription
            var fields = ServiceDiagnosticFields.failure(error)
            fields["method"] = method.rawValue; fields["phase"] = "setup"
            DiagnosticLog.shared.record(diagnosticPrefix + ".connection_check_failed", fields)
            return
        }
        cancelProbe()
        let requestID = UUID(); probeID = requestID
        busy = true; message = nil
        DiagnosticLog.shared.record(diagnosticPrefix + ".connection_check_started", ["method": method.rawValue])
        probe = Task { @MainActor in
            defer { if probeID == requestID { busy = false; probe = nil } }
            do {
                let result: String
                if marketActivity { result = try await target.checkMarketActivity() }
                else { result = try await target.check() }
                try Task.checkCancellation()
                guard probeID == requestID else { return }
                message = result
                DiagnosticLog.shared.record(diagnosticPrefix + ".connection_checked", ["method": method.rawValue])
            } catch {
                guard !Task.isCancelled, probeID == requestID else { return }
                message = (error as? LocalizedError)?.errorDescription
                    ?? (marketActivity ? "Market activity could not connect. Check your connection and retry." : "Research could not connect. Check your connection and retry.")
                var fields = ServiceDiagnosticFields.failure(error)
                fields["method"] = method.rawValue
                DiagnosticLog.shared.record(diagnosticPrefix + ".connection_check_failed", fields)
            }
        }
    }
}

private enum ResearchConnectionProbe: Sendable {
    case direct(DirectResearchCredentials), server(ResearchServerConfiguration)

    func check() async throws -> String {
        switch self {
        case .direct(let credentials):
            try await DirectResearchClient(credentials: credentials).testConnection()
            return "Connected directly to TCGTracking Graded Research from this network. Save Connection to use these settings. Card coverage is checked when you open research."
        case .server(let connection):
            let health = try await Self.serverHealth(connection)
            return "Connected. Graded research: \(health.researchConfigured ? "configured" : "needs server credentials"). PSA lookup: \(health.psaConfigured ? "configured" : "not configured"). Raw market activity: \(health.marketActivityStatus). Save Connection to use these settings."
        }
    }

    func checkMarketActivity() async throws -> String {
        switch self {
        case .direct(let credentials):
            try await DirectOpportunitiesClient(credentials: credentials).testConnection()
            return "Connected directly to TCGTracking Market Activity from this network. Save Connection to use these settings. OppsV2 covers active opportunities; exact card coverage is checked in Market Details."
        case .server(let connection):
            let health = try await Self.serverHealth(connection)
            return "Connected to your server. Raw market activity: \(health.marketActivityStatus). Save Connection to use these settings. OppsV2 covers active opportunities; exact card coverage is checked in Market Details."
        }
    }

    private static func serverHealth(_ connection: ResearchServerConfiguration) async throws -> ResearchServerHealth {
        var request = URLRequest(url: connection.baseURL.appendingPathComponent("api/v1/health"), timeoutInterval: 25)
        request.setValue("Bearer " + connection.deviceToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let started = Date()
        await ServiceDiagnosticFields.record("research.http_started", method: .server, phase: .serverHealth)
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await NativeResearchHTTPDataLoader().data(for: request) }
        catch {
            try Task.checkCancellation()
            await ServiceDiagnosticFields.record("research.http_failed", method: .server, phase: .serverHealth, started: started, error: error)
            throw error
        }
        try Task.checkCancellation()
        await ServiceDiagnosticFields.record("research.http_response", method: .server, phase: .serverHealth, status: response.statusCode, started: started)
        guard response.url == request.url else { throw ResearchConnectionFailure.invalidResponse }
        if response.statusCode == 401 { throw ResearchFailure.authorizationRequired }
        guard response.statusCode == 200, let health = try? JSONDecoder().decode(ResearchServerHealth.self, from: data), health.status == "ok" else {
            throw ResearchConnectionFailure.invalidResponse
        }
        return health
    }
}
