import Foundation
import Combine

struct BetaAllowlistSyncResult: Equatable, Sendable {
    enum Status: String, Sendable {
        case saved
        case alreadyCurrent = "already_current"
        case signInRequired = "sign_in_required"
        case accountMismatch = "account_mismatch"
        case pageChanged = "page_changed"
        case accessDenied = "access_denied"
        case rateLimited = "rate_limited"
        case saveFailed = "save_failed"
        case networkFailed = "network_failed"
    }
    let status: Status
    let ip: String?
    let retryAfterSeconds: TimeInterval?

    init(status: Status, ip: String? = nil, retryAfterSeconds: TimeInterval? = nil) {
        self.status = status; self.ip = ip; self.retryAfterSeconds = retryAfterSeconds
    }
}

@MainActor protocol BetaAllowlistSyncRunning: AnyObject {
    /// Detects the website's current public IP and atomically replaces its saved
    /// allowlist when needed. It must never clear the list in a separate request.
    func run() async throws -> BetaAllowlistSyncResult
    /// Immediately retires the page and any pending native continuation.
    func cancel()
}

/// Owns foreground-only checks. Neither IPs nor website authentication material
/// are persisted here; only the user's enabled preference survives relaunches.
@MainActor final class BetaIPAllowlistSync: ObservableObject {
    static let enabledKey = "betaAutomaticIPAllowlist"
    enum Configuration: Equatable, Sendable { case direct, server, missing, unavailable }

    @Published private(set) var enabled: Bool
    @Published private(set) var status = "The current public IP is checked while the app is open."
    @Published private(set) var busy = false
    @Published private(set) var needsSignIn = false
    @Published private(set) var lastIP: String?
    @Published private(set) var lastCheckedAt: Date?

    private let runner: any BetaAllowlistSyncRunning
    private let defaults: UserDefaults
    private let configuration: @MainActor () -> Configuration
    private let now: @MainActor () -> Date
    private let wait: @MainActor (Duration) async throws -> Void
    private let automaticPolling: Bool
    private var foreground = false
    private var policy = BetaAllowlistSyncPolicy()
    private var work: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var generation = UUID()
    private var debounceGeneration = UUID()
    private var pollingGeneration = UUID()

