import Foundation
import CoreFoundation
import Observation

private let scannerGameCatalogMaximumBytes = 1_048_576

enum ScannerGameCatalogFailure: Error {
    case invalidIndex, responseTooLarge, unavailable
}

/// Discovery describes published recognition packs, not device acceptance or
/// pricing coverage. It runs only when a foreground screen explicitly requests it.
@MainActor @Observable final class ScannerGameCatalog {
    typealias Loader = @Sendable () async throws -> Data
    static let shared = ScannerGameCatalog()
    static let cacheKeysPreference = "scanner.gameCatalog.keys"
    static let cacheDatePreference = "scanner.gameCatalog.updatedAt"
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60

    private(set) var games: [String]
    private(set) var status: String?
    private(set) var isLoading = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private var lastSuccess: Date?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var request: Task<Data, Error>?

    init(defaults: UserDefaults = .standard,
         now: @escaping @MainActor () -> Date = { .now }, loader: Loader? = nil) {
        self.defaults = defaults; self.now = now
        self.loader = loader ?? { try await Self.downloadIndex() }
        let saved = defaults.array(forKey: Self.cacheKeysPreference) as? [String]
        if let saved, !saved.isEmpty, saved.count <= TCGGameRegistry.entries.count,
           saved.allSatisfy(TCGGameRegistry.isScannerKey) {
            games = TCGGameRegistry.scannerNames(forKeys: saved)
            lastSuccess = defaults.object(forKey: Self.cacheDatePreference) as? Date
            status = "Using saved scanner game choices."
        } else {
            games = TCGGameRegistry.scannerNames(forKeys: ["tcgp:3", "tcgp:1", "tcgp:2", "tcgp:68",
                "tcgp:71", "tcgp:77", "tcgp:86", "tcgp:89"])
            status = "Showing bundled scanner options until availability is checked."
        }
    }

    func refreshIfNeeded() async {
        guard !isLoading else { return }
        if let lastSuccess {
            let age = now().timeIntervalSince(lastSuccess)
            if age >= 0, age < Self.refreshInterval { return }
        }
        await refresh()
    }

    func refresh() async {
        cancel()
        let id = UUID(); requestID = id
        isLoading = true; status = "Checking available scanner games…"
        let loader = loader
        let work = Task { try await loader() }
        request = work
        defer {
            if requestID == id { request = nil; isLoading = false }
        }
        do {
            let data = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            try Task.checkCancellation()
            guard requestID == id else { return }
            let available = try Self.availableGames(in: data)
            let keys = available.compactMap(TCGGameRegistry.scannerKey(for:))
            let date = now()
            games = available
            lastSuccess = date
            defaults.set(keys, forKey: Self.cacheKeysPreference)
            defaults.set(date, forKey: Self.cacheDatePreference)
            status = "\(available.count) games have published recognition databases."
        } catch {
            guard requestID == id else { return }
            status = error is CancellationError || Task.isCancelled
                ? "Game list update paused. Saved choices are kept."
                : "Could not update scanner games. Your current choices are kept."
        }
    }

    func cancel() {
        requestID = UUID()
        request?.cancel(); request = nil
        if isLoading { status = "Game list update paused. Saved choices are kept." }
        isLoading = false
    }

    static func availableGames(in data: Data) throws -> [String] {
        guard !data.isEmpty, data.count <= scannerGameCatalogMaximumBytes else {
            throw ScannerGameCatalogFailure.responseTooLarge
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let games = root["games"] as? [String: Any], !games.isEmpty, games.count <= 4_096 else {
            throw ScannerGameCatalogFailure.invalidIndex
        }
        let keys = games.compactMap { key, value -> String? in
            guard TCGGameRegistry.isScannerKey(key), let entry = value as? [String: Any] else { return nil }
            if let count = entry["n"], !positiveInteger(count) { return nil }
            if let rawV2 = entry["v2"] {
                guard let v2 = rawV2 as? [String: Any], let manifest = v2["manifest"] as? String,
                      safeRelativePath(manifest) else { return nil }
                return key
            }
            guard let binary = entry["bin"] as? String, let metadata = entry["meta"] as? String,
                  safeRelativePath(binary), safeRelativePath(metadata), validVersion(entry["ver"]),
                  positiveInteger(entry["bin_bytes"]), positiveInteger(entry["meta_bytes"]) else { return nil }
            return key
        }
        guard !keys.isEmpty else { throw ScannerGameCatalogFailure.invalidIndex }
        return TCGGameRegistry.scannerNames(forKeys: keys)
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        guard path.range(of: #"^[A-Za-z0-9][A-Za-z0-9_./-]{0,449}$"#, options: .regularExpression) != nil else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func positiveInteger(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return false }
        let count = value.doubleValue
        return count.isFinite && count > 0 && count <= 1_000_000_000 && count.rounded() == count
    }

    private static func validVersion(_ value: Any?) -> Bool {
        let version: String
        if let text = value as? String { version = text }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            version = number.stringValue
        } else { return false }
        return version.range(of: #"^[A-Za-z0-9_.:-]{1,100}$"#, options: .regularExpression) != nil
    }

    nonisolated private static func downloadIndex() async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://nsp-static.tcgtracking.com/packs/index.json")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ScannerGameCatalogFailure.unavailable
        }
        guard response.expectedContentLength <= Int64(scannerGameCatalogMaximumBytes) else {
            throw ScannerGameCatalogFailure.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < scannerGameCatalogMaximumBytes else { throw ScannerGameCatalogFailure.responseTooLarge }
            data.append(byte)
        }
        return data
    }
}
