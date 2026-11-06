import Foundation
import Observation
import CoreFoundation

enum NiimbotImageTransportMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case acknowledged
    case pacedWithoutResponse = "paced_without_response"

    var id: Self { self }
    var title: String {
        switch self {
        case .acknowledged: return "Acknowledged (default)"
        case .pacedWithoutResponse: return "Paced without response (experimental)"
        }
    }
}

/// A value captured once per print job. These limits are experimental, not a
/// claim about the printer's UART buffer or physical completion.
struct NiimbotImageTransportConfiguration: Equatable, Sendable {
    static let maximumPendingPacketBytes = 262 // 255-byte payload + seven framing bytes.
    let mode: NiimbotImageTransportMode
    let pacingMilliseconds: Int
    let burstWriteLimit: Int
    let burstByteLimit: Int

    init(mode: NiimbotImageTransportMode = .acknowledged,
         pacingMilliseconds: Int = 10, burstWriteLimit: Int = 1, burstByteLimit: Int = 64) {
        self.mode = mode
        self.pacingMilliseconds = min(1_000, max(10, pacingMilliseconds))
        self.burstWriteLimit = min(4, max(1, burstWriteLimit))
        self.burstByteLimit = min(256, max(20, burstByteLimit))
    }
}

/// Only the experiment's own keys are persisted. Reading preferences does not
/// opt in or change existing printer, paper, inventory or price settings.
@MainActor @Observable final class NiimbotImageTransportPreferences {
    static let shared: NiimbotImageTransportPreferences = {
        let arguments = ProcessInfo.processInfo.arguments
        let token = arguments.first(where: { $0.hasPrefix("--show-transactions-fixture-id=") })
            .map { String($0.dropFirst("--show-transactions-fixture-id=".count)) }
        let fixture = arguments.contains("--show-transactions-ui-fixture")
            ? token.flatMap { UUID(uuidString: $0)?.uuidString } : nil
        let prefix = "niimbotImageTransportExperiment" + (fixture.map { ".fixture." + $0 } ?? "")
        return NiimbotImageTransportPreferences(defaults: .standard, keyPrefix: prefix)
    }()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyPrefix: String
    private var configuration: NiimbotImageTransportConfiguration

    init(defaults: UserDefaults = .standard, keyPrefix: String = "niimbotImageTransportExperiment") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        let mode = defaults.string(forKey: keyPrefix + ".mode")
            .flatMap(NiimbotImageTransportMode.init(rawValue:)) ?? .acknowledged
        configuration = NiimbotImageTransportConfiguration(mode: mode,
            pacingMilliseconds: Self.readInteger(defaults, key: keyPrefix + ".pacingMilliseconds", fallback: 10),
            burstWriteLimit: Self.readInteger(defaults, key: keyPrefix + ".burstWriteLimit", fallback: 1),
            burstByteLimit: Self.readInteger(defaults, key: keyPrefix + ".burstByteLimit", fallback: 64))
    }

    var snapshot: NiimbotImageTransportConfiguration { configuration }
    var mode: NiimbotImageTransportMode {
        get { configuration.mode }
        set { update(mode: newValue) }
    }
    var pacingMilliseconds: Int {
        get { configuration.pacingMilliseconds }
        set { update(pacingMilliseconds: newValue) }
    }
    var burstWriteLimit: Int {
        get { configuration.burstWriteLimit }
        set { update(burstWriteLimit: newValue) }
    }
    var burstByteLimit: Int {
        get { configuration.burstByteLimit }
        set { update(burstByteLimit: newValue) }
    }

    func reset() {
        configuration = NiimbotImageTransportConfiguration()
        for field in ["mode", "pacingMilliseconds", "burstWriteLimit", "burstByteLimit"] {
            defaults.removeObject(forKey: keyPrefix + "." + field)
        }
    }

    private static func readInteger(_ defaults: UserDefaults, key: String, fallback: Int) -> Int {
        guard let value = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              let integer = Int(value.stringValue), String(integer) == value.stringValue else { return fallback }
        return integer
    }

    private func update(mode: NiimbotImageTransportMode? = nil, pacingMilliseconds: Int? = nil,
                        burstWriteLimit: Int? = nil, burstByteLimit: Int? = nil) {
        let next = NiimbotImageTransportConfiguration(mode: mode ?? configuration.mode,
            pacingMilliseconds: pacingMilliseconds ?? configuration.pacingMilliseconds,
            burstWriteLimit: burstWriteLimit ?? configuration.burstWriteLimit,
            burstByteLimit: burstByteLimit ?? configuration.burstByteLimit)
        guard next != configuration else { return }
        configuration = next
        defaults.set(next.mode.rawValue, forKey: keyPrefix + ".mode")
        defaults.set(next.pacingMilliseconds, forKey: keyPrefix + ".pacingMilliseconds")
        defaults.set(next.burstWriteLimit, forKey: keyPrefix + ".burstWriteLimit")
        defaults.set(next.burstByteLimit, forKey: keyPrefix + ".burstByteLimit")
    }
}

