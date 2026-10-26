import Foundation
import Observation
import OSLog

/// A second check at storage keeps the newly allowlisted scan fields numeric or
/// enum-only even if another caller accidentally supplies arbitrary text.
enum DiagnosticScanFields {
    static func accepts(_ key: String, _ value: String) -> Bool {
        if key == "solid" || key == "tracked" { return value == "true" || value == "false" }
        if key == "scan_stage" { return ["none", "one", "quick", "full"].contains(value) }
        if key == "quad_source" { return ["none", "detected", "selected"].contains(value) }
        let integers: Set<String> = ["raw_quads", "rejected_quads", "candidate_quads", "selected_base", "sample_age_ms"]
        let maxima: [String: Double] = ["quad_aspect": 1, "quad_area": 1, "quad_support": 1,
            "mean_luma": 255, "luma_std": 128, "match_distance": 100, "match_gap": 100, "sample_age_ms": 600_000]
        guard integers.contains(key) || maxima[key] != nil else { return true }
        guard let number = Double(value), number.isFinite, (0...(maxima[key] ?? 1_000_000)).contains(number) else { return false }
        return !integers.contains(key) || number.rounded(.towardZero) == number
    }
}

/// Local, bounded JSON-lines diagnostics. Callers supply event codes, never user content.
@MainActor @Observable final class DiagnosticLog {
    static let shared = DiagnosticLog()
    #if DEBUG
    private static let console = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CardShowScanner", category: "Diagnostics")
    #endif
    private(set) var storageFailed = false
    private let directory: URL
    private let maximumBytes: Int
    private let defaults: UserDefaults
    private let run = UUID().uuidString
    private var lastSamples: [String: Date] = [:]
    private let keys: Set<String> = ["provider", "game", "episode", "same", "accepted", "confidence", "candidates",
        "printing_required", "priced", "merged", "automatic", "quantity", "reason", "stage", "backend", "elapsed_ms",
        "scan_ms", "capture_ms", "frames", "domain", "code", "records", "rejected_records", "phase", "candidate_index", "app_version", "build", "downloaded_bytes", "cached_shards", "cache", "source", "persisted", "cache_backend", "revision",
        "solid", "tracked", "scan_stage", "raw_quads", "rejected_quads", "candidate_quads", "selected_base", "quad_source",
        "quad_aspect", "quad_area", "quad_support", "mean_luma", "luma_std", "match_distance", "match_gap", "sample_age_ms"]
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
            keys.contains(key) && value.count <= 80 &&
                value.range(of: #"^[A-Za-z0-9_.-]{1,80}$"#, options: .regularExpression) != nil && DiagnosticScanFields.accepts(key, value)
        }
        let entry: [String: Any] = ["schema": 1, "time": ISO8601DateFormatter().string(from: now),
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
        record("diagnostics.export")
        let bundle = Bundle.main
        let header: [String: Any] = ["schema": 1, "event": "diagnostics.environment", "time": ISO8601DateFormatter().string(from: .now),
            "app_version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "revision": bundle.object(forInfoDictionaryKey: "ScannerWorkflowRevision") as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "note": "Local app events only; no system console, card/list contents, credentials, images, or raw web responses."]
        var data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]); data.append(10)
        for url in [previous, current] where FileManager.default.fileExists(atPath: url.path) {
            data.append(try Data(contentsOf: url))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CardShowDiagnostics-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("CardShowScanner-diagnostics.jsonl")
        try data.write(to: url, options: .atomic)
        return url
    }
}