    init(runner: any BetaAllowlistSyncRunning, defaults: UserDefaults = .standard,
         configuration: @escaping @MainActor () -> Configuration,
         now: @escaping @MainActor () -> Date = { .now },
         automaticPolling: Bool = true,
         wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.runner = runner; self.defaults = defaults; self.configuration = configuration
        self.now = now; self.automaticPolling = automaticPolling; self.wait = wait
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if !enabled { status = "Automatic IP updates are off." }
    }

    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: Self.enabledKey)
        if value { policy.resetForForeground() }
        reconsider()
    }

    func setForeground(_ value: Bool) {
        let returning = value && !foreground
        foreground = value
        if returning { policy.resetForForeground() }
        reconsider()
    }

    /// NWPath changes are hints, not public IP measurements. Retire the old
    /// result immediately and let the new route settle before opening the page.
    func networkChanged() {
        guard canRun else { return }
        cancelWork(); cancelDebounce()
        lastIP = nil; lastCheckedAt = nil
        status = "Network changed. Checking the new public IP…"
        policy.resetForForeground()
        let id = UUID(); debounceGeneration = id
        let delay = wait
        debounce = Task { [weak self] in
            do { try await delay(.seconds(2)) } catch { return }
            guard let self, !Task.isCancelled, self.debounceGeneration == id else { return }
            self.debounce = nil
            self.checkIfDue()
        }
        ensurePolling()
    }

    /// Explicit checks may bypass a recent success, but not server retry delays.
    func checkNow() {
        guard work == nil else { return }
        cancelDebounce(); policy.resetForForeground()
        reconsider()
    }

    /// Called after saving/removing API credentials or returning from sign-in.
    /// A completed interactive sign-in can retry its authentication failure; it
    /// cannot erase a rate-limit cooldown from an unrelated failed request.
    func connectionChanged() {
        let wasSignInRequired = needsSignIn
        cancelWork(); cancelDebounce(); cancelPolling()
        lastIP = nil; lastCheckedAt = nil; needsSignIn = false
        if wasSignInRequired { policy = BetaAllowlistSyncPolicy() }
        else { policy.resetForForeground() }
        reconsider()
    }

    /// Await a foreground synchronization already in flight before a Direct
    /// Beta lookup. Website failure does not suppress the user's API request.
    func prepareForDirectRequest() async {
        guard canRun, !Task.isCancelled else { return }
        if let debounce { await debounce.value }
        guard canRun, !Task.isCancelled else { return }
        checkIfDue()
        if let work { await work.value }
    }

    private var canRun: Bool { foreground && enabled && configuration() == .direct }

    private func reconsider() {
        guard enabled else {
            cancelAll(); status = "Automatic IP updates are off."; return
        }
        guard foreground else {
            cancelAll(); status = "IP checks pause whenever the app is not active."; return
        }
        switch configuration() {
        case .server:
            cancelAll(); status = "My Server uses its own allowlisted IP. The phone’s allowlist is not changed."; return
        case .missing:
            cancelAll(); status = "Save your Direct TCGTracking API connection to enable automatic IP updates."; return
        case .unavailable:
            cancelAll(); status = "API connection settings could not be read. Unlock this iPhone and retry."; return
        case .direct: break
        }
        checkIfDue(); ensurePolling()
    }

    private func checkIfDue() {
        guard canRun, work == nil, debounce == nil,
              policy.isDue(at: now(), isActive: foreground, enabled: enabled) else { return }
        let id = UUID(); generation = id
        busy = true; status = "Checking this phone’s public IP…"
        DiagnosticLog.shared.record("beta_allowlist.check_started")
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == id { self.work = nil; self.busy = false }
            }
            do {
                let result = try await self.runner.run()
                try Task.checkCancellation()
                guard self.generation == id, self.canRun else { return }
                self.accept(result)
            } catch {
                guard !Task.isCancelled, self.generation == id, self.canRun else { return }
                self.accept(.init(status: .networkFailed))
            }
        }
    }

    private func accept(_ result: BetaAllowlistSyncResult) {
        let current = now()
        needsSignIn = false
        switch result.status {
        case .saved, .alreadyCurrent:
            guard let ip = result.ip, let canonical = BetaAllowlistAddress.canonical(ip) else {
                accept(.init(status: .saveFailed)); return
            }
            policy.recordSuccess(at: current)
            lastIP = canonical; lastCheckedAt = current
            status = result.status == .saved
                ? "The allowlist now contains only this phone’s current public IP."
                : "This phone’s current public IP is already the only allowed address."
        case .signInRequired:
            policy.recordFailure(at: current)
            needsSignIn = true
            status = "Sign in to TCGTracking to update your allowed IP automatically."
        case .accountMismatch:
            policy.recordFailure(at: current)
            needsSignIn = true
            status = "Sign in to the TCGTracking account that matches your saved Beta Shipper ID. The allowlist was not changed."
        case .pageChanged:
            policy.recordFailure(at: current)
            status = "The website’s IP settings could not be verified. IP access is unconfirmed."
        case .accessDenied:
            policy.recordFailure(at: current, retryAfterSeconds: result.retryAfterSeconds)
            status = "TCGTracking denied the IP update. Check your website account and Beta access."
        case .rateLimited:
            policy.recordFailure(at: current, retryAfterSeconds: result.retryAfterSeconds)
            status = "TCGTracking requested a pause. IP updates will retry after its waiting period while the app is open."
        case .saveFailed:
            policy.recordFailure(at: current, retryAfterSeconds: result.retryAfterSeconds)
            status = "The IP update was not confirmed. Recheck before relying on Direct Beta access."
        case .networkFailed:
            policy.recordFailure(at: current, retryAfterSeconds: result.retryAfterSeconds)
            status = "The IP check could not finish. It will retry while the app is open."
        }
        DiagnosticLog.shared.record("beta_allowlist.check_finished", ["reason": result.status.rawValue])
    }

    private func ensurePolling() {
        guard automaticPolling, canRun, polling == nil else { return }
        let id = UUID(); pollingGeneration = id
        let delay = wait
        polling = Task { [weak self] in
            while !Task.isCancelled {
                // Start the next minute after completion rather than racing an
                // in-flight check at the edge of its minimum interval.
                if let work = self?.work { await work.value }
                do { try await delay(.seconds(BetaAllowlistSyncPolicy.checkInterval)) } catch { return }
                guard let self, !Task.isCancelled, self.canRun, self.pollingGeneration == id else { return }
                self.checkIfDue()
            }
        }
    }

    private func cancelWork() {
        generation = UUID()
        let wasWorking = work != nil
        work?.cancel(); work = nil; busy = false
        if wasWorking { runner.cancel() }
    }
    private func cancelDebounce() {
        debounceGeneration = UUID(); debounce?.cancel(); debounce = nil
    }
    private func cancelPolling() {
        pollingGeneration = UUID(); polling?.cancel(); polling = nil
    }
    private func cancelAll() { cancelWork(); cancelDebounce(); cancelPolling() }
}
