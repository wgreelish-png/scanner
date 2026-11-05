import XCTest
import UIKit
@testable import CardShowScanner

final class DeviceHealthValuesTests: XCTestCase {
    func testHeartbeatAggregatesDelaysWithoutCountingOrdinaryTicksOrInactiveTime() {
        var window = DeviceResponsivenessWindow()
        window.reset(at: 100)
        window.heartbeat(at: 102)
        window.heartbeat(at: 104.5)
        window.heartbeat(at: 106.6)
        XCTAssertEqual(window.takeFields(), ["ui_lag_count": "1", "ui_lag_max_ms": "500"])
        window.heartbeat(at: 109.1)
        XCTAssertEqual(window.takeFields(), ["ui_lag_count": "1", "ui_lag_max_ms": "500"])
        window.reset()
        window.reset(at: 10_000)
        window.heartbeat(at: 10_002)
        XCTAssertEqual(window.takeFields(), ["ui_lag_count": "0", "ui_lag_max_ms": "0"])
        window.heartbeat(at: .nan)
        window.heartbeat(at: 10_100)
        XCTAssertEqual(window.delayedCount, 0, "Invalid clocks retire the earlier deadline")
    }

    func testUnknownBatteryLevelsStayMissingAndStateRemainsIndependent() {
        for level in [Float(-1), Float.nan, Float.infinity, Float(1.1)] {
            XCTAssertNil(DeviceBatterySample(level: level, state: .unknown).percentage)
        }
        XCTAssertEqual(DeviceBatterySample(level: 0, state: .unplugged).percentage, 0)
        XCTAssertEqual(DeviceBatterySample(level: 0.5, state: .charging).percentage, 50)
        XCTAssertEqual(DeviceBatterySample(level: 1, state: .full).percentage, 100)
        XCTAssertEqual(DeviceThermalLevel(.nominal), .nominal)
        XCTAssertEqual(DeviceThermalLevel(.fair), .fair)
        XCTAssertEqual(DeviceThermalLevel(.serious), .serious)
        XCTAssertEqual(DeviceThermalLevel(.critical), .critical)
    }

    func testHealthValidationRejectsUnboundedOrFreeFormMeasurements() {
        let maxima = ["native_memory_mb": 65_536, "native_cpu_ms": 3_600_000, "sample_window_ms": 3_600_000,
            "battery_percent": 100, "ui_lag_count": 10_000, "ui_lag_max_ms": 60_000, "memory_warning_count": 10_000,
            "health_report_count": 1_000, "health_report_window_s": 604_800]
        for (key, maximum) in maxima {
            XCTAssertTrue(DiagnosticHealthFields.accepts(key, "0"), key)
            XCTAssertTrue(DiagnosticHealthFields.accepts(key, String(maximum)), key)
            for invalid in [String(maximum + 1), "-1", "+1", "01", "1.0", "1e2", "nan", "inf", "PRIVATE_VALUE"] {
                XCTAssertFalse(DiagnosticHealthFields.accepts(key, invalid), "\(key): \(invalid)")
            }
        }
        for (key, value) in ["thermal_level": "hot", "low_power_mode": "1", "process_scope": "all_processes",
                             "battery_state": "87", "health_report_kind": "raw_payload"] {
            XCTAssertFalse(DiagnosticHealthFields.accepts(key, value), key)
        }
    }
}

@MainActor final class DeviceHealthMonitorTests: XCTestCase {
    func testForegroundSamplesUseNativeProcessDeltasAndResetAcrossSuspension() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let monitor = fixture.monitor()
        monitor.setForeground(true)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(fixture.battery.isMonitoringEnabled)
        fixture.uptime = 2; monitor.heartbeatNow()
        fixture.uptime = 4.5; monitor.heartbeatNow()
        fixture.uptime = 30; fixture.cpu = 10.15; monitor.sampleNow()
        var samples = try fixture.fields(for: "health.sample")
        XCTAssertEqual(samples.count, 2)
        XCTAssertNil(samples[0]["native_cpu_ms"], "The first sample establishes a CPU baseline")
        XCTAssertEqual(samples[1]["process_scope"], "native_app")
        XCTAssertEqual(samples[1]["native_memory_mb"], "42")
        XCTAssertEqual(samples[1]["native_cpu_ms"], "150")
        XCTAssertEqual(samples[1]["sample_window_ms"], "30000")
        XCTAssertEqual(samples[1]["battery_percent"], "50")
        XCTAssertEqual(samples[1]["battery_state"], "charging")
        XCTAssertEqual(samples[1]["ui_lag_count"], "1")
        XCTAssertEqual(samples[1]["ui_lag_max_ms"], "500")

