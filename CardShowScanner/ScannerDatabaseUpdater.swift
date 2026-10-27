import Foundation
import Combine
import CoreFoundation
import WebKit

struct ScannerDatabaseUpdateResult: Decodable, Equatable {
    enum Status: String, Decodable { case upToDate, updated, skipped, failed }
    var status: Status
    var downloadedBytes: Int64
    var cachedShards: Int
    var proposedManifestPath: String?
    var previousManifestPath: String?

    static func decode(_ value: Any?) throws -> Self {
        guard let dictionary = value as? [String: Any] else { throw ScannerDatabaseUpdateFailure.invalidResult }
        let result = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: dictionary))
        guard (0...10_000_000_000).contains(result.downloadedBytes), (0...1_000_000).contains(result.cachedShards) else {
            throw ScannerDatabaseUpdateFailure.invalidResult
        }
        if result.status == .upToDate || result.status == .updated {
            guard let proposed = result.proposedManifestPath, let previous = result.previousManifestPath,
                  ScannerDatabaseCache.validKey("M:" + proposed), ScannerDatabaseCache.validKey("M:" + previous),
                  !proposed.hasPrefix("/"), !previous.hasPrefix("/") else { throw ScannerDatabaseUpdateFailure.invalidResult }
        }
        if result.status == .upToDate && result.downloadedBytes != 0 { throw ScannerDatabaseUpdateFailure.invalidResult }
        return result
    }
}

enum ScannerDatabaseUpdateFailure: Error { case invalidResult, unavailable, timedOut, changedCache, incompleteCache }

struct ScannerDatabaseUpdatePolicy {
    static let successInterval: TimeInterval = 24 * 60 * 60
    static let failureInterval: TimeInterval = 60 * 60
    static func isDue(lastSuccess: Date?, lastFailure: Date?, now: Date) -> Bool {
        for (date, interval) in [(lastSuccess, successInterval), (lastFailure, failureInterval)] {
            if let date, date <= now, now.timeIntervalSince(date) < interval { return false }
        }
        return true
    }
}

extension ScannerDatabaseCache {
    /// A retired document can have already queued prune requests. Resolve each
    /// deletion against current native pointers in this same actor operation;
    /// the old document's earlier keep-set cannot delete a newly published pack.
    @discardableResult
    func removeIfUnreferenced(_ key: String) throws -> Bool {
        try Task.checkCancellation()
        guard Self.validKey(key) else { throw ScannerCacheFailure.invalidKey }
        guard key != "index", !key.hasPrefix("cur:") else { return false }
        do {
            for marker in try keys() where marker.hasPrefix("cur:") {
                try Task.checkCancellation()
                guard let current = try read(marker), current.first == 0,
                      let path = try JSONSerialization.jsonObject(with: Data(current.dropFirst()), options: [.fragmentsAllowed]) as? String,
                      !path.hasPrefix("/"), Self.validKey("M:" + path),
                      let data = try read("M:" + path), data.first == 0,
                      let manifest = try JSONSerialization.jsonObject(with: Data(data.dropFirst())) as? [String: Any],
                      manifest["v"] as? Int == 2, let shards = manifest["shards"] as? [[String: Any]],
                      !shards.isEmpty, shards.count <= Self.maximumKeys / 2 else { return false }
                if key == "M:" + path { return false }
                let directory = path.lastIndex(of: "/").map { String(path[...$0]) } ?? ""
                for shard in shards {
                    try Task.checkCancellation()
                    guard let hash = shard["hash"] as? String, let metadata = shard["meta"] as? String,
                          !hash.isEmpty, !metadata.isEmpty, !hash.contains("/"), !metadata.contains("/"),
                          Self.validKey("h:" + directory + hash), Self.validKey("m:" + directory + metadata) else { return false }
                    if key == "h:" + directory + hash || key == "m:" + directory + metadata { return false }
                }
            }
        } catch {
            if error is CancellationError { throw error }
            return false // A corrupt marker cannot authorize deleting any pack.
        }
        try Task.checkCancellation()
        try remove(key); return true
    }

