import Foundation
import CryptoKit

enum BetaAPIFamily: String, Sendable { case opportunities, research }

enum BetaAPICadenceFailure: Error, Equatable, Sendable {
    case invalidRequest, invalidResponse, responseTooLarge, networkUnavailable, httpStatus(Int)
}

struct BetaAPISetInfo: Equatable, Sendable {
    /// The index's data hash; it must never be sent as HTTP If-None-Match.
    let dataETag: String?
    let checkedAt: Date
}

/// One authenticated request budget for both Beta API families. Data caches are
/// credential-specific; the rate budget is shipper-specific, including rotations.
actor BetaAPICadence {
    static let shared = BetaAPICadence(disk: .shared)
    static let indexLifetime: TimeInterval = 24 * 60 * 60
    private let now: @Sendable () -> Date
    private let wait: @Sendable (TimeInterval) async throws -> Void
    private let disk: BetaAPIDiskCache?

    init(now: @escaping @Sendable () -> Date = { Date() },
         wait: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         disk: BetaAPIDiskCache? = nil) {
        self.now = now; self.wait = wait; self.disk = disk
    }

    nonisolated static func account(for credentials: DirectResearchCredentials) -> String {
        digest("https://beta.tcgtracking.com\0" + credentials.shipperID + "\0" + credentials.apiKey)
    }
    private nonisolated static func budgetAccount(for credentials: DirectResearchCredentials) -> String {
        digest("https://beta.tcgtracking.com\0" + credentials.shipperID)
    }
    private nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Budget {
        var window: Date
        var sent = 0
        var limit = 120
        var remaining: Int?
        var resetAt: Date?
        var cooldownUntil: Date?
    }
    private var budgets: [String: Budget] = [:]

    /// Every sent request consumes a slot, including metadata, HEAD, failures
    /// and 304. Cancellation after sending never returns that slot.
    func send(_ request: URLRequest, credentials: DirectResearchCredentials,
              loader: any ResearchHTTPDataLoading) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let checked: DirectResearchCredentials
        do { checked = try .validated(shipperID: credentials.shipperID, apiKey: credentials.apiKey) }
        catch { throw BetaAPICadenceFailure.invalidRequest }
        guard Self.allows(request) else { throw BetaAPICadenceFailure.invalidRequest }
        let account = Self.budgetAccount(for: checked)
        try await reserve(account: account)
        try Task.checkCancellation()
        var request = request
        request.setValue(checked.shipperID, forHTTPHeaderField: "X-Shipper-Id")
        request.setValue(checked.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        let phase: ServiceDiagnosticFields.Phase = request.url?.path == "/v1/meta" ? .opportunitiesMeta
            : (request.url?.path == "/v1/research/meta" ? .researchMeta
                : (request.url?.path.hasSuffix("/research") == true ? .researchProduct : .opportunitiesProduct))
        let started = Date()
        await ServiceDiagnosticFields.record("beta.http_started", method: .direct, phase: phase)
        try Task.checkCancellation()
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch {
            try Task.checkCancellation()
            await ServiceDiagnosticFields.record("beta.http_failed", method: .direct, phase: phase, started: started, error: error)
            if let error = error as? BetaAPICadenceFailure { throw error }
            if error as? ResearchFailure == .responseTooLarge { throw BetaAPICadenceFailure.responseTooLarge }
            if error as? ResearchFailure == .invalidResponse { throw BetaAPICadenceFailure.invalidResponse }
            throw BetaAPICadenceFailure.networkUnavailable
        }
        guard response.url == request.url else { throw BetaAPICadenceFailure.invalidResponse }
        observe(response, account: account, at: now())
        await ServiceDiagnosticFields.record("beta.http_response", method: .direct, phase: phase,
            status: response.statusCode, started: started)
        try Task.checkCancellation()
        guard data.count <= 8 * 1_024 * 1_024 else { throw BetaAPICadenceFailure.responseTooLarge }
        return (data, response)
    }

    private nonisolated static func allows(_ request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme == "https", url.host == "beta.tcgtracking.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, ["GET", "HEAD"].contains(request.httpMethod ?? "GET") else { return false }
        return url.path.range(of: #"^/v1/(?:meta|research/meta|[123]/sets/[1-9][0-9]*(?:/research)?)$"#,
                              options: .regularExpression) != nil
    }

    private func reserve(account: String) async throws {
        while true {
            try Task.checkCancellation()
            let current = now()
            let window = Date(timeIntervalSince1970: floor(current.timeIntervalSince1970 / 60) * 60)
            if budgets[account] == nil, budgets.count >= 256 {
                budgets = budgets.filter { _, state in
                    state.window.addingTimeInterval(120) > current || (state.cooldownUntil ?? .distantPast) > current || (state.resetAt ?? .distantPast) > current
                }
                guard budgets.count < 256 else { throw BetaAPICadenceFailure.networkUnavailable }
            }
            var state = budgets[account] ?? Budget(window: window)
            if current < state.window || current >= state.window.addingTimeInterval(60) { state.window = window; state.sent = 0 }
            if let reset = state.resetAt, current >= reset { state.remaining = nil; state.resetAt = nil }
            var deadline = max(current, state.cooldownUntil ?? current)
            if state.sent >= state.limit { deadline = max(deadline, state.window.addingTimeInterval(60)) }
            if state.remaining == 0 { deadline = max(deadline, state.resetAt ?? state.window.addingTimeInterval(60)) }
            if deadline > current {
                budgets[account] = state
                try await wait(deadline.timeIntervalSince(current))
                try Task.checkCancellation()
                // An injected clock must advance when its waiter returns. This
                // guard also prevents a broken clock from causing a busy loop.
                guard now() > current else { throw BetaAPICadenceFailure.networkUnavailable }
                continue
            }
            state.sent += 1
            if let remaining = state.remaining { state.remaining = max(0, remaining - 1) }
            budgets[account] = state
            return
        }
    }

    private func observe(_ response: HTTPURLResponse, account: String, at current: Date) {
        guard var state = budgets[account] else { return }
        if let value = Self.integerHeader(response, "X-RateLimit-Limit"), value > 0 { state.limit = min(120, value) }
        if let remaining = Self.integerHeader(response, "X-RateLimit-Remaining") {
            state.remaining = min(state.remaining ?? 120, min(120, remaining))
            if let seconds = Self.integerHeader(response, "X-RateLimit-Reset") {
                state.resetAt = max(state.resetAt ?? .distantPast, current.addingTimeInterval(TimeInterval(min(86_400, max(1, seconds)))))
            } else if state.resetAt == nil { state.resetAt = state.window.addingTimeInterval(60) }
        }
        if response.statusCode == 429 || (response.statusCode == 503 && response.value(forHTTPHeaderField: "Retry-After") != nil) {
            let deadline = current.addingTimeInterval(Self.retryDelay(response, now: current))
            state.cooldownUntil = max(state.cooldownUntil ?? .distantPast, deadline)
        }
        budgets[account] = state
    }

    private nonisolated static func integerHeader(_ response: HTTPURLResponse, _ name: String) -> Int? {
        guard let text = response.value(forHTTPHeaderField: name), text.utf8.count <= 10,
              text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(text) else { return nil }
        return value
    }
    private nonisolated static func retryDelay(_ response: HTTPURLResponse, now: Date) -> TimeInterval {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"), value.count <= 128 else { return 60 }
        if let number = Double(value), number.isFinite, number >= 0 { return min(86_400, max(1, number)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { min(86_400, max(1, $0.timeIntervalSince(now))) } ?? 60
    }

    private struct SetIndex: Sendable { let dataETag: String? }
    private struct IndexEntry: Sendable {
        let data: Data
        let httpETag: String?
        let checkedAt: Date
        let sets: [String: SetIndex]
    }
    private struct Pending {
        let generation: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<IndexEntry, Error>]
    }
    private var indices: [String: IndexEntry] = [:]
    private var pending: [String: Pending] = [:]
    private var epoch = UUID()

    func setInfo(family: BetaAPIFamily, category: Int, group: Int, forceRefresh: Bool = false,
                 credentials: DirectResearchCredentials, loader: any ResearchHTTPDataLoading) async throws -> BetaAPISetInfo {
        try Task.checkCancellation()
        guard (1...3).contains(category), group > 0 else { throw BetaAPICadenceFailure.invalidRequest }
        let key = Self.account(for: credentials) + ":" + family.rawValue
        let currentEpoch = epoch
        if indices[key] == nil, let saved = await disk?.entry(for: key, kind: .index),
           let decoded = try? Self.decodeIndex(saved.data, httpETag: saved.httpETag, checkedAt: saved.checkedAt) {
            guard epoch == currentEpoch else { throw CancellationError() }
            if indices[key] == nil { indices[key] = decoded; trimIndices(keeping: key) }
        }
        try Task.checkCancellation()
        guard epoch == currentEpoch else { throw CancellationError() }
        let entry: IndexEntry
        if !forceRefresh, let cached = indices[key], now() >= cached.checkedAt,
           now().timeIntervalSince(cached.checkedAt) < Self.indexLifetime { entry = cached }
        else {
            let waiter = UUID()
            entry = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    if pending[key] != nil { pending[key]?.waiters[waiter] = continuation }
                    else {
                        let generation = UUID()
                        pending[key] = Pending(generation: generation, task: nil, waiters: [waiter: continuation])
                        pending[key]?.task = Task { await self.fetchIndex(key: key, generation: generation, family: family,
                                                                       credentials: credentials, loader: loader) }
                    }
                }
            } onCancel: { Task { await self.cancel(waiter: waiter, key: key) } }
        }
        try Task.checkCancellation()
        guard let set = entry.sets["\(category):\(group)"] else { throw BetaAPICadenceFailure.httpStatus(404) }
        return BetaAPISetInfo(dataETag: set.dataETag, checkedAt: entry.checkedAt)
    }

    private func fetchIndex(key: String, generation: UUID, family: BetaAPIFamily,
                            credentials: DirectResearchCredentials, loader: any ResearchHTTPDataLoading) async {
        do {
            let old = indices[key]
            let path = family == .opportunities ? "/v1/meta" : "/v1/research/meta"
            var request = URLRequest(url: URL(string: "https://beta.tcgtracking.com" + path)!,
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let etag = old?.httpETag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            let (data, response) = try await send(request, credentials: credentials, loader: loader)
            let result: IndexEntry
            switch response.statusCode {
            case 200: result = try Self.decodeIndex(data, httpETag: Self.safeETag(response.value(forHTTPHeaderField: "ETag")), checkedAt: now())
            case 304:
                guard let old else { throw BetaAPICadenceFailure.invalidResponse }
                result = IndexEntry(data: old.data, httpETag: Self.safeETag(response.value(forHTTPHeaderField: "ETag")) ?? old.httpETag,
                                    checkedAt: now(), sets: old.sets)
            default: throw BetaAPICadenceFailure.httpStatus(response.statusCode)
            }
            try Task.checkCancellation()
            guard pending[key]?.generation == generation else { return }
            await disk?.store(.init(data: result.data, httpETag: result.httpETag, dataETag: nil, checkedAt: result.checkedAt), for: key, kind: .index)
            try Task.checkCancellation()
            guard let request = pending[key], request.generation == generation else { return }
            indices[key] = result
            trimIndices(keeping: key)
            pending[key] = nil
            for continuation in request.waiters.values { continuation.resume(returning: result) }
        } catch {
            guard let request = pending[key], request.generation == generation else { return }
            pending[key] = nil
            let failure: Error = Task.isCancelled ? CancellationError() : error
            for continuation in request.waiters.values { continuation.resume(throwing: failure) }
        }
    }

    private func cancel(waiter: UUID, key: String) {
        let continuation = pending[key]?.waiters.removeValue(forKey: waiter)
        continuation?.resume(throwing: CancellationError())
        if pending[key]?.waiters.isEmpty == true { pending[key]?.task?.cancel(); pending[key] = nil }
    }

    private func trimIndices(keeping key: String) {
        while indices.count > 8, let oldest = indices.filter({ $0.key != key }).min(by: { $0.value.checkedAt < $1.value.checkedAt })?.key { indices[oldest] = nil }
    }

    private nonisolated static func safeETag(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.utf8.count <= 512,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
    private nonisolated static func decodeIndex(_ data: Data, httpETag: String?, checkedAt: Date) throws -> IndexEntry {
        guard data.count <= 8 * 1_024 * 1_024,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              body["error"] == nil, (body["success"] as? Bool) != false,
              let categories = body["categories"] as? [String: Any], categories.count <= 32 else { throw BetaAPICadenceFailure.invalidResponse }
        var sets: [String: SetIndex] = [:]
        for (category, value) in categories {
            guard let number = Int(category), number > 0, String(number) == category,
                  let value = value as? [String: Any], let groups = value["sets"] as? [String: Any], groups.count <= 50_000 else { throw BetaAPICadenceFailure.invalidResponse }
            for (group, value) in groups {
                guard let number = Int(group), number > 0, String(number) == group,
                      let value = value as? [String: Any] else { throw BetaAPICadenceFailure.invalidResponse }
                let hash: String?
                if value["etag"] == nil || value["etag"] is NSNull { hash = nil }
                else { guard let text = value["etag"] as? String, let checked = safeETag(text) else { throw BetaAPICadenceFailure.invalidResponse }; hash = checked }
                sets[category + ":" + group] = SetIndex(dataETag: hash)
            }
        }
        return IndexEntry(data: data, httpETag: httpETag, checkedAt: checkedAt, sets: sets)
    }

    /// Clearing saved data intentionally preserves the shipper's request budget.
    func clear() async {
        epoch = UUID()
        indices.removeAll()
        for request in pending.values {
            request.task?.cancel()
            for continuation in request.waiters.values { continuation.resume(throwing: CancellationError()) }
        }
        pending.removeAll()
        await disk?.clear()
    }
}