        monitor.setForeground(false)
        XCTAssertFalse(fixture.battery.isMonitoringEnabled)
        fixture.uptime = 10_000; fixture.cpu = 200
        monitor.heartbeatNow(); monitor.sampleNow()
        XCTAssertEqual(try fixture.fields(for: "health.sample").count, 2)
        monitor.setForeground(true)
        fixture.uptime = 10_002; monitor.heartbeatNow()
        fixture.uptime = 10_030; fixture.cpu = 200.05; monitor.sampleNow()
        samples = try fixture.fields(for: "health.sample")
        XCTAssertNil(samples[2]["native_cpu_ms"])
        XCTAssertEqual(samples[3]["native_cpu_ms"], "50")
        XCTAssertEqual(samples[3]["ui_lag_count"], "0", "Offscreen dwell is not a UI stall")
        monitor.setForeground(false)
    }

    func testOptOutStopsObserversAndRestoresBatteryThenReenablesFromCleanBaselines() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let monitor = fixture.monitor()
        monitor.setForeground(true)
        fixture.resources = DeviceResourceState(thermal: .serious, lowPowerMode: true)
        fixture.center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        await settle()
        XCTAssertEqual(try fixture.fields(for: "health.thermal_changed").count, 1)
        XCTAssertEqual(try fixture.fields(for: "health.low_power_changed").count, 1,
                       "Coalesced notifications must not lose either changed state")
        fixture.center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        await settle()
        fixture.uptime = 30; monitor.sampleNow()
        XCTAssertEqual(try fixture.fields(for: "health.memory_warning").count, 1)
        XCTAssertEqual(try fixture.fields(for: "health.sample").last?["memory_warning_count"], "1")

        fixture.defaults.set(false, forKey: "diagnosticsEnabled")
        fixture.center.post(name: UserDefaults.didChangeNotification, object: nil)
        await settle()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(fixture.battery.isMonitoringEnabled)
        let reads = fixture.processReads
        fixture.center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        monitor.sampleNow(); monitor.heartbeatNow()
        await settle()
        XCTAssertEqual(fixture.processReads, reads)
        fixture.defaults.set(true, forKey: "diagnosticsEnabled")
        fixture.center.post(name: UserDefaults.didChangeNotification, object: nil)
        await settle()
        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(fixture.battery.isMonitoringEnabled)
        XCTAssertEqual(try fixture.fields(for: "health.sample").last?["ui_lag_count"], "0")
        monitor.setForeground(false)
        fixture.defaults.set(false, forKey: "diagnosticsEnabled")
        fixture.center.post(name: UserDefaults.didChangeNotification, object: nil)
        await settle()
        XCTAssertFalse(monitor.isRunning)
    }

    func testExistingBatteryMonitoringOwnershipSurvivesRepeatedLifecycleChanges() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.battery.isMonitoringEnabled = true
        let monitor = fixture.monitor()
        monitor.setForeground(true); monitor.setForeground(true)
        XCTAssertEqual(fixture.processReads, 1, "Duplicate active callbacks do not restart telemetry")
        monitor.setForeground(false); monitor.setForeground(false)
        XCTAssertTrue(fixture.battery.isMonitoringEnabled)
        fixture.defaults.set(false, forKey: "diagnosticsEnabled")
        monitor.setForeground(true)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertTrue(fixture.battery.isMonitoringEnabled)
        monitor.setForeground(false)
    }

    func testDroppingMonitorCancelsBothSleepingTasksAndReleasesBatteryLease() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let waiting = expectation(description: "Both low-frequency tasks are sleeping")
        waiting.expectedFulfillmentCount = 2
        let cancelled = expectation(description: "Both sleepers were cancelled")
        cancelled.expectedFulfillmentCount = 2
        var monitor: DeviceHealthMonitor? = fixture.monitor(automaticallySchedules: true, wait: { _ in
            waiting.fulfill()
            do { try await Task.sleep(for: .seconds(3_600)) }
            catch { cancelled.fulfill(); throw error }
        })
        weak var retainedMonitor = monitor
        monitor?.setForeground(true)
        await fulfillment(of: [waiting], timeout: 2)
        monitor = nil
        XCTAssertNil(retainedMonitor, "Sleeping tasks and notification observers must not retain the monitor")
        await fulfillment(of: [cancelled], timeout: 2)
        await settle()
        XCTAssertFalse(fixture.battery.isMonitoringEnabled)
    }

    func testHealthStorageDropsRawValuesUnknownFieldsAndNonHealthMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.log.record("health.sample", ["thermal_level": "fair", "low_power_mode": "false", "native_cpu_ms": "23",
            "process_scope": "native_app", "battery_percent": "101", "ui_lag_max_ms": "NaN",
            "native_memory_mb": "PRIVATE_MEMORY", "temperature_celsius": "42", "code": "PRIVATE_CODE",
            "health_report_kind": "raw_payload", "health_report_count": "01"])
        XCTAssertEqual(try fixture.fields(for: "health.sample"), [["thermal_level": "fair", "low_power_mode": "false",
            "native_cpu_ms": "23", "process_scope": "native_app"]])
        fixture.log.record("health.os_report", ["health_report_kind": "hang", "health_report_count": "2", "health_report_window_s": "86400"])
        XCTAssertEqual(try fixture.fields(for: "health.os_report").first,
                       ["health_report_kind": "hang", "health_report_count": "2", "health_report_window_s": "86400"])
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    @MainActor private final class Battery: DeviceBatteryMonitoring {
        var isMonitoringEnabled = false
        func sample() -> DeviceBatterySample { .init(level: 0.5, state: .charging) }
    }

    @MainActor private final class Fixture {
        let suite = "DeviceHealthTests." + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults: UserDefaults
        let log: DiagnosticLog
        let center = NotificationCenter()
        let battery = Battery()
        var uptime: TimeInterval = 0
        var cpu: TimeInterval = 10
        var processReads = 0
        var resources = DeviceResourceState(thermal: .nominal, lowPowerMode: false)

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            log = DiagnosticLog(directory: directory, defaults: defaults)
        }
        func monitor(automaticallySchedules: Bool = false,
                     wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) -> DeviceHealthMonitor {
            DeviceHealthMonitor(log: log, center: center, battery: battery, resources: { self.resources }, process: {
                self.processReads += 1
                return DeviceProcessSample(footprintBytes: 42 * 1_048_576, cpuSeconds: self.cpu)
            }, uptime: { self.uptime }, automaticallySchedules: automaticallySchedules, wait: wait)
        }
        func fields(for event: String) throws -> [[String: String]] {
            let file = try log.exportForCopy()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap { line in
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                return row["event"] as? String == event ? row["fields"] as? [String: String] : nil
            }
        }
        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