    /// Publication is one actor operation without suspension. A scanner cancels
    /// the caller before reading the cache: a queued publication observes that
    /// cancellation, or a publication already writing finishes before any read.
    /// Staging never removes the old pack or publishes a pointer from JavaScript.
    func commitPreparedManifest(gameKey: String, previous: String, proposed: String) throws {
        try Task.checkCancellation()
        guard ["tcgp:1", "tcgp:2", "tcgp:3"].contains(gameKey),
              Self.validKey("M:" + previous), Self.validKey("M:" + proposed),
              !previous.hasPrefix("/"), !proposed.hasPrefix("/") else { throw ScannerDatabaseUpdateFailure.invalidResult }
        guard let currentData = try read("cur:" + gameKey), currentData.first == 0,
              let current = try JSONSerialization.jsonObject(with: Data(currentData.dropFirst()), options: [.fragmentsAllowed]) as? String,
              current == previous || current == proposed else { throw ScannerDatabaseUpdateFailure.changedCache }
        guard let manifestData = try read("M:" + proposed), manifestData.first == 0,
              let manifest = try JSONSerialization.jsonObject(with: Data(manifestData.dropFirst())) as? [String: Any],
              manifest["v"] as? Int == 2, let shards = manifest["shards"] as? [[String: Any]],
              !shards.isEmpty, shards.count <= Self.maximumKeys / 2 else { throw ScannerDatabaseUpdateFailure.incompleteCache }
        let directory = proposed.lastIndex(of: "/").map { String(proposed[...$0]) } ?? ""
        for shard in shards {
            try Task.checkCancellation()
            guard let hash = shard["hash"] as? String, let metadata = shard["meta"] as? String,
                  !hash.isEmpty, !metadata.isEmpty, !hash.contains("/"), !metadata.contains("/"),
                  Self.validKey("h:" + directory + hash), Self.validKey("m:" + directory + metadata),
                  let binary = try read("h:" + directory + hash), let data = try read("m:" + directory + metadata),
                  try Self.validPreparedShard(binary, metadata: data) else {
                throw ScannerDatabaseUpdateFailure.incompleteCache
            }
        }
        try Task.checkCancellation()
        guard current != proposed else { return }
        var encoded = Data([0])
        encoded.append(try JSONSerialization.data(withJSONObject: proposed, options: [.fragmentsAllowed]))
        try write("cur:" + gameKey, data: encoded)
    }

    private static func validPreparedShard(_ binary: Data, metadata: Data) throws -> Bool {
        guard binary.count >= 25, binary.prefix(9) == Data([1, 78, 83, 80, 83, 2, 0, 0, 0]), metadata.first == 0,
              let object = try JSONSerialization.jsonObject(with: Data(metadata.dropFirst())) as? [String: Any],
              let refs = object["refs"] as? [Any], let key = object["k"] as? NSNumber,
              CFGetTypeID(key) != CFBooleanGetTypeID(), key.doubleValue.isFinite,
              key.doubleValue >= 0, key.doubleValue <= Double(UInt32.max), key.doubleValue.rounded() == key.doubleValue else { return false }
        func littleEndian(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(binary[offset + $1]) << UInt32($1 * 8) }
        }
        let count = Int(littleEndian(9))
        guard count <= 500_000, refs.count == count, littleEndian(17) == UInt32(key.doubleValue) else { return false }
        let endHashes = 24 + count * 162
        let aligned = endHashes + (4 - endHashes % 4) % 4
        return binary.count >= 1 + aligned + count * 8
    }
}

@MainActor protocol ScannerDatabaseUpdateRunning: AnyObject {
    func run(gameKey: String) async throws -> ScannerDatabaseUpdateResult
    /// Synchronously retires the document before the camera receives a lease.
    func cancel()
}

