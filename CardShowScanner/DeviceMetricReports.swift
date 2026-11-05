import Foundation
@preconcurrency import MetricKit

/// Numeric summaries of reports iOS chooses to deliver. These are counts in
/// each supplied report window, never cumulative app totals or live monitoring.
struct DeviceMetricReport: Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case crash, hang
        case cpuException = "cpu_exception"
        case diskWriteException = "disk_write_exception"
    }

    struct Window: Equatable, Sendable {
        let begin: TimeInterval
        let end: TimeInterval
    }

    // Values at this bound can represent more diagnoses in the supplied window.
    static let maximumCount = 1_000
    static let maximumWindowSeconds: TimeInterval = 604_800
    let window: Window
    let windowSeconds: Int
    private let counts: [Kind: Int]

    init?(begin: Date, end: Date, crashes: Int, hangs: Int, cpuExceptions: Int, diskWriteExceptions: Int) {
        let start = begin.timeIntervalSinceReferenceDate, finish = end.timeIntervalSinceReferenceDate
        let duration = finish - start
        guard start.isFinite, finish.isFinite, duration.isFinite,
              (0...Self.maximumWindowSeconds).contains(duration) else { return nil }
        window = Window(begin: start, end: finish)
        windowSeconds = Int(duration.rounded(.towardZero))
        counts = [.crash: crashes, .hang: hangs, .cpuException: cpuExceptions, .diskWriteException: diskWriteExceptions]
            .mapValues { min(Self.maximumCount, max(0, $0)) }
    }

    var diagnosticFields: [[String: String]] {
        Kind.allCases.compactMap { kind in
            guard let count = counts[kind], count > 0 else { return nil }
            return ["health_report_kind": kind.rawValue, "health_report_count": String(count),
                    "health_report_window_s": String(windowSeconds)]
        }
    }
}

/// Only recent windows are retained in memory; no identifiers or report bodies
/// are persisted. Replayed windows do not create duplicate local summaries.
struct DeviceMetricReportDeduplicator {
    private static let maximumWindows = 32
    private var windows: [DeviceMetricReport.Window] = []

    mutating func insert(_ window: DeviceMetricReport.Window) -> Bool {
        guard !windows.contains(window) else { return false }
        windows.append(window)
        if windows.count > Self.maximumWindows { windows.removeFirst(windows.count - Self.maximumWindows) }
        return true
    }
}

/// A new immutable subscriber belongs to each foreground/opt-in generation.
/// SDK callbacks reduce payloads before crossing to the main actor; raw reports,
/// stacks, metadata and JSON representations never enter our diagnostic queue.
private final class DeviceMetricSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private static let maximumPayloadsPerDelivery = 8
    private let generation: UUID
    private let receive: @Sendable (UUID, [DeviceMetricReport]) -> Void

    init(generation: UUID, receive: @escaping @Sendable (UUID, [DeviceMetricReport]) -> Void) {
        self.generation = generation; self.receive = receive
        super.init()
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Ordinary daily metrics are outside this aggregate diagnostic scope.
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.suffix(Self.maximumPayloadsPerDelivery).compactMap { payload in
            DeviceMetricReport(begin: payload.timeStampBegin, end: payload.timeStampEnd,
                crashes: payload.crashDiagnostics?.count ?? 0, hangs: payload.hangDiagnostics?.count ?? 0,
                cpuExceptions: payload.cpuExceptionDiagnostics?.count ?? 0,
                diskWriteExceptions: payload.diskWriteExceptionDiagnostics?.count ?? 0)
        }
        guard !reports.isEmpty else { return }
        receive(generation, reports)
    }
}

/// Subscribing does not request or manufacture reports. iOS may deliver delayed
/// reports, and delivery is not guaranteed. There is no app timer or network use.
@MainActor final class DeviceMetricReports {
    static let shared = DeviceMetricReports()
    private var subscriber: DeviceMetricSubscriber?
    private var generation = UUID()
    private var deduplicator = DeviceMetricReportDeduplicator()
    private let log = DiagnosticLog.shared

    private init() {}

    /// The app supplies foreground && diagnostics-enabled. Removing a subscriber
    /// invalidates even callbacks already queued by that subscription.
    func setEnabled(_ enabled: Bool) {
        guard enabled != (subscriber != nil) else { return }
        generation = UUID()
        if let subscriber {
            MXMetricManager.shared.remove(subscriber)
            self.subscriber = nil
        }
        guard enabled else { return }
        let subscriber = DeviceMetricSubscriber(generation: generation) { [weak self] generation, reports in
            Task { @MainActor [weak self] in
                guard let self, self.subscriber != nil, self.generation == generation, self.log.enabled else { return }
                self.record(reports)
            }
        }
        self.subscriber = subscriber
        MXMetricManager.shared.add(subscriber)
    }

    private func record(_ reports: [DeviceMetricReport]) {
        for report in reports {
            let fields = report.diagnosticFields
            guard !fields.isEmpty, deduplicator.insert(report.window) else { continue }
            for field in fields { log.record("health.os_report", field) }
        }
    }
}
