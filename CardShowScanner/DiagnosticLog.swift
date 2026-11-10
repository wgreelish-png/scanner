import Foundation
import Observation
import OSLog

/// A second check at storage keeps the newly allowlisted scan fields numeric or
/// enum-only even if another caller accidentally supplies arbitrary text.
enum DiagnosticScanFields {
    static func accepts(_ key: String, _ value: String) -> Bool {
        if key == "resource_mode" { return ["normal", "reduced", "cooling"].contains(value) }
        if key == "capture_state" { return ["live", "review", "manual", "prompt", "stopped"].contains(value) }
        if key == "constraint_state" { return ["pending", "applied", "unsupported", "failed", "inactive"].contains(value) }
        if key == "processing_active" { return value == "true" || value == "false" }
        if key == "target_fps" { return ["0", "1", "10", "30"].contains(value) }
        if key == "camera_fps" {
            guard value.range(of: #"\A(?:0|[1-9][0-9]{0,2})(?:\.[0-9]{1,3})?\z"#, options: .regularExpression) != nil,
                  let fps = Double(value), fps.isFinite else { return false }
            return (0...240).contains(fps)
        }
        if key == "method" { return ["direct", "server"].contains(value) }
        if ["solid", "tracked", "border_retry", "border_retained"].contains(key) { return value == "true" || value == "false" }
        if key == "scan_stage" { return ["none", "one", "quick", "full"].contains(value) }
        if key == "quad_source" { return ["none", "detected", "selected"].contains(value) }
        if key == "shape" { return ["missing", "object", "array", "null", "string", "number", "boolean"].contains(value) }
        let integers: Set<String> = ["raw_quads", "rejected_quads", "candidate_quads", "selected_base", "sample_age_ms", "record_index", "page", "total", "priced_records", "unpriced_records", "invalid_price_records", "observed_count", "entry_limit"]
        let maxima: [String: Double] = ["quad_aspect": 1, "quad_area": 1, "quad_support": 1,
            "mean_luma": 255, "luma_std": 128, "match_distance": 100, "match_gap": 100, "sample_age_ms": 600_000]
        guard integers.contains(key) || maxima[key] != nil else { return true }
        guard let number = Double(value), number.isFinite, (0...(maxima[key] ?? 1_000_000)).contains(number) else { return false }
        return !integers.contains(key) || number.rounded(.towardZero) == number
    }
}

/// Printer transport diagnostics describe byte counts and command identifiers,
/// never packet contents, Bluetooth names or device identifiers. Validate at
/// storage as well as at the native caller so accidental free-form values drop.
enum DiagnosticPrinterFields {
    static let timingKeys: Set<String> = ["transfer_elapsed_ms", "plan_encode_ms", "packet_encode_ms", "packet_pacing_ms",
        "att_ack_wait_ms", "printer_reply_wait_ms", "status_poll_ms", "status_backoff_ms", "print_start_ms",
        "print_end_ms", "previous_job_gap_ms", "roll_read_ms", "preparation_elapsed_ms", "render_elapsed_ms",
        "approval_save_ms", "queue_save_ms"]
    static let batchingBounds: [String: UInt64] = [
        "image_write_count": 1_000_000, "image_batch_count": 1_000_000,
        "image_batched_packets": 1_000_000, "group_image_writes": 1_000_000,
        "image_max_write_bytes": 65_535, "image_batch_limit": 256, "image_batch_frame_limit": 16,
        "image_requested_byte_limit": 256, "image_pacing_ms": 50
    ]
    static let batchingKeys = Set(batchingBounds.keys)
    static let rollKeys: Set<String> = ["roll_read_result", "roll_read_error", "roll_detection_result", "roll_product_code",
        "label_width_mm", "label_height_mm", "label_feed_dots", "label_head_dots"]