/// Foreground Home-only maintenance. The scanner's lease always takes priority;
/// no recognition engine, camera, session, list or offer is involved in a check.
@MainActor final class ScannerDatabaseUpdater: ObservableObject {
    static let shared = ScannerDatabaseUpdater()
    static let enabledKey = "autoDatabaseUpdates"
    enum State: Equatable { case idle, checking, upToDate, updated, unavailable, failed, disabled }
    @Published private(set) var state: State = .idle
    var status: String {
        switch state {
        case .idle: return "Saved databases open immediately. Automatic checks run between scans."
        case .checking: return "Checking the saved game database for updates…"
        case .upToDate: return "The saved game database is up to date."
        case .updated: return "The saved game database was updated for your next scan."
        case .unavailable: return "Open the scanner once to save this game's database."
        case .failed: return "The update check could not finish. Your saved database is kept."
        case .disabled: return "Automatic database checks are off."
        }
    }
    private let defaults: UserDefaults
    private let cache: ScannerDatabaseCache
    private let runner: any ScannerDatabaseUpdateRunning
    private let now: @MainActor () -> Date
    private let wait: @MainActor (Duration) async throws -> Void
    private var visible = false
    private var foreground = true
    private var enabled: Bool
    private var game = "Pokémon"
    private var scannerLeases: Set<UUID> = []
    private var lastFailures: [String: Date] = [:]
    private var work: Task<Void, Never>?
    private var workingGame: String?
    private var generation = UUID()

    init(defaults: UserDefaults = .standard, cache: ScannerDatabaseCache = .shared,
         runner: (any ScannerDatabaseUpdateRunning)? = nil,
         now: @escaping @MainActor () -> Date = { .now },
         wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.defaults = defaults; self.cache = cache
        self.runner = runner ?? ScannerDatabaseUpdateWebRunner()
        self.now = now; self.wait = wait
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if !enabled { state = .disabled }
    }
    func lastSuccessfulCheck(for game: String) -> Date? {
        guard let key = Self.gameKey(game), let value = defaults.object(forKey: Self.successKey(key)) as? NSNumber,
              value.doubleValue.isFinite, value.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: value.doubleValue)
    }
    func setHomeVisible(_ value: Bool, game: String) {
        visible = value; self.game = game; reconsider()
    }
    func setForeground(_ value: Bool) { foreground = value; reconsider() }
    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: Self.enabledKey); reconsider()
    }
    func beginScannerUse() -> UUID {
        let lease = UUID(); scannerLeases.insert(lease)
        cancelWork(); return lease
    }
    func endScannerUse(_ lease: UUID) {
        guard scannerLeases.remove(lease) != nil else { return }
        reconsider()
    }
    private static func gameKey(_ game: String) -> String? {
        ["Pokémon": "tcgp:3", "Magic: The Gathering": "tcgp:1", "Yu-Gi-Oh!": "tcgp:2"][game]
    }
    private static func successKey(_ gameKey: String) -> String { "scanner.databaseUpdate.lastSuccess." + gameKey }
    private var allowed: Bool { visible && foreground && enabled && scannerLeases.isEmpty }
    private func cancelWork() {
        generation = UUID(); work?.cancel(); work = nil; workingGame = nil
        runner.cancel()
        state = enabled ? .idle : .disabled
    }
    private func reconsider() {
        guard allowed, let key = Self.gameKey(game) else { cancelWork(); return }
        if work != nil, workingGame == key { return }
        guard ScannerDatabaseUpdatePolicy.isDue(lastSuccess: lastSuccessfulCheck(for: game), lastFailure: lastFailures[key], now: now()) else {
            cancelWork()
            state = lastFailures[key].map { $0 <= now() && now().timeIntervalSince($0) < ScannerDatabaseUpdatePolicy.failureInterval } == true ? .failed : .upToDate
            return
        }
        cancelWork()
        let id = UUID(); generation = id; workingGame = key
        let delay = wait
        work = Task { [weak self] in
            do {
                try await delay(.seconds(2)); try Task.checkCancellation()
                guard let self, self.allowed, self.generation == id else { return }
                self.state = .checking
                DiagnosticLog.shared.record("database.auto_check_started", ["game": key])
                let result = try await self.runner.run(gameKey: key)
                try Task.checkCancellation()
                guard self.allowed, self.generation == id else { return }
                switch result.status {
                case .updated, .upToDate:
                    guard let previous = result.previousManifestPath, let proposed = result.proposedManifestPath else {
                        throw ScannerDatabaseUpdateFailure.invalidResult
                    }
                    try await self.cache.commitPreparedManifest(gameKey: key, previous: previous, proposed: proposed)
                    try Task.checkCancellation()
                    guard self.allowed, self.generation == id else { return }
                    self.defaults.set(self.now().timeIntervalSince1970, forKey: Self.successKey(key))
                    self.lastFailures[key] = nil
                    self.state = result.status == .updated ? .updated : .upToDate
                    DiagnosticLog.shared.record("database.auto_check_completed", ["game": key,
                        "downloaded_bytes": String(result.downloadedBytes), "cached_shards": String(result.cachedShards)])
                case .skipped:
                    self.state = .unavailable
                    DiagnosticLog.shared.record("database.auto_check_skipped", ["game": key])
                case .failed:
                    throw ScannerDatabaseUpdateFailure.unavailable
                }
                self.work = nil; self.workingGame = nil
            } catch {
                guard let self, self.generation == id else { return }
                self.work = nil; self.workingGame = nil
                if error is CancellationError || Task.isCancelled { self.state = .idle; return }
                self.lastFailures[key] = self.now(); self.state = .failed
                DiagnosticLog.shared.record("database.auto_check_failed", ["game": key])
            }
        }
    }
}

