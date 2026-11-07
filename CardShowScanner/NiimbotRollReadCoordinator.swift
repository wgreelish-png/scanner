import Foundation
import Observation

enum NiimbotRollEstimateFreshness: Equatable, Sendable {
    case unknown, fresh, stale, unavailable
}

enum NiimbotRollRefreshSource: String, Equatable, Sendable {
    case cache, read
    case inFlight = "in_flight"
}

/// A roll read is a tiny command, not an image upload. Prefer the established
/// acknowledged channel; use the advertised no-response path only if needed.
enum NiimbotOptionalRollWritePolicy {
    enum Mode: Equatable, Sendable { case acknowledged, unacknowledged }
    enum FailureAction: Equatable, Sendable { case keepConnection, quarantineRead, retireConnection }

    static func select(supportsWrite: Bool, supportsWriteWithoutResponse: Bool) -> Mode? {
        if supportsWrite { return .acknowledged }
        return supportsWriteWithoutResponse ? .unacknowledged : nil
    }

    static func failureAction(mode: Mode, wasDispatched: Bool,
                              awaitingAcknowledgement: Bool) -> FailureAction {
        // CoreBluetooth's write callback has no request identifier. A pending
        // ACK cannot be abandoned while allowing another command on this link.
        if mode == .acknowledged && awaitingAcknowledgement { return .retireConnection }
        return wasDispatched ? .quarantineRead : .keepConnection
    }
}

/// NIIMBOT replies carry an opcode but no request ID. After an abandoned
/// dispatched read, only reconnecting permits another RFID request.
struct NiimbotOptionalRollReplyGuard {
    private(set) var isQuarantined = false
    private var abandonedReply = false

    mutating func abandonRead(wasSent: Bool) {
        guard wasSent else { return }
        isQuarantined = true; abandonedReply = true
    }
    mutating func markUnsupported() { isQuarantined = true }
    mutating func consumeLateResponse(_ command: UInt8) -> Bool {
        guard abandonedReply, command == 0x1b || command == 0x00 else { return false }
        abandonedReply = false
        return true
    }
}

/// A print preflight is valid only for its connection, immutable product
/// measurements and media mode. Remaining-counter freshness is independent.
struct NiimbotPrintStockSnapshot: Equatable, Sendable {
    let connection: UUID
    let product: NiimbotLabelProduct?
    let paperMode: NiimbotPaperMode

    func matches(connection: UUID, product: NiimbotLabelProduct?, paperMode: NiimbotPaperMode) -> Bool {
        self.connection == connection && self.product == product && self.paperMode == paperMode
    }
}

/// Optional roll metadata has its own lifetime; it never owns a printer
/// connection or a print operation. Only an actual read can make it fresh.
@MainActor @Observable final class NiimbotRollReadCoordinator {
    private(set) var estimate: NiimbotRollEstimate?
    private(set) var info: NiimbotRollInfo?
    private(set) var freshness = NiimbotRollEstimateFreshness.unknown
    private(set) var isReading = false
    @ObservationIgnored private var connection = UUID()
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cachedAt: TimeInterval?
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    private static let maximumCacheAge: TimeInterval = 30

    init(now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    deinit { task?.cancel() }

    func reset() {
        connection = UUID(); revision = UUID()
        task?.cancel(); task = nil; isReading = false
        cachedAt = nil
        estimate = nil; info = nil; freshness = .unknown
    }

    func markStale() {
        revision = UUID()
        cachedAt = nil
        if estimate != nil { freshness = .stale }
    }

    /// Automatic consumers may reuse one successful read for this connection.
    /// An explicit Refresh still calls refreshInfo, which always reads again.
    /// Printing, stock changes and disconnects invalidate the cache immediately;
    /// a short monotonic lifetime also prevents indefinitely reusing quiet stock.
    @discardableResult func refreshInfoIfNeeded(
        load: @escaping @MainActor () async throws -> NiimbotRollInfo?,
        onUpdate: @escaping @MainActor (NiimbotRollInfo?) -> Void = { _ in }
    ) -> NiimbotRollRefreshSource {
        guard task == nil else { return .inFlight }
        if info != nil, let cachedAt {
            let age = now() - cachedAt
            if age.isFinite, age >= 0, age < Self.maximumCacheAge { return .cache }
        }
        _ = refreshInfo(load: load, onUpdate: onUpdate)
        return .read
    }

    @discardableResult func refresh(load: @escaping @MainActor () async throws -> NiimbotRollEstimate?) -> Bool {
        refreshInfo(load: {
            guard let estimate = try await load() else { return nil }
            return NiimbotRollInfo(estimate: estimate)
        })
    }

    /// Publication is fenced by both connection and work revision. Detection
    /// callbacks cannot alter paper after a late or cancelled read completes.
    @discardableResult func refreshInfo(
        load: @escaping @MainActor () async throws -> NiimbotRollInfo?,
        onUpdate: @escaping @MainActor (NiimbotRollInfo?) -> Void = { _ in }
    ) -> Bool {
        guard task == nil else { return false }
        let requestConnection = connection, requestRevision = revision
        isReading = true
        task = Task { [weak self] in
            let result: Result<NiimbotRollInfo?, Error>
            do { result = .success(try await load()) }
            catch { result = .failure(error) }
            guard let self, self.connection == requestConnection else { return }
            defer { self.task = nil; self.isReading = false }
            guard self.revision == requestRevision, !Task.isCancelled else { return }
            switch result {
            case .success(let value):
                self.info = value
                self.cachedAt = value == nil ? nil : self.now()
                self.estimate = value?.estimate
                self.freshness = self.estimate == nil ? .unavailable : .fresh
                onUpdate(value)
            case .failure:
                self.cachedAt = nil
                self.info = nil
                self.freshness = self.estimate == nil ? .unavailable : .stale
                onUpdate(nil)
            }
        }
        return true
    }

    /// The transport bounds reads to 750 ms. Foreground print/settings work
    /// drains that one request before using the same command channel.
    func waitUntilIdle() async {
        let pending = task
        await pending?.value
    }
}