    static func accepts(_ key: String, _ value: String, event: String? = nil) -> Bool {
        if timingKeys.contains(key) { return acceptsInteger(value, maximum: 3_600_000) }
        if let maximum = batchingBounds[key] { return acceptsInteger(value, maximum: maximum) }
        if rollKeys.contains(key) { return acceptsRoll(key, value, event: event) }
        if key == "elapsed_ms", event?.hasPrefix("label.") == true {
            return acceptsInteger(value, maximum: 3_600_000)
        }
        if ["label.preparation_summary", "label.group_transfer", "label.transfer_summary"].contains(event ?? ""),
           ["page", "total", "quantity"].contains(key) {
            return acceptsInteger(value, maximum: 250)
        }
        if event == "label.preparation_summary", key == "phase" {
            return ["completed", "failed", "reused_queue"].contains(value)
        }
        if event == "label.group_transfer", key == "accepted" { return value == "true" || value == "false" }
        switch key {
        case "request_code", "response_code", "last_response_code", "protocol_version":
            return acceptsInteger(value, maximum: 255)
        case "printer_model":
            return acceptsInteger(value, maximum: 65_535)
        case "sent_bytes", "notification_bytes", "notification_count", "packet_count":
            return acceptsInteger(value, maximum: 1_000_000)
        case "native_groups", "native_copies", "print_start_count", "print_end_count", "render_count", "raster_reuse_count":
            return acceptsInteger(value, maximum: 250)
        case "image_packets", "request_count", "status_polls", "group_image_packets", "group_requests":
            return acceptsInteger(value, maximum: 1_000_000)
        case "wire_bytes", "group_wire_bytes":
            return acceptsInteger(value, maximum: 100_000_000)
        case "write_mode":
            return ["acknowledged", "unacknowledged"].contains(value)
        case "print_task":
            return ["legacy_serial", "declared_serial", "buffered_copies"].contains(value)
        case "command_path":
            return ["d110", "d110m_b1", "d110m_v4"].contains(value)
        case "preparation_kind":
            return ["inventory", "custom"].contains(value)
        case "preparation_stage":
            return ["preview", "queue"].contains(value)
        case "roll_read_source":
            return ["cache", "read", "in_flight", "forced", "unavailable"].contains(value)
        case "connection_end_source":
            return ["replace_connection", "manual_disconnect", "stop_requested", "print_cancelled",
                    "required_failure", "request_cancelled"].contains(value)
        default:
            return true
        }
    }

    private static func acceptsRoll(_ key: String, _ value: String, event: String?) -> Bool {
        switch key {
        case "roll_read_result":
            return event == "label.roll_read" && ["response", "no_roll", "failed"].contains(value)
        case "roll_read_error":
            return event == "label.roll_read" && ["responseTimeout", "printerBusy", "cancelled", "unsupportedResponse",
                "notActive", "notConnected", "connectionLost", "writeFailed", "other"].contains(value)
        default:
            guard event == "label.roll_detection" else { return false }
            switch key {
            case "roll_detection_result":
                return ["matched", "unknown_product", "media_mismatch", "unavailable", "invalidated"].contains(value)
            case "roll_product_code":
                // This is a nonunique catalog SKU, not a tag UID or roll serial.
                // Keep leading zeros rather than parsing the product as an integer.
                return (1...32).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) }
            case "label_width_mm", "label_height_mm":
                guard value.range(of: #"\A(?:0|[1-9][0-9]{0,2})(?:\.[0-9]{1,6})?\z"#, options: .regularExpression) != nil,
                      let millimeters = Double(value), millimeters.isFinite else { return false }
                return millimeters > 0 && millimeters <= 100
            case "label_feed_dots":
                return acceptsInteger(value, maximum: 800) && value != "0"
            case "label_head_dots":
                return value == "96"
            default:
                return false
            }
        }
    }

    private static func acceptsInteger(_ value: String, maximum: UInt64) -> Bool {
        guard let number = UInt64(value), number <= maximum else { return false }
        // Native String(integer) values are canonical decimal text. Reject
        // signs, whitespace, fractions, exponent notation and padded strings.
        return String(number) == value
    }
}

/// Health diagnostics contain bounded aggregate measurements and fixed states,
/// never raw OS reports, device identifiers, temperatures or user content.
enum DiagnosticHealthFields {
    static let keys: Set<String> = ["thermal_level", "low_power_mode", "process_scope", "native_memory_mb",
        "native_cpu_ms", "sample_window_ms", "battery_state", "battery_percent", "ui_lag_count",
        "ui_lag_max_ms", "memory_warning_count", "health_report_kind", "health_report_count", "health_report_window_s"]

