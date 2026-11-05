import Foundation
import Observation

enum NiimbotRollEstimateFreshness: Equatable, Sendable {
    case unknown, fresh, stale, unavailable
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

/// Optional roll metadata has its own lifetime; it never owns a printer
/// connection or a print operation. Only an actual read can make it fresh.
@MainActor @Observable final class NiimbotRollReadCoordinator {
    private(set) var estimate: NiimbotRollEstimate?
    private(set) var freshness = NiimbotRollEstimateFreshness.unknown
    private(set) var isReading = false
    @ObservationIgnored private var connection = UUID()
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    func reset() {
        connection = UUID(); revision = UUID()
        task?.cancel(); task = nil; isReading = false
        estimate = nil; freshness = .unknown
    }

    func markStale() {
        revision = UUID()
        if estimate != nil { freshness = .stale }
    }

    @discardableResult func refresh(load: @escaping @MainActor () async throws -> NiimbotRollEstimate?) -> Bool {
        guard task == nil else { return false }
        let requestConnection = connection, requestRevision = revision
        isReading = true
        task = Task { [weak self] in
            let result: Result<NiimbotRollEstimate?, Error>
            do { result = .success(try await load()) }
            catch { result = .failure(error) }
            guard let self, self.connection == requestConnection else { return }
            defer { self.task = nil; self.isReading = false }
            guard self.revision == requestRevision, !Task.isCancelled else { return }
            switch result {
            case .success(let value):
                self.estimate = value
                self.freshness = value == nil ? .unavailable : .fresh
            case .failure:
                self.freshness = self.estimate == nil ? .unavailable : .stale
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
