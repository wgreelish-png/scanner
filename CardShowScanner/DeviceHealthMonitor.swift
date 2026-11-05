import Foundation
import UIKit
import Darwin

enum DeviceThermalLevel: String, Equatable, Sendable {
    case nominal, fair, serious, critical, unknown

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

/// Resource protection can read this independently of diagnostic recording.
struct DeviceResourceState: Equatable, Sendable {
    let thermal: DeviceThermalLevel
    let lowPowerMode: Bool

    static func current() -> Self {
        Self(thermal: DeviceThermalLevel(ProcessInfo.processInfo.thermalState),
             lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    var diagnosticFields: [String: String] {
        ["thermal_level": thermal.rawValue, "low_power_mode": String(lowPowerMode)]
    }
}

enum DeviceBatteryState: String, Sendable { case unknown, unplugged, charging, full }

struct DeviceBatterySample: Sendable {
    let level: Float
    let state: DeviceBatteryState
    var percentage: Int? {
        guard level.isFinite, (0...1).contains(level) else { return nil }
        return Int((level * 100).rounded())
    }
}

@MainActor protocol DeviceBatteryMonitoring: AnyObject {
    var isMonitoringEnabled: Bool { get set }
    func sample() -> DeviceBatterySample
}

@MainActor private final class NativeDeviceBattery: DeviceBatteryMonitoring {
    var isMonitoringEnabled: Bool {
        get { UIDevice.current.isBatteryMonitoringEnabled }
        set { UIDevice.current.isBatteryMonitoringEnabled = newValue }
    }
    func sample() -> DeviceBatterySample {
        let state: DeviceBatteryState
        switch UIDevice.current.batteryState {
        case .unknown: state = .unknown
        case .unplugged: state = .unplugged
        case .charging: state = .charging
        case .full: state = .full
        @unknown default: state = .unknown
        }
        return DeviceBatterySample(level: UIDevice.current.batteryLevel, state: state)
    }
}

/// Only this native app process is measured. WebKit runs in separate processes
/// and is excluded. CPU is cumulative process CPU time, never device power draw.
struct DeviceProcessSample: Sendable {
    let footprintBytes: UInt64?
    let cpuSeconds: TimeInterval?

    static func current() -> Self {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var usage = rusage()
        let cpu: TimeInterval?
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        } else { cpu = nil }
        return Self(footprintBytes: status == KERN_SUCCESS ? info.phys_footprint : nil, cpuSeconds: cpu)
    }
}

/// One bounded aggregate; the heartbeat never writes a diagnostic event.
struct DeviceResponsivenessWindow {
    static let heartbeatInterval: TimeInterval = 2
    static let delayThreshold: TimeInterval = 0.250
    private var expectedAt: TimeInterval?
    private(set) var delayedCount = 0
    private(set) var maximumDelayMilliseconds = 0

    mutating func reset(at uptime: TimeInterval? = nil) {
        expectedAt = uptime.flatMap { $0.isFinite && $0 >= 0 ? $0 + Self.heartbeatInterval : nil }
        delayedCount = 0; maximumDelayMilliseconds = 0
    }

    mutating func heartbeat(at uptime: TimeInterval) {
        guard uptime.isFinite, uptime >= 0 else { reset(); return }
        defer { expectedAt = uptime + Self.heartbeatInterval }
        guard let expectedAt else { return }
        let delay = uptime - expectedAt
        guard delay >= Self.delayThreshold else { return }
        delayedCount = min(10_000, delayedCount + 1)
        maximumDelayMilliseconds = max(maximumDelayMilliseconds, Int(min(60_000, delay * 1_000).rounded()))
    }

    mutating func takeFields() -> [String: String] {
        let fields = ["ui_lag_count": String(delayedCount), "ui_lag_max_ms": String(maximumDelayMilliseconds)]
        delayedCount = 0; maximumDelayMilliseconds = 0
        return fields
    }
}

/// Foreground-only telemetry: one aggregate every 30 seconds, a cheap two-second
/// heartbeat, and native resource notifications. No frame callbacks or backlog.
@MainActor final class DeviceHealthMonitor {
    static let shared = DeviceHealthMonitor()
    static let sampleInterval: TimeInterval = 30
    private(set) var isRunning = false
    private var foreground = false
    private let log: DiagnosticLog
    private let center: NotificationCenter
    private let battery: any DeviceBatteryMonitoring
    private let resources: @MainActor () -> DeviceResourceState
    private let process: @MainActor () -> DeviceProcessSample
    private let uptime: @MainActor () -> TimeInterval
    private let wait: @Sendable (Duration) async throws -> Void
    private let automaticallySchedules: Bool
    private var preferenceObserver: NSObjectProtocol?
    private var resourceObservers: [NSObjectProtocol] = []
    private var sampleTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var generation = UUID()
    private var priorBatteryMonitoring: Bool?
    private var previousResources: DeviceResourceState?
    private var previousProcess: (uptime: TimeInterval, cpu: TimeInterval?)?
    private var responsiveness = DeviceResponsivenessWindow()
    private var memoryWarningCount = 0

