import Foundation
import Combine

struct BetaAllowlistSyncResult: Equatable, Sendable {
    enum Status: String, Sendable {
        case saved
        case capacityReached = "capacity_reached"
        case historyUnavailable = "history_unavailable"
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
    /// Detects the current phone address, replaces only its recorded previous
    /// address and preserves the account's other entries in the same save.
    func run() async throws -> BetaAllowlistSyncResult
    /// Immediately retires the page and any pending native continuation.
    func cancel()
}

/// Owns foreground-only checks. The runner keeps only per-account phone IP
/// history in device-only Keychain; website authentication never enters it.
@MainActor final class BetaIPAllowlistSync: ObservableObject {
    static let enabledKey = "betaAutomaticIPAllowlist"
    enum Configuration: Equatable, Sendable { case direct, server, missing, unavailable }

    @Published private(set) var enabled: Bool
    @Published private(set) var status = "The current public IP is checked while the app is open."
    @Published private(set) var busy = false
    @Published private(set) var needsSignIn = false
    @Published private(set) var isCoolingPaused = false
    @Published private(set) var lastIP: String?
    @Published private(set) var lastCheckedAt: Date?

    private let runner: any BetaAllowlistSyncRunning
    private let defaults: UserDefaults
    private let configuration: @MainActor () -> Configuration
    private let now: @MainActor () -> Date
    private let thermalState: @MainActor () -> ProcessInfo.ThermalState
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
    private var thermalObserver: NSObjectProtocol?
    private var authenticationMessage = "Sign in to TCGTracking to update your allowed IP automatically."

    init(runner: any BetaAllowlistSyncRunning, defaults: UserDefaults = .standard,
         configuration: @escaping @MainActor () -> Configuration,
         now: @escaping @MainActor () -> Date = { .now },
         thermalState: @escaping @MainActor () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         automaticPolling: Bool = true,
         wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.runner = runner; self.defaults = defaults; self.configuration = configuration
        self.now = now; self.thermalState = thermalState; self.automaticPolling = automaticPolling; self.wait = wait
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if !enabled { status = "Automatic IP updates are off." }
        isCoolingPaused = Self.requiresCooling(thermalState())
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.thermalStateChanged() }
        }
    }

    deinit {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
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
        guard connectionEligible else { return }
        cancelWork(); cancelDebounce()
        lastIP = nil; lastCheckedAt = nil
        policy.resetForForeground()
        guard canRun else { reconsider(); return }
        status = "Network changed. Checking the new public IP…"
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
        guard connectionEligible, !Self.requiresCooling(thermalState()) else { reconsider(); return }
        cancelDebounce()
        if needsSignIn {
            // An explicit retry is the only path besides an authentication
            // change that may retry a known sign-in failure immediately.
            needsSignIn = false
            policy = BetaAllowlistSyncPolicy()
        } else { policy.resetForForeground() }
        reconsider()
    }

    /// Optional website work pauses while the device cools. Notifications wake
    /// recovery; there is no extra timer and no paused polling loop.
    func thermalStateChanged() {
        let cooling = Self.requiresCooling(thermalState())
        guard cooling != isCoolingPaused else { return }
        isCoolingPaused = cooling
        if !cooling { policy.resetForForeground() }
        DiagnosticLog.shared.record("beta_allowlist.thermal_changed", ["reason": cooling ? "cooling" : "resumed"])
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

    private var connectionEligible: Bool { foreground && enabled && configuration() == .direct }
    private var canRun: Bool {
        connectionEligible && !needsSignIn && !Self.requiresCooling(thermalState())
    }

    private static func requiresCooling(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    private func reconsider() {
        isCoolingPaused = Self.requiresCooling(thermalState())
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
        guard !needsSignIn else {
            cancelAll(); status = authenticationMessage + " Automatic checks are paused until sign-in changes or you tap Check IP Now."
            return
        }
        guard !isCoolingPaused else {
            cancelAll(); status = "IP checks are paused while this iPhone cools. Direct API requests remain available."
            return
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
                ? "This iPhone’s IP was updated. Other allowed addresses were preserved."
                : "This iPhone’s current public IP is already allowed."
        case .capacityReached:
            policy.recordFailure(at: current)
            status = "The allowlist is full. Remove an unused address on TCGTracking before adding this iPhone; other addresses were kept."
        case .historyUnavailable:
            policy.recordFailure(at: current)
            status = "This iPhone’s saved IP history is unavailable. Unlock the phone and recheck before relying on automatic updates."
        case .signInRequired:
            policy.recordFailure(at: current)
            needsSignIn = true
            authenticationMessage = "Sign in to TCGTracking to update your allowed IP automatically."
            status = authenticationMessage + " Automatic checks are paused until sign-in changes or you tap Check IP Now."
        case .accountMismatch:
            policy.recordFailure(at: current)
            needsSignIn = true
            authenticationMessage = "Sign in to the TCGTracking account that matches your saved Beta Shipper ID. The allowlist was not changed."
            status = authenticationMessage + " Automatic checks are paused until sign-in changes or you tap Check IP Now."
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
        if needsSignIn { cancelDebounce(); cancelPolling() }
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
                guard !Task.isCancelled, self?.canRun == true, self?.pollingGeneration == id else { return }
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
