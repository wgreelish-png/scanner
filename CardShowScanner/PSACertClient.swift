import Foundation
import Observation

/// This is the app server's normalized certificate contract, not an invented
/// endpoint on PSA's public website. The server owns the authorized adapter.
struct PSACertificateMetadata: Decodable, Equatable, Sendable {
    let certificateNumber: String
    let grader: String
    let grade: String
    let name: String
    let year: String?
    let set: String?
    let number: String?
    let language: String?
    let printing: String?
    let imageURL: URL?
    let source: String
    let qualifiers: [String]?
    let autographGrade: String?

    var researchGrade: String {
        let missing = (qualifiers ?? []).filter { !grade.localizedCaseInsensitiveContains($0) }
        return missing.isEmpty ? grade : grade + " (" + missing.joined(separator: ", ") + ")"
    }
    var suggestedSearch: String {
        [name, number].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func decode(_ data: Data, certificateNumber: String) throws -> Self {
        guard data.count <= NativeResearchHTTPDataLoader.maximumBytes,
              let result = try? JSONDecoder().decode(Self.self, from: data),
              result.certificateNumber == certificateNumber, result.grader == "PSA",
              !result.grade.isEmpty, result.grade.count <= 100,
              !result.name.isEmpty, result.name.count <= 500,
              !result.source.isEmpty, result.source.count <= 200,
              (result.qualifiers ?? []).count <= 20,
              (result.qualifiers ?? []).allSatisfy({ !$0.isEmpty && $0.count <= 100 }),
              [result.year, result.set, result.number, result.language, result.printing, result.autographGrade]
                .allSatisfy({ ($0?.count ?? 0) <= 500 }),
              result.imageURL == nil || (result.imageURL?.scheme == "https" && result.imageURL?.host?.isEmpty == false && result.imageURL?.user == nil && result.imageURL?.password == nil)
        else { throw PSACertificateFailure.invalidResponse }
        return result
    }
}

enum PSACertificateFailure: LocalizedError, Equatable {
    case invalidCertificate, notConfigured, notFound, invalidResponse, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidCertificate: return "Enter the certificate number from the PSA label."
        case .notConfigured: return "PSA certificate lookup is not configured on the research server. You can still find the card manually below."
        case .notFound: return "No certification record was returned. Check the number or find the card manually below."
        case .invalidResponse: return "The certificate response could not be matched safely to this number. Find the card manually or retry."
        case .unavailable: return "Certificate lookup is unavailable. Retry or find the card manually below."
        }
    }
}

protocol PSACertificateLookingUp: Sendable {
    func lookup(_ certificateNumber: String) async throws -> PSACertificateMetadata
}

struct PSACertificateClient: PSACertificateLookingUp {
    let baseURL: URL
    let deviceToken: String
    private let loader: any ResearchHTTPDataLoading
    init(baseURL: URL, deviceToken: String, loader: any ResearchHTTPDataLoading = NativeResearchHTTPDataLoader()) {
        self.baseURL = baseURL; self.deviceToken = deviceToken; self.loader = loader
    }
    func lookup(_ certificateNumber: String) async throws -> PSACertificateMetadata {
        guard PSACertificateCode.parse(certificateNumber, kind: .manual)?.certificateNumber == certificateNumber else {
            throw PSACertificateFailure.invalidCertificate
        }
        guard ResearchClient.validBaseURL(baseURL), (baseURL.path.isEmpty || baseURL.path == "/"),
              !deviceToken.isEmpty, deviceToken.count <= 4096,
              !deviceToken.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ResearchFailure.notConfigured
        }
        let url = baseURL.appendingPathComponent("api/v1/psa/cert/" + certificateNumber)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + deviceToken, forHTTPHeaderField: "Authorization")
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch { try Task.checkCancellation(); throw PSACertificateFailure.unavailable }
        try Task.checkCancellation()
        guard response.url == url else { throw PSACertificateFailure.invalidResponse }
        switch response.statusCode {
        case 200: return try PSACertificateMetadata.decode(data, certificateNumber: certificateNumber)
        case 401: throw ResearchFailure.authorizationRequired
        case 403: throw ResearchFailure.accessDenied
        case 404: throw PSACertificateFailure.notFound
        case 501: throw PSACertificateFailure.notConfigured
        default: throw PSACertificateFailure.unavailable
        }
    }
}

struct ConfiguredPSACertificateLookup: PSACertificateLookingUp {
    func lookup(_ certificateNumber: String) async throws -> PSACertificateMetadata {
        guard let configuration = try ResearchConnectionStore().load() else { throw ResearchFailure.notConfigured }
        return try await PSACertificateClient(baseURL: configuration.baseURL, deviceToken: configuration.deviceToken).lookup(certificateNumber)
    }
}

@MainActor @Observable final class PSAResearchModel {
    private(set) var certificateNumber = ""
    private(set) var metadata: PSACertificateMetadata?
    private(set) var loading = false
    private(set) var message: String?
    private let lookup: any PSACertificateLookingUp
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    init(lookup: any PSACertificateLookingUp = ConfiguredPSACertificateLookup()) { self.lookup = lookup }
    func accept(_ code: PSACertificateCode) {
        cancel(); certificateNumber = code.certificateNumber; metadata = nil; message = nil; loading = true
        let request = requestID, number = certificateNumber
        task = Task { [weak self, lookup] in
            do {
                let metadata = try await lookup.lookup(number)
                guard let self, !Task.isCancelled, self.requestID == request else { return }
                guard self.certificateNumber == metadata.certificateNumber else {
                    self.loading = false; self.message = PSACertificateFailure.invalidResponse.errorDescription; return
                }
                self.metadata = metadata; self.loading = false
                DiagnosticLog.shared.record("psa.lookup_finished")
            } catch {
                guard let self, !Task.isCancelled, self.requestID == request else { return }
                self.loading = false
                self.message = (error as? LocalizedError)?.errorDescription ?? PSACertificateFailure.unavailable.errorDescription
                DiagnosticLog.shared.record("psa.lookup_failed")
            }
        }
    }
    func retry() {
        guard let code = PSACertificateCode.parse(certificateNumber, kind: .manual) else { return }
        accept(code)
    }
    func clear() { cancel(); certificateNumber = ""; metadata = nil; message = nil }
    func cancel() { task?.cancel(); task = nil; requestID = UUID(); loading = false }
}