    init(log: DiagnosticLog? = nil, center: NotificationCenter = .default,
         battery: (any DeviceBatteryMonitoring)? = nil,
         resources: @escaping @MainActor () -> DeviceResourceState = { .current() },
         process: @escaping @MainActor () -> DeviceProcessSample = { .current() },
         uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticallySchedules: Bool = true,
         wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.log = log ?? .shared; self.center = center; self.battery = battery ?? NativeDeviceBattery()
        self.resources = resources; self.process = process; self.uptime = uptime
        self.automaticallySchedules = automaticallySchedules; self.wait = wait
    }

    deinit {
        sampleTask?.cancel(); heartbeatTask?.cancel()
        if let preferenceObserver { center.removeObserver(preferenceObserver) }
        for observer in resourceObservers { center.removeObserver(observer) }
        if let restore = priorBatteryMonitoring {
            let source = battery
            Task { @MainActor in source.isMonitoringEnabled = restore }
        }
    }

    /// Pass false for inactive as well as background scenes. A fresh monotonic
    /// baseline on every restart excludes suspension and Control Center dwell.
    func setForeground(_ active: Bool) {
        foreground = active
        if active, preferenceObserver == nil {
            preferenceObserver = center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshDiagnosticsPreference() }
            }
        } else if !active, let preferenceObserver {
            center.removeObserver(preferenceObserver); self.preferenceObserver = nil
        }
        refreshDiagnosticsPreference()
    }

    func refreshDiagnosticsPreference() {
        if foreground && log.enabled {
            if !isRunning { start() }
        } else { stop() }
    }

    private func start() {
        generation = UUID(); isRunning = true
        priorBatteryMonitoring = battery.isMonitoringEnabled
        battery.isMonitoringEnabled = true
        responsiveness.reset(at: uptime())
        previousProcess = nil; memoryWarningCount = 0
        previousResources = resources()
        let id = generation
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange,
                     UIApplication.didReceiveMemoryWarningNotification] {
            resourceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    self.resourceChanged(name)
                }
            })
        }
        sampleNow()
        guard automaticallySchedules else { return }
        let wait = wait
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await wait(.seconds(DeviceResponsivenessWindow.heartbeatInterval)) } catch { return }
                guard let self, self.isRunning, self.generation == id, !Task.isCancelled else { return }
                self.heartbeatNow()
            }
        }
        sampleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await wait(.seconds(Self.sampleInterval)) } catch { return }
                guard let self, self.isRunning, self.generation == id, !Task.isCancelled else { return }
                self.sampleNow()
            }
        }
    }

    private func stop() {
        generation = UUID(); isRunning = false
        sampleTask?.cancel(); sampleTask = nil; heartbeatTask?.cancel(); heartbeatTask = nil
        for observer in resourceObservers { center.removeObserver(observer) }
        resourceObservers.removeAll()
        if let priorBatteryMonitoring { battery.isMonitoringEnabled = priorBatteryMonitoring }
        priorBatteryMonitoring = nil; previousResources = nil; previousProcess = nil
        responsiveness.reset(); memoryWarningCount = 0
    }

    func heartbeatNow() {
        guard isRunning, foreground, log.enabled else { refreshDiagnosticsPreference(); return }
        responsiveness.heartbeat(at: uptime())
    }

    func sampleNow() {
        guard isRunning, foreground, log.enabled else { refreshDiagnosticsPreference(); return }
        let current = uptime(), resource = resources(), sample = process(), batterySample = battery.sample()
        var fields = resource.diagnosticFields
        fields["process_scope"] = "native_app"
        if let bytes = sample.footprintBytes { fields["native_memory_mb"] = String(bytes / 1_048_576) }
        if let previousProcess, current.isFinite, current > previousProcess.uptime {
            let elapsed = (current - previousProcess.uptime) * 1_000
            if elapsed <= 3_600_000 {
                fields["sample_window_ms"] = String(Int(elapsed.rounded()))
                if let cpu = sample.cpuSeconds, let previous = previousProcess.cpu,
                   cpu.isFinite, previous.isFinite, cpu >= previous, (cpu - previous) * 1_000 <= 3_600_000 {
                    fields["native_cpu_ms"] = String(Int(((cpu - previous) * 1_000).rounded()))
                }
            }
        }
        previousProcess = current.isFinite && current >= 0 ? (current, sample.cpuSeconds) : nil
        fields["battery_state"] = batterySample.state.rawValue
        if let percentage = batterySample.percentage { fields["battery_percent"] = String(percentage) }
        fields.merge(responsiveness.takeFields()) { _, value in value }
        fields["memory_warning_count"] = String(memoryWarningCount); memoryWarningCount = 0
        log.record("health.sample", fields)
    }

    private func resourceChanged(_ name: Notification.Name) {
        guard isRunning, foreground, log.enabled else { refreshDiagnosticsPreference(); return }
        let resource = resources()
        if name == UIApplication.didReceiveMemoryWarningNotification {
            memoryWarningCount = min(10_000, memoryWarningCount + 1)
            log.record("health.memory_warning", resource.diagnosticFields, sampleEvery: 1)
            return
        }
        if previousResources?.thermal != resource.thermal {
            log.record("health.thermal_changed", resource.diagnosticFields)
        }
        if previousResources?.lowPowerMode != resource.lowPowerMode {
            log.record("health.low_power_changed", resource.diagnosticFields)
        }
        previousResources = resource
    }
}