    static func accepts(_ key: String, _ value: String) -> Bool {
        switch key {
        case "thermal_level": return ["nominal", "fair", "serious", "critical", "unknown"].contains(value)
        case "low_power_mode": return value == "true" || value == "false"
        case "process_scope": return value == "native_app"
        case "battery_state": return ["unknown", "unplugged", "charging", "full"].contains(value)
        case "health_report_kind": return ["crash", "hang", "cpu_exception", "disk_write_exception"].contains(value)
        case "native_memory_mb": return integer(value, maximum: 65_536)
        case "native_cpu_ms", "sample_window_ms": return integer(value, maximum: 3_600_000)
        case "battery_percent": return integer(value, maximum: 100)
        case "ui_lag_count", "memory_warning_count": return integer(value, maximum: 10_000)
        case "ui_lag_max_ms": return integer(value, maximum: 60_000)
        case "health_report_count": return integer(value, maximum: 1_000)
        case "health_report_window_s": return integer(value, maximum: 604_800)
        default: return true
        }
    }

    private static func integer(_ text: String, maximum: UInt64) -> Bool {
        guard let value = UInt64(text), value <= maximum else { return false }
        return String(value) == text
    }
}

/// Only fixed classifications and numeric status/timing values leave a service
/// client. Never copy response messages, request URLs or credential values here.
enum ServiceDiagnosticFields {
    enum Phase: String, Sendable {
        case setup, researchMeta = "research_meta", serverHealth = "server_health", researchProduct = "research_product"
        case opportunitiesMeta = "opportunities_meta", opportunitiesProduct = "opportunities_product"
    }
    static func failure(_ error: Error) -> [String: String] {
        if let error = error as? MarketPricingFailure {
            switch error {
            case .accessRejected(let code):
                var fields = ["domain": "market", "reason": "access_rejected"]
                if (100...599).contains(code) { fields["code"] = String(code) }
                return fields
            case .publicPageUnavailable: return ["domain": "market", "reason": "public_page_unavailable"]
            }
        }
        if let error = error as? BetaAPIIndexValidationFailure { return error.diagnosticFields }
        if let error = error as? CardShowInventoryFailure {
            return ["domain": "inventory", "reason": error.diagnosticReason]
        }
        if let error = error as? BetaAPICadenceFailure {
            switch error {
            case .invalidRequest: return ["domain": "beta", "reason": "invalid_request"]
            case .invalidResponse: return ["domain": "beta", "reason": "invalid_response"]
            case .unsupportedIndex: return ["domain": "beta", "reason": "unsupported_index"]
            case .responseTooLarge: return ["domain": "beta", "reason": "response_too_large"]
            case .networkUnavailable: return ["domain": "beta", "reason": "network_unavailable"]
            case .httpStatus(let code):
                var fields = ["domain": "beta", "reason": "http_failure"]
                if (100...599).contains(code) { fields["code"] = String(code) }
                return fields
            }
        }
        if let error = error as? OpenAPIPricingFailure {
            let reason: String
            var status: Int?
            switch error {
            case .httpStatus(let code): reason = "http_failure"; status = code
            case .invalidResponse: reason = "invalid_response"
            case .responseTooLarge: reason = "response_too_large"
            case .unsupportedCard: reason = "unsupported_card"
            case .catalogUnavailable: reason = "catalog_mapping_missing"
            }
            var fields = ["domain": "openapi", "reason": reason]
            if let status, (100...599).contains(status) { fields["code"] = String(status) }
            return fields
        }
        if let error = error as? OpportunitiesFailure {
            let reason: String
            var status: Int?
            switch error {
            case .notConfigured: reason = "server_not_configured"
            case .directNotConfigured: reason = "direct_credentials_missing"
            case .unsupportedCard: reason = "unsupported_card"
            case .catalogUnavailable: reason = "catalog_mapping_missing"
            case .authorizationRequired: reason = "device_token_rejected"; status = 401
            case .directAuthorizationRequired: reason = "beta_credentials_rejected"; status = 401
            case .accessDenied: reason = "access_denied"; status = 403
            case .notCovered: reason = "product_not_covered"
            case .skuNotCovered: reason = "exact_sku_not_covered"
            case .invalidResponse: reason = "invalid_response"
            case .responseTooLarge: reason = "response_too_large"
            case .networkUnavailable: reason = "network_unavailable"
            case .rateLimited: reason = "rate_limited"; status = 429
            case .serviceUnavailable(let code): reason = "service_unavailable"; status = code
            }
            var fields = ["domain": "opportunities", "reason": reason]
            if let status, (100...599).contains(status) { fields["code"] = String(status) }
            return fields
        }
        if let error = error as? PSACertificateFailure {
            let reason: String
            switch error {
            case .invalidCertificate: reason = "invalid_certificate"
            case .notConfigured: reason = "adapter_not_configured"
            case .notFound: reason = "certificate_not_found"
            case .invalidResponse: reason = "invalid_certificate_response"
            case .unavailable: reason = "certificate_unavailable"
            }
            return ["domain": "psa", "reason": reason]
        }
        if let error = error as? ResearchFailure {
            let reason: String
            var status: Int?
            switch error {
            case .notConfigured: reason = "server_not_configured"
            case .directNotConfigured: reason = "direct_credentials_missing"
            case .unsupportedCard: reason = "unsupported_card"
            case .catalogUnavailable: reason = "catalog_mapping_missing"
            case .authorizationRequired: reason = "device_token_rejected"; status = 401
            case .directAuthorizationRequired: reason = "research_credentials_rejected"; status = 401
            case .accessDenied: reason = "access_denied"; status = 403
            case .notCovered: reason = "not_covered"
            case .invalidResponse: reason = "invalid_response"
            case .responseTooLarge: reason = "response_too_large"
            case .networkUnavailable: reason = "network_unavailable"
            case .serviceUnavailable(let code): reason = "service_unavailable"; status = code
            }
            var fields = ["domain": "research", "reason": reason]
            if let status, (100...599).contains(status) { fields["code"] = String(status) }
            return fields
        }
        if let error = error as? ResearchConnectionFailure {
            let reason: String
            switch error {
            case .invalidConfiguration: reason = "invalid_connection_settings"
            case .storage: reason = "keychain_unavailable"
            case .invalidResponse: reason = "invalid_connection_response"
            }
            return ["domain": "research_connection", "reason": reason]
        }
        if error is CancellationError { return ["domain": "request", "reason": "cancelled"] }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return ["domain": "network", "reason": "transport_error", "code": String(ns.code)] }
        return ["domain": "request", "reason": "unclassified_failure"]
    }

    static func record(_ event: String, method: ResearchAccessMethod, phase: Phase,
                       status: Int? = nil, started: Date? = nil, error: Error? = nil) async {
        guard !Task.isCancelled else { return }
        var fields = error.map(failure) ?? [:]
        fields["method"] = method.rawValue; fields["phase"] = phase.rawValue
        if let status, (100...599).contains(status) { fields["code"] = String(status) }
        if let started { fields["elapsed_ms"] = String(Int(max(0, min(3_600_000, Date().timeIntervalSince(started) * 1_000)))) }
        let safeFields = fields
        await MainActor.run {
            guard !Task.isCancelled else { return }
            DiagnosticLog.shared.record(event, safeFields)
        }
    }
}