/// The driver retains one bounded NIIMBOT frame and its offset. This gate owns
/// only the job-wide burst budget; it never copies, truncates or reorders data.
/// CoreBluetooth readiness is a separate condition from this pacing deadline.
struct NiimbotImageWriteGate {
    struct Decision: Equatable {
        let allowedBytes: Int
        let waitingForReadiness: Bool
        let resumeAt: ContinuousClock.Instant?
    }

    let configuration: NiimbotImageTransportConfiguration
    private var writesInBurst = 0
    private var bytesInBurst = 0
    private var lastSubmission: ContinuousClock.Instant?

    init(configuration: NiimbotImageTransportConfiguration) { self.configuration = configuration }

    mutating func decision(remainingBytes: Int, maximumWriteLength: Int, isReady: Bool,
                           at now: ContinuousClock.Instant) -> Decision {
        // The driver treats an unavailable negotiated write size as an error.
        // No timer or readiness loop should spin on an invalid/empty request.
        guard remainingBytes > 0, maximumWriteLength > 0 else {
            return Decision(allowedBytes: 0, waitingForReadiness: false, resumeAt: nil)
        }
        var resumeAt: ContinuousClock.Instant?
        if let lastSubmission {
            let deadline = lastSubmission.advanced(by: .milliseconds(configuration.pacingMilliseconds))
            if now >= deadline {
                writesInBurst = 0
                bytesInBurst = 0
            } else if now < lastSubmission || writesInBurst >= configuration.burstWriteLimit
                        || bytesInBurst >= configuration.burstByteLimit {
                resumeAt = deadline
            }
        }
        let allowed = resumeAt == nil && isReady
            ? min(remainingBytes, min(maximumWriteLength, configuration.burstByteLimit - bytesInBurst)) : 0
        return Decision(allowedBytes: max(0, allowed), waitingForReadiness: !isReady, resumeAt: resumeAt)
    }

    /// Records a chunk handed to CoreBluetooth in the same actor turn. No
    /// budget is consumed while either readiness or pacing prevents a write.
    mutating func recordSubmission(byteCount: Int, at now: ContinuousClock.Instant) {
        guard byteCount > 0 else { return }
        writesInBurst = min(configuration.burstWriteLimit, writesInBurst + 1)
        bytesInBurst = min(configuration.burstByteLimit,
            bytesInBurst + min(byteCount, configuration.burstByteLimit))
        lastSubmission = lastSubmission.map { max($0, now) } ?? now
    }

    mutating func reset() {
        writesInBurst = 0
        bytesInBurst = 0
        lastSubmission = nil
    }
}

/// One cancelable pacing wake for the current transfer. The callback is only a
/// wake hint: the driver must recheck readiness, pacing and connection/job IDs.
@MainActor final class NiimbotImagePacingWake {
    typealias Sleep = @MainActor (ContinuousClock.Instant) async throws -> Void
    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private var token: UUID?
    private var transferID: UUID?
    private(set) var scheduledDeadline: ContinuousClock.Instant?

    init(sleep: @escaping Sleep = { try await ContinuousClock().sleep(until: $0) }) { self.sleep = sleep }
    deinit { task?.cancel() }

    func schedule(transferID: UUID, deadline: ContinuousClock.Instant,
                  onWake: @escaping @MainActor () -> Void) {
        if self.transferID == transferID, let existing = scheduledDeadline, existing <= deadline { return }
        cancel()
        let current = UUID()
        token = current
        self.transferID = transferID
        scheduledDeadline = deadline
        let sleep = self.sleep
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do { try await sleep(deadline) }
            catch {
                guard let self, self.token == current else { return }
                self.clear()
                return
            }
            guard !Task.isCancelled, let self, self.token == current else { return }
            self.clear()
            onWake()
        }
    }

    func cancel() {
        task?.cancel()
        clear()
    }

    private func clear() {
        task = nil
        token = nil
        transferID = nil
        scheduledDeadline = nil
    }
}