/// A data-only local document. It cannot request camera/microphone permission,
/// open another page/window, show JavaScript dialogs or initialize recognition.
@MainActor private final class ScannerDatabaseUpdateWebRunner: NSObject, ScannerDatabaseUpdateRunning, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView?
    private var navigation: WKNavigation?
    private var continuation: CheckedContinuation<ScannerDatabaseUpdateResult, Error>?
    private var generation: UUID?
    private var startup: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var gameKey = ""

    func run(gameKey: String) async throws -> ScannerDatabaseUpdateResult {
        cancel(); try Task.checkCancellation()
        let id = UUID(); generation = id; self.gameKey = gameKey
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self, self.generation == id else { return }
                    self.finish(.failure(ScannerDatabaseUpdateFailure.timedOut))
                }
                startup = Task { [weak self] in
                    do {
                        try await LocalScannerServer.shared.start(); try Task.checkCancellation()
                        guard let self, self.generation == id else { return }
                        let config = WKWebViewConfiguration()
                        config.websiteDataStore = .default()
                        config.preferences.javaScriptCanOpenWindowsAutomatically = false
                        let view = WKWebView(frame: .zero, configuration: config)
                        self.webView = view; view.navigationDelegate = self; view.uiDelegate = self
                        self.navigation = view.load(URLRequest(url: LocalScannerServer.pageURL))
                        if self.navigation == nil { self.finish(.failure(ScannerDatabaseUpdateFailure.unavailable)) }
                    } catch {
                        guard let self, self.generation == id else { return }
                        self.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == id else { return }
                self?.cancel()
            }
        }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<ScannerDatabaseUpdateResult, Error>) {
        generation = nil; startup?.cancel(); startup = nil; timeout?.cancel(); timeout = nil
        navigation = nil
        if let view = webView {
            view.navigationDelegate = nil; view.uiDelegate = nil; view.stopLoading()
            view.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
            view.removeFromSuperview()
        }
        webView = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
    private static func allowed(_ url: URL?) -> Bool { url == LocalScannerServer.pageURL }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(generation != nil && action.targetFrame?.isMainFrame == true && Self.allowed(action.request.url) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = generation, webView === self.webView, let navigation, navigation === self.navigation,
              Self.allowed(webView.url) else { return }
        self.navigation = nil
        guard let url = Bundle.main.url(forResource: "DatabaseUpdater", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            finish(.failure(ScannerDatabaseUpdateFailure.unavailable)); return
        }
        webView.evaluateJavaScript(source) { [weak self, weak webView] _, error in
            guard let self, let webView, self.generation == id, self.webView === webView else { return }
            if let error { self.finish(.failure(error)); return }
            webView.callAsyncJavaScript("return await globalThis.CardShowDatabaseUpdater.run(config);",
                arguments: ["config": ["game": self.gameKey, "cacheToken": LocalScannerServer.shared.cacheToken]],
                in: nil, in: .page, completionHandler: { [weak self, weak webView] result in
                    guard let self, let webView, self.generation == id, self.webView === webView else { return }
                    do { self.finish(.success(try ScannerDatabaseUpdateResult.decode(result.get()))) }
                    catch { self.finish(.failure(error)) }
                })
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView, navigation === self.navigation { finish(.failure(error)) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView, navigation === self.navigation { finish(.failure(error)) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { finish(.failure(ScannerDatabaseUpdateFailure.unavailable)) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
}