/// Local, bounded JSON-lines diagnostics. Callers supply event codes, never user content.
@MainActor @Observable final class DiagnosticLog {
    static let shared = DiagnosticLog()
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    #if DEBUG
    private static let console = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CardShowScanner", category: "Diagnostics")
    #endif
    private(set) var storageFailed = false
    private let directory: URL
    private let maximumBytes: Int
    private let defaults: UserDefaults
    private let run = UUID().uuidString
    private var lastSamples: [String: Date] = [:]
    private let keys: Set<String> = Set(["provider", "game", "episode", "same", "accepted", "confidence", "candidates",
        "printing_required", "priced", "merged", "automatic", "quantity", "reason", "stage", "backend", "elapsed_ms",
        "scan_ms", "capture_ms", "frames", "domain", "code", "records", "rejected_records", "phase", "candidate_index", "app_version", "build", "downloaded_bytes", "cached_shards", "cache", "source", "persisted", "cache_backend", "revision",
        "record_index", "page", "total", "shape", "priced_records", "unpriced_records", "invalid_price_records", "observed_count", "entry_limit", "method", "solid", "tracked", "border_retry", "border_retained", "scan_stage", "raw_quads", "rejected_quads", "candidate_quads", "selected_base", "quad_source",
        "quad_aspect", "quad_area", "quad_support", "mean_luma", "luma_std", "match_distance", "match_gap", "sample_age_ms",
        "request_code", "response_code", "last_response_code", "sent_bytes", "notification_bytes", "notification_count", "packet_count", "write_mode",
        "print_task", "native_groups", "native_copies", "image_packets", "request_count", "wire_bytes", "status_polls",
        "command_path", "printer_model", "protocol_version", "print_start_count", "print_end_count",
        "group_image_packets", "group_requests", "group_wire_bytes", "preparation_kind", "preparation_stage",
        "render_count", "raster_reuse_count", "roll_read_source", "connection_end_source",
        "resource_mode", "capture_state", "target_fps", "camera_fps", "processing_active", "constraint_state"])
        .union(DiagnosticPrinterFields.timingKeys)
        .union(DiagnosticPrinterFields.batchingKeys)
        .union(DiagnosticPrinterFields.rollKeys)
    private var current: URL { directory.appendingPathComponent("current.jsonl") }
    private var previous: URL { directory.appendingPathComponent("previous.jsonl") }
    var enabled: Bool { defaults.object(forKey: "diagnosticsEnabled") as? Bool ?? true }

    init(directory: URL? = nil, maximumBytes: Int = 262144, defaults: UserDefaults = .standard) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        self.maximumBytes = max(1024, maximumBytes)
        self.defaults = defaults
    }
    func record(_ event: String, _ fields: [String: String] = [:], sampleEvery: TimeInterval = 0) {
        guard enabled else { return }
        guard event.range(of: #"^[a-z][a-z0-9_.]{0,79}$"#, options: .regularExpression) != nil else { return }
        let now = Date()
        if sampleEvery > 0, let last = lastSamples[event], now.timeIntervalSince(last) < sampleEvery { return }
        if sampleEvery > 0 { lastSamples[event] = now }
        // Unknown fields and free-form values are dropped at the storage boundary.
        let safe = fields.filter { key, value in
            (keys.contains(key) || DiagnosticHealthFields.keys.contains(key)) &&
                (!event.hasPrefix("health.") || DiagnosticHealthFields.keys.contains(key)) && value.count <= 80 &&
                value.range(of: #"^[A-Za-z0-9_.-]{1,80}$"#, options: .regularExpression) != nil &&
                DiagnosticScanFields.accepts(key, value) && DiagnosticPrinterFields.accepts(key, value, event: event) &&
                DiagnosticHealthFields.accepts(key, value)
        }
        let entry: [String: Any] = ["schema": 1, "time": Self.timestampFormatter.string(from: now),
            "run": run, "event": event, "fields": safe]
        do {
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]); data.append(10)
            guard data.count <= maximumBytes else { return }
            #if DEBUG
            // Mirror the same filtered event, even if writing the local file fails.
            // Notice-level events are visible in Xcode and macOS Console while attached.
            let line = String(decoding: data.dropLast(), as: UTF8.self)
            Self.console.notice("[CardShowScanner] \(line, privacy: .public)")
            #endif
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let attributes = try? FileManager.default.attributesOfItem(atPath: current.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > maximumBytes {
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                if FileManager.default.fileExists(atPath: current.path) { try FileManager.default.moveItem(at: current, to: previous) }
            }
            if !FileManager.default.fileExists(atPath: current.path) { try Data().write(to: current, options: .atomic) }
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
            storageFailed = false
        } catch { storageFailed = true }
    }
    func failure(_ event: String, _ error: Error) {
        if let marketError = error as? MarketPricingFailure, case let .accessRejected(status) = marketError {
            record(event, ["domain": "market", "code": String(status), "reason": "access_rejected"]); return
        }
        let ns = error as NSError
        let domains: Set<String> = [NSCocoaErrorDomain, NSURLErrorDomain, "WKErrorDomain", "CardShowScanner.BridgeFailure"]
        record(event, ["domain": domains.contains(ns.domain) ? ns.domain : "other", "code": String(ns.code)])
    }
    func clear() throws {
        for url in [current, previous] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        lastSamples.removeAll(); storageFailed = false
    }
    func export() throws -> URL {
        try exportFile(event: "diagnostics.export")
    }

    func exportForCopy() throws -> URL {
        try exportFile(event: "diagnostics.copy")
    }

    private func exportFile(event: String) throws -> URL {
        record(event)
        let data = try reportData()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CardShowDiagnostics-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("CardShowScanner-diagnostics.jsonl")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func reportData() throws -> Data {
        let bundle = Bundle.main
        let header: [String: Any] = ["schema": 1, "event": "diagnostics.environment", "time": Self.timestampFormatter.string(from: .now),
            "app_version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "revision": bundle.object(forInfoDictionaryKey: "ScannerWorkflowRevision") as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "note": "Local app events and aggregate device health only; no system console, raw OS reports, card/list contents, credentials, images, or raw web responses. Native process samples exclude WebKit processes."]
        var data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]); data.append(10)
        for url in [previous, current] where FileManager.default.fileExists(atPath: url.path) {
            data.append(try Data(contentsOf: url))
        }
        return data
    }
}
