import XCTest
import UniformTypeIdentifiers
@testable import CardShowScanner

@MainActor final class ScannerDiagnosticsTests: XCTestCase {
    func testFileForCopyIncludesEnvironmentAndSanitizedEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "DiagnosticFileCopy." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        let safe = ["method": "direct", "phase": "research_product", "code": "403", "reason": "access_denied"]
        log.record("research.lookup_failed", safe.merging([
            "cookie": "PRIVATE_COOKIE", "api_key": "PRIVATE_KEY", "body": "PRIVATE_RESPONSE",
            "url": "https://private.example", "mean_luma": "PRIVATE_VALUE"
        ]) { _, value in value })

        let file = try log.exportForCopy()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertTrue(file.isFileURL)
        XCTAssertEqual(file.lastPathComponent, "CardShowScanner-diagnostics.jsonl")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_"))
        XCTAssertFalse(text.contains("private.example"))
        let rows = try diagnosticRows(text)
        XCTAssertEqual(rows.compactMap { $0["event"] as? String },
                       ["diagnostics.environment", "research.lookup_failed", "diagnostics.copy"])
        let header = try XCTUnwrap(rows.first)
        XCTAssertEqual(header["schema"] as? Int, 1)
        for key in ["app_version", "build", "revision", "os", "time"] {
            XCTAssertFalse(try XCTUnwrap(header[key] as? String).isEmpty, "Missing environment field: \(key)")
        }
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for row in rows {
            let value = try XCTUnwrap(row["time"] as? String)
            XCTAssertNotNil(value.range(of: #"\.[0-9]{3}Z$"#, options: .regularExpression))
            XCTAssertNotNil(timestamp.date(from: value), "Diagnostic timestamps include milliseconds for stage correlation")
        }
        XCTAssertEqual(rows[1]["fields"] as? [String: String], safe)
        XCTAssertEqual(rows[2]["fields"] as? [String: String], [:])
    }

    func testFileForCopyWhileRecordingDisabledKeepsHeaderAndPreviousCurrentOrderWithoutChangingSavedLogs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "DisabledDiagnosticFileCopy." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "diagnosticsEnabled")
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        XCTAssertFalse(log.enabled)
        let emptyFile = try log.exportForCopy()
        defer { try? FileManager.default.removeItem(at: emptyFile.deletingLastPathComponent()) }
        let emptyRows = try diagnosticRows(String(contentsOf: emptyFile, encoding: .utf8))
        XCTAssertEqual(emptyRows.compactMap { $0["event"] as? String }, ["diagnostics.environment"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Copying an empty report does not create saved log files")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = directory.appendingPathComponent("previous.jsonl")
        let current = directory.appendingPathComponent("current.jsonl")
        let previousData = Data("{\"schema\":1,\"event\":\"fixture.previous\",\"fields\":{\"code\":\"401\"}}\n".utf8)
        let currentData = Data("{\"schema\":1,\"event\":\"fixture.current\",\"fields\":{\"code\":\"200\"}}\n".utf8)
        try previousData.write(to: previous)
        try currentData.write(to: current)
        log.record("fixture.disabled", ["code": "403"])
        let file = try log.exportForCopy()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rows = try diagnosticRows(String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(rows.compactMap { $0["event"] as? String },
                       ["diagnostics.environment", "fixture.previous", "fixture.current"])
        XCTAssertEqual(rows[1]["fields"] as? [String: String], ["code": "401"])
        XCTAssertEqual(rows[2]["fields"] as? [String: String], ["code": "200"])
        XCTAssertEqual(try Data(contentsOf: previous), previousData)
        XCTAssertEqual(try Data(contentsOf: current), currentData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["current.jsonl", "previous.jsonl"])
    }

    func testClipboardProviderLoadsTheNamedDiagnosticFileWithoutPlainTextRepresentation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "DiagnosticClipboardFile." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        log.record("scanner.stop")
        let file = try log.exportForCopy()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let expected = try Data(contentsOf: file)
        let provider = try DiagnosticFileClipboard.provider(for: file)

        XCTAssertEqual(provider.suggestedName, "CardShowScanner-diagnostics.jsonl")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.data.identifier))
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
        let loaded: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CocoaError(.fileReadUnknown) }
                    // The provider owns this temporary URL. Read it while its
                    // completion handler is running, as a receiving app does.
                    continuation.resume(returning: try Data(contentsOf: url))
                } catch { continuation.resume(throwing: error) }
            }
        }
        XCTAssertEqual(loaded, expected)
        let rows = try diagnosticRows(String(decoding: loaded, as: UTF8.self))
        XCTAssertEqual(rows.compactMap { $0["event"] as? String },
                       ["diagnostics.environment", "scanner.stop", "diagnostics.copy"])
    }

    private func diagnosticRows(_ text: String) throws -> [[String: Any]] {
        try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testPrinterHandshakeExportKeepsOnlyBoundedTransportMetadataWithoutDeviceOrPacketContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "PrinterHandshakeDiagnostics." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        let expected: [[String: String]] = [
            ["phase": "handshake", "stage": "connect", "request_code": "193", "response_code": "194",
             "last_response_code": "194", "sent_bytes": "9", "notification_bytes": "8", "notification_count": "1",
             "packet_count": "1", "write_mode": "acknowledged", "mean_luma": "71.500"],
            ["phase": "handshake", "stage": "printer_info", "request_code": "0", "response_code": "255",
             "last_response_code": "0", "sent_bytes": "0", "notification_bytes": "1000000", "notification_count": "0",
             "packet_count": "1000000", "write_mode": "unacknowledged"],
            ["phase": "print_failed", "stage": "page_end", "request_code": "227", "response_code": "228",
             "last_response_code": "179", "sent_bytes": "8", "notification_bytes": "11", "notification_count": "1",
             "packet_count": "1", "write_mode": "acknowledged", "reason": "responseTimeout"]
        ]
        for fields in expected {
            log.record("label.handshake_completed", fields.merging([
                "device_name": "D110_M-PRIVATE_DEVICE", "peripheral_id": "PRIVATE_PERIPHERAL",
                "serial": "PRIVATE_SERIAL", "packet_hex": "PRIVATE_PACKET_5555", "raw_data": "PRIVATE_RAW_BYTES",
                "characteristic_uuid": "PRIVATE_CHARACTERISTIC", "url": "https://private.example"
            ]) { _, value in value })
        }
        let file = try log.export()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_"))
        XCTAssertFalse(text.contains("private.example"))
        let rows = try diagnosticRows(text).filter { $0["event"] as? String == "label.handshake_completed" }
        XCTAssertEqual(rows.compactMap { $0["fields"] as? [String: String] }, expected,
                       "Native progress remains diagnosable without logging packet payloads or printer identity")
    }

    func testPrinterHandshakeExportDropsNondecimalOutOfRangeAndFreeFormTransportValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "RejectedPrinterHandshakeDiagnostics." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        let numericKeys = ["request_code", "response_code", "last_response_code", "sent_bytes", "notification_bytes", "notification_count", "packet_count"]
        let invalidValues = ["D110_M-PRIVATE_DEVICE", "PRIVATE_PACKET_5555", "-1", "1.5", "1e3", "0xff",
                             "1000001", "18446744073709551616", "01", "+1", " 1", "1\n", ""]
        for value in invalidValues {
            var fields = Dictionary(uniqueKeysWithValues: numericKeys.map { ($0, value) })
            fields["write_mode"] = "acknowledged-PRIVATE_DEVICE"
            fields["phase"] = "handshake"
            fields["mean_luma"] = "PRIVATE_LIGHTING"
            log.record("label.handshake_failed", fields)
        }
        log.record("label.handshake_failed", ["phase": "handshake", "request_code": "256", "response_code": "999",
            "last_response_code": "256", "sent_bytes": "1000001", "notification_bytes": "1000001",
            "notification_count": "1000001", "packet_count": "1000001", "write_mode": "withResponse"])
        let file = try log.exportForCopy()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_"))
        let rows = try diagnosticRows(text).filter { $0["event"] as? String == "label.handshake_failed" }
        XCTAssertEqual(rows.count, invalidValues.count + 1)
        for row in rows {
            XCTAssertEqual(row["fields"] as? [String: String], ["phase": "handshake"],
                           "Both scan and printer validators must run at the final storage boundary")
        }
    }

    func testPrintTransferSummaryStoresOnlyBoundedAggregateFieldsAndRespectsOptOut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "PrintTransferDiagnostics." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        let expected = ["print_task": "buffered_copies", "total": "250", "native_groups": "250", "native_copies": "219",
            "image_packets": "1000000", "request_count": "1000000", "wire_bytes": "100000000",
            "transfer_elapsed_ms": "3600000", "status_polls": "1000000"]
        log.record("label.transfer_summary", expected.merging([
            "card_name": "PRIVATE_CARD", "packet_hex": "PRIVATE_PACKET", "product_uid": "PRIVATE_ROLL"
        ]) { _, value in value })
        log.record("label.transfer_summary", ["print_task": "PRIVATE_PRINTER", "native_groups": "251", "native_copies": "251",
            "image_packets": "1000001", "request_count": "1e3", "wire_bytes": "100000001",
            "transfer_elapsed_ms": "3600001", "status_polls": "01"])
        defaults.set(false, forKey: "diagnosticsEnabled")
        log.record("label.transfer_summary", expected)
        let file = try log.exportForCopy()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let text = try String(contentsOf: file, encoding: .utf8)
        let rows = try diagnosticRows(text).filter { $0["event"] as? String == "label.transfer_summary" }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?["fields"] as? [String: String], expected)
        XCTAssertEqual(rows.last?["fields"] as? [String: String], [:])
        XCTAssertFalse(text.contains("PRIVATE_"))
        for key in expected.keys where key != "print_task" && key != "total" {
            for invalid in ["-1", "+1", "1.5", "1e3", "01", " 1", "1\n", "PRIVATE_VALUE", ""] {
                XCTAssertFalse(DiagnosticPrinterFields.accepts(key, invalid), "\(key) must reject noncanonical values")
            }
        }
    }

    func testPrinterStageTimingsPreparationAndCacheExportStayPrivateAndRespectOptOut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "PrinterStageDiagnostics." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        let timings = Dictionary(uniqueKeysWithValues: DiagnosticPrinterFields.timingKeys.map { ($0, "3600000") })
        let transfer = timings.merging(["printer_model": "2320", "protocol_version": "4", "command_path": "d110m_v4",
            "print_task": "buffered_copies", "print_start_count": "1", "print_end_count": "1", "total": "3"]) { _, value in value }
        let expected: [(String, [String: String])] = [
            ("label.transfer_summary", transfer),
            ("label.group_transfer", ["page": "1", "quantity": "1", "total": "3", "elapsed_ms": "12345", "accepted": "true",
                "group_image_packets": "200", "group_requests": "203", "group_wire_bytes": "8000"]),
            ("label.preparation_summary", ["preparation_kind": "custom", "preparation_stage": "queue", "phase": "completed",
                "total": "3", "render_count": "0", "raster_reuse_count": "3", "preparation_elapsed_ms": "14",
                "render_elapsed_ms": "0", "approval_save_ms": "0", "queue_save_ms": "12"]),
            ("label.roll_read", ["roll_read_source": "cache", "roll_read_ms": "0"]),
            ("label.connection_ended", ["connection_end_source": "manual_disconnect", "phase": "active"])
        ]
        for (event, fields) in expected {
            log.record(event, fields.merging(["device_name": "PRIVATE_PRINTER", "roll_barcode": "PRIVATE_ROLL",
                "serial": "PRIVATE_SERIAL", "label_price": "PRIVATE_PRICE", "raw_packet": "PRIVATE_PACKET",
                "card_name": "PRIVATE_CARD", "raster": "PRIVATE_IMAGE"]) { _, value in value })
        }
        defaults.set(false, forKey: "diagnosticsEnabled")
        log.record("label.transfer_summary", transfer)
        let file = try log.exportForCopy()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_"))
        let rows = try diagnosticRows(text).filter { ($0["event"] as? String)?.hasPrefix("label.") == true }
        XCTAssertEqual(rows.compactMap { $0["event"] as? String }, expected.map { $0.0 })
        XCTAssertEqual(rows.compactMap { $0["fields"] as? [String: String] }, expected.map { $0.1 },
                       "Only bounded timing/count fields and fixed classifications may enter a diagnostic file")
    }

    func testPrinterStageExportRejectsInvalidTimingsModelsCountsAndClassifications() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "RejectedPrinterStageDiagnostics." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        var maxima = Dictionary(uniqueKeysWithValues: DiagnosticPrinterFields.timingKeys.map { ($0, 3_600_000) })
        maxima.merge(["printer_model": 65_535, "protocol_version": 255, "print_start_count": 250, "print_end_count": 250,
            "render_count": 250, "raster_reuse_count": 250, "group_image_packets": 1_000_000, "group_requests": 1_000_000,
            "group_wire_bytes": 100_000_000, "elapsed_ms": 3_600_000, "page": 250, "total": 250, "quantity": 250]) { _, value in value }
        let classifications = ["command_path", "preparation_kind", "preparation_stage", "roll_read_source", "connection_end_source"]
        for invalid in ["-1", "+1", "01", "1e3", "1.5", "NaN", "inf", "PRIVATE_VALUE", ""] {
            var fields = Dictionary(uniqueKeysWithValues: maxima.keys.map { ($0, invalid) })
            for key in classifications { fields[key] = "PRIVATE_VALUE" }
            log.record("label.transfer_summary", fields)
        }
        for (key, maximum) in maxima {
            XCTAssertTrue(DiagnosticPrinterFields.accepts(key, "0", event: "label.transfer_summary"))
            XCTAssertTrue(DiagnosticPrinterFields.accepts(key, String(maximum), event: "label.transfer_summary"))
            log.record("label.transfer_summary", [key: String(maximum + 1)])
        }
        log.record("label.preparation_summary", ["phase": "PRIVATE_VALUE", "elapsed_ms": "PRIVATE_VALUE"])
        log.record("label.group_transfer", ["accepted": "PRIVATE_VALUE"])
        let file = try log.exportForCopy()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_"))
        let rows = try diagnosticRows(text).filter { ($0["event"] as? String)?.hasPrefix("label.") == true }
        XCTAssertEqual(rows.count, 9 + maxima.count + 2)
        XCTAssertTrue(rows.allSatisfy { ($0["fields"] as? [String: String]) == [:] })
    }

    func testPrinterStageClassificationsAcceptAllSupportedPathsAndCacheDecisions() {
        let values: [String: [String]] = [
            "command_path": ["d110", "d110m_b1", "d110m_v4"],
            "preparation_kind": ["inventory", "custom"], "preparation_stage": ["preview", "queue"],
            "roll_read_source": ["cache", "read", "in_flight", "forced", "unavailable"],
            "connection_end_source": ["replace_connection", "manual_disconnect", "stop_requested", "print_cancelled",
                "required_failure", "request_cancelled"]
        ]
        for (key, allowed) in values {
            for value in allowed { XCTAssertTrue(DiagnosticPrinterFields.accepts(key, value), "\(key)=\(value)") }
        }
    }

    func testAcknowledgedImageBatchDiagnosticsKeepOnlyCountersAndRespectOptOut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "AcknowledgedImageBatchDiagnostics." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        let summary = ["write_mode": "acknowledged", "image_write_count": "6", "image_batch_count": "5",
            "image_batched_packets": "10", "image_max_write_bytes": "192", "image_batch_limit": "256",
            "image_batch_frame_limit": "16", "image_requested_byte_limit": "256", "image_pacing_ms": "50"]
        let group = ["page": "1", "quantity": "1", "total": "2", "accepted": "true",
            "group_image_packets": "3", "group_image_writes": "2", "group_wire_bytes": "75"]
        let privateFields = ["packet_hex": "PRIVATE_PACKET", "image_data": "PRIVATE_IMAGE",
            "card_name": "PRIVATE_CARD", "serial": "PRIVATE_SERIAL", "device_name": "PRIVATE_PRINTER"]
        log.record("label.transfer_summary", summary.merging(privateFields) { _, value in value })
        log.record("label.group_transfer", group.merging(privateFields) { _, value in value })
        defaults.set(false, forKey: "diagnosticsEnabled")
        log.record("label.transfer_summary", summary)
        log.record("label.group_transfer", group)
        let file = try log.exportForCopy()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_"))
        let rows = try diagnosticRows(text).filter { ($0["event"] as? String)?.hasPrefix("label.") == true }
        XCTAssertEqual(rows.count, 2, "Disabled diagnostics must not record either aggregate event")
        XCTAssertEqual(rows.first?["fields"] as? [String: String], summary)
        XCTAssertEqual(rows.last?["fields"] as? [String: String], group)
    }

    func testAcknowledgedImageBatchDiagnosticsRejectNoncanonicalAndOutOfBoundsValuesAtStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "RejectedImageBatchDiagnostics." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        let bounds: [String: UInt64] = ["image_write_count": 1_000_000, "image_batch_count": 1_000_000,
            "image_batched_packets": 1_000_000, "group_image_writes": 1_000_000,
            "image_max_write_bytes": 65_535, "image_batch_limit": 256, "image_batch_frame_limit": 16,
            "image_requested_byte_limit": 256, "image_pacing_ms": 50]
        let zero = Dictionary(uniqueKeysWithValues: bounds.keys.map { ($0, "0") })
        let maximum = Dictionary(uniqueKeysWithValues: bounds.map { ($0.key, String($0.value)) })
        log.record("label.transfer_summary", zero)
        log.record("label.transfer_summary", maximum)
        let invalid = ["-1", "+1", "01", "1e3", "1.5", "NaN", "inf", "true", "PRIVATE_VALUE", "",
                       " 1", "1\n", "18446744073709551616"]
        for value in invalid {
            for key in bounds.keys { XCTAssertFalse(DiagnosticPrinterFields.accepts(key, value)) }
            log.record("label.transfer_summary", Dictionary(uniqueKeysWithValues: bounds.keys.map { ($0, value) }))
        }
        for (key, limit) in bounds {
            XCTAssertTrue(DiagnosticPrinterFields.accepts(key, "0"))
            XCTAssertTrue(DiagnosticPrinterFields.accepts(key, String(limit)))
            XCTAssertFalse(DiagnosticPrinterFields.accepts(key, String(limit + 1)))
            log.record("label.transfer_summary", [key: String(limit + 1)])
        }
        let file = try log.exportForCopy()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_"))
        let rows = try diagnosticRows(text).filter { $0["event"] as? String == "label.transfer_summary" }
        XCTAssertEqual(rows.count, 2 + invalid.count + bounds.count)
        XCTAssertEqual(rows.first?["fields"] as? [String: String], zero)
        XCTAssertEqual(rows.dropFirst().first?["fields"] as? [String: String], maximum)
        XCTAssertTrue(rows.dropFirst(2).allSatisfy { ($0["fields"] as? [String: String]) == [:] })
    }

    func testRollReadAndDetectionResultsKeepOnlyScopedMetadataAndRespectOptOut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "RollResultDiagnostics." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        let expected: [(String, [String: String])] = [
            ("label.roll_read", ["roll_read_source": "forced", "roll_read_result": "response",
                "write_mode": "acknowledged", "roll_read_ms": "18"]),
            ("label.roll_detection", ["roll_detection_result": "matched", "roll_product_code": "06172315",
                "label_width_mm": "14.0", "label_height_mm": "40.0", "label_feed_dots": "320", "label_head_dots": "96"]),
            ("label.roll_read", ["roll_read_source": "forced", "roll_read_result": "failed",
                "roll_read_error": "printerBusy", "write_mode": "acknowledged", "roll_read_ms": "18"]),
            ("label.roll_detection", ["roll_detection_result": "unavailable"]),
            ("label.roll_read", ["roll_read_source": "read", "roll_read_result": "no_roll",
                "write_mode": "unacknowledged", "roll_read_ms": "33"])
        ]
        let privateFields = ["uid": "PRIVATE_UID", "roll_serial": "PRIVATE_SERIAL", "serial": "PRIVATE_SERIAL",
            "packet_hex": "PRIVATE_PACKET", "device_name": "PRIVATE_PRINTER", "card_name": "PRIVATE_CARD"]
        for (event, fields) in expected {
            let wrongScope = event == "label.roll_read"
                ? ["roll_detection_result": "matched", "roll_product_code": "120425109", "label_width_mm": "40.0",
                   "label_height_mm": "12.0", "label_feed_dots": "320", "label_head_dots": "96"]
                : ["roll_read_result": "response", "roll_read_error": "other"]
            log.record(event, fields.merging(privateFields) { _, value in value }
                .merging(wrongScope) { _, value in value })
        }
        defaults.set(false, forKey: "diagnosticsEnabled")
        for (event, fields) in expected { log.record(event, fields) }
        let file = try log.exportForCopy()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_"))
        let rows = try diagnosticRows(text).filter { ($0["event"] as? String)?.hasPrefix("label.roll_") == true }
        XCTAssertEqual(rows.compactMap { $0["event"] as? String }, expected.map(\.0))
        XCTAssertEqual(rows.compactMap { $0["fields"] as? [String: String] }, expected.map(\.1),
                       "Only the nonunique product SKU is retained, including its leading zero")
    }

    func testRollResultClassificationsRequireTheirExactEventAndFixedValues() {
        let fields: [(String, String, [String])] = [
            ("roll_read_result", "label.roll_read", ["response", "no_roll", "failed"]),
            ("roll_read_error", "label.roll_read", ["responseTimeout", "printerBusy", "cancelled", "unsupportedResponse",
                "notActive", "notConnected", "connectionLost", "writeFailed", "other"]),
            ("roll_detection_result", "label.roll_detection", ["matched", "unknown_product", "media_mismatch", "unavailable", "invalidated"])
        ]
        for (key, event, allowed) in fields {
            for value in allowed {
                XCTAssertTrue(DiagnosticPrinterFields.accepts(key, value, event: event))
                XCTAssertFalse(DiagnosticPrinterFields.accepts(key, value))
                XCTAssertFalse(DiagnosticPrinterFields.accepts(key, value, event: "label.transfer_summary"))
                let wrongEvent = event == "label.roll_read" ? "label.roll_detection" : "label.roll_read"
                XCTAssertFalse(DiagnosticPrinterFields.accepts(key, value, event: wrongEvent))
            }
            for value in ["", "PRIVATE_VALUE", "Response", "1", "true", "responseTimeout-PRIVATE"] {
                XCTAssertFalse(DiagnosticPrinterFields.accepts(key, value, event: event))
            }
        }
        for value in ["acknowledged", "unacknowledged"] {
            XCTAssertTrue(DiagnosticPrinterFields.accepts("write_mode", value, event: "label.roll_read"))
        }
    }

    func testRollProductsAndDimensionsRejectInvalidFormatsAndOutOfRangeValuesAtStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "RejectedRollMetadata." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        let dimensions: ([String], [String]) = (
            ["0.000001", "0.5", "12", "12.0", "99.999999", "100", "100.000000"],
            ["0", "0.000000", "-1", "+1", "01", "01.0", ".5", "12.", "12.0000001", "100.000001", "101",
             "1e1", "NaN", "inf", "１２.０", " 12", "12\n", "1,5", "1_2", "PRIVATE_DIMENSION"])
        let cases: [(String, [String], [String])] = [
            ("roll_product_code", ["0", "06172315", String(repeating: "9", count: 32)],
                ["", String(repeating: "9", count: 33), "12A34", "１２３", "١٢٣", "-1", "+1", "1e3", "1.0", " 123", "123\n", "123/456", "PRIVATE_SKU"]),
            ("label_width_mm", dimensions.0, dimensions.1),
            ("label_height_mm", dimensions.0, dimensions.1),
            ("label_feed_dots", ["1", "320", "800"], ["0", "801", "01", "+1", "-1", "1.5", "1e2", "１２", "18446744073709551616"]),
            ("label_head_dots", ["96"], ["0", "95", "97", "096", "+96", "96.0", "９６", "PRIVATE_HEAD"])
        ]
        var expected: [[String: String]] = []
        for (key, valid, invalid) in cases {
            for value in valid {
                XCTAssertTrue(DiagnosticPrinterFields.accepts(key, value, event: "label.roll_detection"))
                XCTAssertFalse(DiagnosticPrinterFields.accepts(key, value, event: "label.roll_read"))
                XCTAssertFalse(DiagnosticPrinterFields.accepts(key, value))
                log.record("label.roll_detection", [key: value]); expected.append([key: value])
            }
            for value in invalid {
                XCTAssertFalse(DiagnosticPrinterFields.accepts(key, value, event: "label.roll_detection"))
                log.record("label.roll_detection", [key: value]); expected.append([:])
            }
        }
        let allFields = ["roll_read_result": "response", "roll_read_error": "other", "roll_detection_result": "matched",
            "roll_product_code": "120425109", "label_width_mm": "40.0", "label_height_mm": "12.0",
            "label_feed_dots": "320", "label_head_dots": "96"]
        for event in ["label.transfer_summary", "web.scan_stats"] {
            log.record(event, allFields); expected.append([:])
        }
        log.record("label.roll_read", ["roll_read_result": "PRIVATE_RESULT", "roll_read_error": "PRIVATE_ERROR"])
        expected.append([:])
        log.record("label.roll_detection", ["roll_detection_result": "PRIVATE_RESULT"])
        expected.append([:])
        let file = try log.exportForCopy()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_"))
        let rows = try diagnosticRows(text).filter {
            ["label.roll_detection", "label.roll_read", "label.transfer_summary", "web.scan_stats"].contains($0["event"] as? String ?? "")
        }
        XCTAssertEqual(rows.compactMap { $0["fields"] as? [String: String] }, expected)
    }

    func testBetaIndexLimitDiagnosticsPersistOnlyBoundedCounts() throws {
        let failure = BetaAPIIndexValidationFailure(stage: .categories, reason: .tooManyEntries,
            observedCount: 257, entryLimit: 256)
        let fields = ServiceDiagnosticFields.failure(failure)
        XCTAssertEqual(fields["observed_count"], "257")
        XCTAssertEqual(fields["entry_limit"], "256")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "BetaIndexLimitDiagnostics." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        log.record("beta.index_rejected", fields.merging(["body": "PRIVATE_BODY", "api_key": "PRIVATE_KEY"]) { _, value in value })
        log.record("beta.index_rejected", ["observed_count": "PRIVATE_COUNT", "entry_limit": "1.5"])
        let exported = try log.export()
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        let text = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_"))
        let events = try text.split(separator: "\n").compactMap { line -> [String: String]? in
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return row["event"] as? String == "beta.index_rejected" ? row["fields"] as? [String: String] : nil
        }
        XCTAssertEqual(events.first?["observed_count"], "257")
        XCTAssertEqual(events.first?["entry_limit"], "256")
        XCTAssertEqual(events.last?.count, 0)
        for value in ["-1", "nan", "1.5", "1000001"] {
            XCTAssertFalse(DiagnosticScanFields.accepts("observed_count", value))
            XCTAssertFalse(DiagnosticScanFields.accepts("entry_limit", value))
        }
    }

    func testBetaIndexDiagnosticsKeepOnlyFixedFieldAndShapeClassifications() throws {
        let failure = BetaAPIIndexValidationFailure(stage: .sets, reason: .unexpectedType, shape: .array)
        let fields = ServiceDiagnosticFields.failure(failure)
        XCTAssertEqual(fields, ["domain": "beta_index", "stage": "sets", "reason": "unexpected_type", "shape": "array"])
        XCTAssertEqual(ServiceDiagnosticFields.failure(BetaAPICadenceFailure.unsupportedIndex),
            ["domain": "beta", "reason": "unsupported_index"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "BetaIndexDiagnostics." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        log.record("beta.index_rejected", fields.merging(["body": "PRIVATE_BODY", "api_key": "PRIVATE_KEY"]) { _, new in new })
        log.record("beta.index_rejected", ["shape": "PRIVATE_SHAPE"])
        let exported = try log.export()
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        let text = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_"))
        let rows = try text.split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let events = rows.filter { $0["event"] as? String == "beta.index_rejected" }
        XCTAssertEqual(events.first?["fields"] as? [String: String], fields)
        XCTAssertEqual((events.last?["fields"] as? [String: String])?.count, 0)
    }

    func testInventoryDiagnosticFailuresDistinguishResponseAuthAndPersistence() {
        XCTAssertEqual(ServiceDiagnosticFields.failure(CardShowInventoryFailure.invalidResponse),
                       ["domain": "inventory", "reason": "invalid_response"])
        XCTAssertEqual(ServiceDiagnosticFields.failure(CardShowInventoryFailure.persistenceFailed),
                       ["domain": "inventory", "reason": "persistence_failed"])
        XCTAssertEqual(ServiceDiagnosticFields.failure(CardShowInventoryFailure.signInRequired),
                       ["domain": "inventory", "reason": "sign_in_required"])
    }

    func testInventoryDiagnosticPositionsAreNumericAndRawPayloadIsDropped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "InventoryDiagnosticExport." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        log.record("card_show_inventory.validation_failed", ["phase": "stock", "stage": "row",
            "reason": "missing_sku", "record_index": "4", "page": "1", "total": "92",
            "body": "PRIVATE_ROW", "cookie": "PRIVATE_COOKIE"])
        log.record("card_show_inventory.validation_failed", ["record_index": "-1", "page": "PRIVATE_PAGE", "total": "1.5"])
        let url = try log.export()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_"))
        let entries = try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let fields = entries.filter { $0["event"] as? String == "card_show_inventory.validation_failed" }.compactMap { $0["fields"] as? [String: String] }
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields[0]["record_index"], "4"); XCTAssertEqual(fields[0]["page"], "1"); XCTAssertEqual(fields[0]["total"], "92")
        XCTAssertNil(fields[1]["record_index"]); XCTAssertNil(fields[1]["page"]); XCTAssertNil(fields[1]["total"])
    }

    func testOpportunitiesDiagnosticFailuresRemainDistinctFromExperimentalResearch() async throws {
        XCTAssertEqual(ServiceDiagnosticFields.failure(OpportunitiesFailure.notCovered), ["domain": "opportunities", "reason": "product_not_covered"])
        XCTAssertEqual(ServiceDiagnosticFields.failure(OpportunitiesFailure.skuNotCovered), ["domain": "opportunities", "reason": "exact_sku_not_covered"])
        XCTAssertEqual(ServiceDiagnosticFields.failure(OpportunitiesFailure.directAuthorizationRequired),
                       ["domain": "opportunities", "reason": "beta_credentials_rejected", "code": "401"])
        XCTAssertEqual(ServiceDiagnosticFields.failure(OpportunitiesFailure.rateLimited)["code"], "429")
        XCTAssertNil(ServiceDiagnosticFields.failure(OpportunitiesFailure.serviceUnavailable(600))["code"])
        XCTAssertEqual(ServiceDiagnosticFields.Phase.opportunitiesProduct.rawValue, "opportunities_product")
        XCTAssertEqual(ServiceDiagnosticFields.failure(OpenAPIPricingFailure.catalogUnavailable),
                       ["domain": "openapi", "reason": "catalog_mapping_missing"])
        XCTAssertEqual(ServiceDiagnosticFields.failure(OpenAPIPricingFailure.httpStatus(503))["code"], "503")
        XCTAssertEqual(ServiceDiagnosticFields.failure(BetaAPICadenceFailure.httpStatus(429)),
                       ["domain": "beta", "reason": "http_failure", "code": "429"])
        XCTAssertNil(ServiceDiagnosticFields.failure(BetaAPICadenceFailure.httpStatus(600))["code"])
    }

    func testPricingFailureDiagnosticsKeepReasonWithoutPrivateErrorContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "PricingFailureDiagnostics." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        let cases: [(Error, [String: String])] = [
            (OpenAPIPricingFailure.invalidResponse, ["domain": "openapi", "reason": "invalid_response"]),
            (OpenAPIPricingFailure.catalogUnavailable, ["domain": "openapi", "reason": "catalog_mapping_missing"]),
            (MarketPricingFailure.accessRejected(403), ["domain": "market", "reason": "access_rejected", "code": "403"]),
            (URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_NETWORK_DETAILS"]),
             ["domain": "network", "reason": "transport_error", "code": "-1009"])
        ]
        for (error, fields) in cases {
            log.record("pricing.failed", ServiceDiagnosticFields.failure(error))
            var editor = ServiceDiagnosticFields.failure(error); editor["phase"] = "editor"
            log.record("inventory.pricing_failed", editor)
            XCTAssertEqual(ServiceDiagnosticFields.failure(error), fields)
        }
        let file = try log.exportForCopy()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_NETWORK_DETAILS"))
        let rows = try diagnosticRows(text).filter { ["pricing.failed", "inventory.pricing_failed"].contains($0["event"] as? String ?? "") }
        let expected = cases.flatMap { _, fields in [fields, fields.merging(["phase": "editor"]) { _, value in value }] }
        XCTAssertEqual(rows.compactMap { $0["fields"] as? [String: String] }, expected)
        XCTAssertNil(ServiceDiagnosticFields.failure(MarketPricingFailure.accessRejected(600))["code"])
    }

    func testResearchDiagnosticExportKeepsMethodAndStatusWithoutCredentialContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "ResearchDiagnosticExport." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        var fields = ServiceDiagnosticFields.failure(ResearchFailure.directAuthorizationRequired)
        fields["method"] = "direct"; fields["phase"] = "research_meta"
        log.record("research.connection_check_failed", fields)
        log.record("research.connection_check_failed", ["method": "PRIVATE_KEY", "token": "PRIVATE_TOKEN", "url": "https://private.example"])
        let exported = try log.export()
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        let text = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_")); XCTAssertFalse(text.contains("private.example"))
        let rows = try text.split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let failures = rows.filter { $0["event"] as? String == "research.connection_check_failed" }
        let saved = try XCTUnwrap(failures.first?["fields"] as? [String: String])
        XCTAssertEqual(saved["method"], "direct"); XCTAssertEqual(saved["code"], "401")
        XCTAssertEqual(saved["phase"], "research_meta"); XCTAssertEqual(saved["reason"], "research_credentials_rejected")
        XCTAssertEqual((failures.last?["fields"] as? [String: String])?.count, 0)
    }

    func testServiceFailureClassificationSeparatesResearchFromCertificateSetup() async throws {
        XCTAssertEqual(ServiceDiagnosticFields.failure(ResearchFailure.notConfigured), ["domain": "research", "reason": "server_not_configured"])
        XCTAssertEqual(ServiceDiagnosticFields.failure(PSACertificateFailure.notConfigured), ["domain": "psa", "reason": "adapter_not_configured"])
        XCTAssertEqual(ServiceDiagnosticFields.failure(ResearchFailure.accessDenied)["code"], "403")
        XCTAssertEqual(ServiceDiagnosticFields.failure(ResearchFailure.authorizationRequired)["reason"], "device_token_rejected")
        XCTAssertEqual(ServiceDiagnosticFields.failure(ResearchConnectionFailure.storage)["reason"], "keychain_unavailable")
        XCTAssertNil(ServiceDiagnosticFields.failure(ResearchFailure.serviceUnavailable(99))["code"])
        XCTAssertNil(ServiceDiagnosticFields.failure(ResearchFailure.serviceUnavailable(600))["code"])
    }

    func testServiceFailureClassificationDoesNotExposeUnknownErrorDescriptions() async throws {
        let secret = "PRIVATE_CERT_KEY_AND_URL"
        let error = NSError(domain: secret, code: 123, userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLErrorKey: secret])
        let fields = ServiceDiagnosticFields.failure(error)
        XCTAssertEqual(fields, ["domain": "request", "reason": "unclassified_failure"])
        XCTAssertFalse(String(describing: fields).contains(secret))
    }

    private func envelope(_ values: [String: Any] = [:]) throws -> TCGBridgeEnvelope {
        var object: [String: Any] = ["nonce": "test", "kind": "diagnostic", "event": "scan_stats"]
        object.merge(values) { _, value in value }
        return try JSONDecoder().decode(TCGBridgeEnvelope.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testCameraWorkloadKeepsRequestedRateSeparateFromConfirmedCaptureRate() throws {
        var wire = try envelope(["event": "camera_workload", "resourceMode": "reduced", "captureState": "live",
            "targetFPS": 10, "processingActive": true, "constraintState": "pending"])
        let pending = try XCTUnwrap(ScannerDiagnosticRecord.validated(wire))
        XCTAssertEqual(pending.event, "web.camera_workload")
        XCTAssertEqual(pending.sampleEvery, 0, "State transitions must not wait for sampled scan statistics")
        XCTAssertEqual(pending.fields, ["resource_mode": "reduced", "capture_state": "live", "target_fps": "10",
            "processing_active": "true", "constraint_state": "pending"])
        XCTAssertNil(pending.fields["camera_fps"], "A requested limit is not proof of an applied camera rate")

        wire.cameraFPS = 9.9761; wire.constraintState = "applied"
        let applied = try XCTUnwrap(ScannerDiagnosticRecord.validated(wire))
        XCTAssertEqual(applied.fields["target_fps"], "10")
        XCTAssertEqual(applied.fields["camera_fps"], "9.976")
        XCTAssertEqual(applied.fields["constraint_state"], "applied")

        wire.cameraFPS = 30; wire.constraintState = "unsupported"
        let unsupported = try XCTUnwrap(ScannerDiagnosticRecord.validated(wire))
        XCTAssertEqual(unsupported.fields["target_fps"], "10")
        XCTAssertEqual(unsupported.fields["camera_fps"], "30.000",
                       "Diagnostics retain a measured rate even when the camera did not honor the target")
        XCTAssertEqual(unsupported.fields["constraint_state"], "unsupported")
    }

    func testCameraWorkloadRecognizesIdleReviewManualAndStoppedStatesWithoutInventingCameraMeasurements() throws {
        let scenarios: [(String, String, Double, Bool, String)] = [
            ("normal", "live", 30, true, "applied"),
            ("reduced", "review", 10, false, "pending"),
            ("reduced", "manual", 1, false, "applied"),
            ("normal", "prompt", 1, false, "failed"),
            ("cooling", "stopped", 0, false, "inactive")
        ]
        for (mode, state, target, processing, constraint) in scenarios {
            let record = try XCTUnwrap(ScannerDiagnosticRecord.validated(envelope([
                "event": "camera_workload", "resourceMode": mode, "captureState": state, "targetFPS": target,
                "processingActive": processing, "constraintState": constraint])))
            XCTAssertEqual(record.fields, ["resource_mode": mode, "capture_state": state,
                "target_fps": String(Int(target)), "processing_active": String(processing), "constraint_state": constraint])
            XCTAssertNil(record.fields["camera_fps"])
        }
        for measured in [0.0, 240.0] {
            let record = try XCTUnwrap(ScannerDiagnosticRecord.validated(envelope([
                "event": "camera_workload", "cameraFPS": measured])))
            XCTAssertEqual(record.fields["camera_fps"], measured == 0 ? "0.000" : "240.000")
        }
    }

    func testCameraWorkloadDropsFreeformStatesAndNonfiniteOutOfRangeOrUnsupportedRates() throws {
        var wire = try envelope(["event": "camera_workload", "resourceMode": "PRIVATE_MODE",
            "captureState": "PRIVATE_CARD", "constraintState": "PRIVATE_DEVICE", "message": "PRIVATE_CONTENT"])
        for (target, camera) in [(-1.0, -1.0), (2, 240.001), (29.97, 241),
                                  (.infinity, .infinity), (.nan, .nan)] {
            wire.targetFPS = target; wire.cameraFPS = camera
            let record = try XCTUnwrap(ScannerDiagnosticRecord.validated(wire))
            XCTAssertTrue(record.fields.isEmpty)
        }
    }

    func testCameraWorkloadWireFieldsCannotBeSmuggledThroughOtherDiagnosticEvents() throws {
        for event in ["scan_stats", "pack_ready", "startup_failed", "recognition_snapshot"] {
            let record = try XCTUnwrap(ScannerDiagnosticRecord.validated(envelope([
                "event": event, "resourceMode": "reduced", "captureState": "manual", "targetFPS": 1,
                "cameraFPS": 30, "processingActive": false, "constraintState": "applied",
                "resource_mode": "PRIVATE_MODE", "camera_fps": "PRIVATE_VALUE"])))
            XCTAssertTrue(record.fields.isEmpty, "Workload fields belong only to camera_workload, not \(event)")
        }
    }

    func testCameraWorkloadStorageIndependentlyValidatesRedactsAndRespectsRecordingOptOut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "CameraWorkloadDiagnostics." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        let expected = ["resource_mode": "reduced", "capture_state": "manual", "target_fps": "1",
            "camera_fps": "1.000", "processing_active": "false", "constraint_state": "applied"]
        log.record("web.camera_workload", expected.merging(["image": "PRIVATE_IMAGE", "card_name": "PRIVATE_CARD",
            "device_name": "PRIVATE_DEVICE", "body": "PRIVATE_RESPONSE", "token": "PRIVATE_TOKEN",
            "resourceMode": "PRIVATE_WIRE_MODE"]) { _, value in value })
        log.record("web.camera_workload", ["resource_mode": "PRIVATE_MODE", "capture_state": "PRIVATE_STATE",
            "constraint_state": "PRIVATE_CONSTRAINT", "target_fps": "30.0", "camera_fps": "241",
            "processing_active": "1"])
        for value in ["-1", "+1", "nan", "NaN", "infinity", "241", "240.001", "1e1", "1E1", " 1", "1 ",
                      "1.0000", "01", "00", "01.2", "1.", ".1", "1\n"] {
            XCTAssertFalse(DiagnosticScanFields.accepts("camera_fps", value), "Invalid measured rate: \(value)")
        }
        for value in ["-1", "+1", "10.0", "1e1", " 10", "10 ", "01", "2", "29.97", "PRIVATE_RATE"] {
            XCTAssertFalse(DiagnosticScanFields.accepts("target_fps", value), "Invalid target: \(value)")
        }
        for value in ["0", "0.000", "1", "1.0", "10.12", "30.000", "239.999", "240", "240.000"] {
            XCTAssertTrue(DiagnosticScanFields.accepts("camera_fps", value))
        }
        for value in ["0", "1", "10", "30"] {
            XCTAssertTrue(DiagnosticScanFields.accepts("target_fps", value))
        }

        let url = try log.export()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.contains("PRIVATE_"))
        let samples = try diagnosticRows(content).filter { $0["event"] as? String == "web.camera_workload" }
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.first?["fields"] as? [String: String], expected)
        XCTAssertEqual(samples.last?["fields"] as? [String: String], [:])

        let current = directory.appendingPathComponent("current.jsonl")
        let saved = try Data(contentsOf: current)
        defaults.set(false, forKey: "diagnosticsEnabled")
        log.record("web.camera_workload", expected)
        XCTAssertEqual(try Data(contentsOf: current), saved, "Opting out prevents even sanitized workload records")
    }

    func testCameraGeometryAndLightingDecodeIntoBoundedScalarFields() async throws {
        let wire = try envelope(["solid": true, "tracked": false, "borderRetry": true, "borderRetained": false, "scanStage": "full", "rawQuads": 12,
            "rejectedQuads": 3, "candidateQuads": 4, "selectedBase": 1, "quadSource": "selected",
            "quadAspect": 0.75, "quadArea": 0.51235, "quadSupport": 0.87, "meanLuma": 64.5,
            "lumaStd": 19.25, "matchDistance": 8.5, "matchGap": 4.75, "frames": 2, "backend": "worker"])
        let record = try XCTUnwrap(ScannerDiagnosticRecord.validated(wire))
        XCTAssertEqual(record.event, "web.scan_stats"); XCTAssertEqual(record.sampleEvery, 5)
        XCTAssertEqual(record.fields, ["solid": "true", "tracked": "false", "border_retry": "true", "border_retained": "false", "scan_stage": "full", "raw_quads": "12",
            "rejected_quads": "3", "candidate_quads": "4", "selected_base": "1", "quad_source": "selected",
            "quad_aspect": "0.750", "quad_area": "0.512", "quad_support": "0.870", "mean_luma": "64.500",
            "luma_std": "19.250", "match_distance": "8.500", "match_gap": "4.750", "frames": "2", "backend": "worker"])
    }

    func testMissingQuadAndKnownZeroMeasurementsRemainDistinctFromMissingFields() async throws {
        let record = try XCTUnwrap(ScannerDiagnosticRecord.validated(envelope(["solid": false, "scanStage": "none",
            "quadSource": "none", "candidateQuads": 0, "rawQuads": 0, "meanLuma": 0, "lumaStd": 0])))
        XCTAssertEqual(record.fields["solid"], "false"); XCTAssertEqual(record.fields["candidate_quads"], "0")
        XCTAssertEqual(record.fields["mean_luma"], "0.000"); XCTAssertEqual(record.fields["luma_std"], "0.000")
        XCTAssertNil(record.fields["quad_aspect"]); XCTAssertNil(record.fields["selected_base"])
    }

    func testNonfiniteOutOfRangeAndFractionalCountsAreDropped() async throws {
        var wire = try envelope()
        wire.rawQuads = .nan; wire.rejectedQuads = -1; wire.candidateQuads = 2.5; wire.selectedBase = 1_000_001
        wire.quadAspect = 1.001; wire.quadArea = -.infinity; wire.quadSupport = 2
        wire.meanLuma = 256; wire.lumaStd = -0.1; wire.matchDistance = .infinity; wire.matchGap = 101
        wire.scanMS = .nan; wire.captureMS = -1; wire.elapsedMS = 86_400_001; wire.frames = -1
        let record = try XCTUnwrap(ScannerDiagnosticRecord.validated(wire))
        XCTAssertTrue(record.fields.isEmpty)
    }

    func testScanAndStartupStagesUseIndependentEnumNamespaces() async throws {
        let scan = try XCTUnwrap(ScannerDiagnosticRecord.validated(envelope(["stage": "one", "scanStage": "quick"])))
        XCTAssertNil(scan.fields["stage"]); XCTAssertEqual(scan.fields["scan_stage"], "quick")
        let startup = try XCTUnwrap(ScannerDiagnosticRecord.validated(envelope(["event": "startup_failed", "stage": "camera",
            "scanStage": "full", "solid": true, "meanLuma": 40, "quadSource": "selected"])))
        XCTAssertEqual(startup.fields["stage"], "camera")
        XCTAssertNil(startup.fields["scan_stage"]); XCTAssertNil(startup.fields["mean_luma"])
        XCTAssertNil(startup.fields["solid"]); XCTAssertNil(startup.fields["quad_source"])
    }

    func testUntrustedEnumsEventNamesAndRecognitionPayloadsCannotBecomeDiagnostics() async throws {
        let wire = try envelope(["stage": "PRIVATE_CARD", "scanStage": "full.private", "quadSource": "PRIVATE_REF",
            "backend": "PRIVATE_PROVIDER", "errorKind": "PRIVATE_ERROR", "message": "PRIVATE_MESSAGE",
            "capturedImageBase64": "PRIVATE_IMAGE", "card_name": "PRIVATE_CARD", "token": "PRIVATE_TOKEN"])
        let record = try XCTUnwrap(ScannerDiagnosticRecord.validated(wire))
        XCTAssertTrue(record.fields.isEmpty)
        XCTAssertNil(ScannerDiagnosticRecord.validated(try envelope(["event": "scan_stats.PRIVATE_TOKEN"])))
        XCTAssertNil(ScannerDiagnosticRecord.validated(try envelope(["kind": "scan"])))
    }

    func testSettledSnapshotIsRecordedWithoutStatsSamplingDelay() async throws {
        let record = try XCTUnwrap(ScannerDiagnosticRecord.validated(envelope(["event": "recognition_snapshot",
            "scanStage": "one", "solid": true, "selectedBase": 0, "quadSource": "selected", "sampleAgeMS": 0])))
        XCTAssertEqual(record.event, "web.recognition_snapshot"); XCTAssertEqual(record.sampleEvery, 0)
        XCTAssertEqual(record.fields["scan_stage"], "one"); XCTAssertEqual(record.fields["selected_base"], "0")
        XCTAssertEqual(record.fields["sample_age_ms"], "0")
    }

    func testManualIssueMarkerKeepsOnlyKnownReasonAndBoundedSampleAge() async throws {
        for reason in ["top_loader", "dark_card", "wrong_border"] {
            let record = try XCTUnwrap(ScannerDiagnosticRecord.validated(envelope(["event": "scan_issue", "issueReason": reason,
                "sampleAgeMS": 1234, "quadSource": "detected", "solid": false, "quadAspect": 0.75])))
            XCTAssertEqual(record.event, "web.scan_issue"); XCTAssertEqual(record.sampleEvery, 0)
            XCTAssertEqual(record.fields["reason"], reason); XCTAssertEqual(record.fields["sample_age_ms"], "1234")
            XCTAssertEqual(record.fields["quad_aspect"], "0.750")
        }
        var invalid = try envelope(["event": "scan_issue", "issueReason": "PRIVATE_CARD"])
        for age in [-1.0, 600_001, 2.5, .infinity, .nan] {
            invalid.sampleAgeMS = age
            let record = try XCTUnwrap(ScannerDiagnosticRecord.validated(invalid))
            XCTAssertNil(record.fields["reason"]); XCTAssertNil(record.fields["sample_age_ms"])
        }
        let unrelated = try XCTUnwrap(ScannerDiagnosticRecord.validated(envelope(["event": "pack_ready", "issueReason": "top_loader", "sampleAgeMS": 5])))
        XCTAssertNil(unrelated.fields["reason"]); XCTAssertNil(unrelated.fields["sample_age_ms"])
        let stalePayloads: [[String: Any]] = [["sampleAgeMS": 15_001], [:]]
        for values in stalePayloads {
            var payload: [String: Any] = ["event": "scan_issue", "issueReason": "top_loader", "quadAspect": 0.75, "solid": false]
            payload.merge(values) { _, value in value }
            let stale = try XCTUnwrap(ScannerDiagnosticRecord.validated(envelope(payload)))
            XCTAssertEqual(stale.fields["reason"], "top_loader")
            XCTAssertNil(stale.fields["quad_aspect"]); XCTAssertNil(stale.fields["solid"])
        }
    }

    func testLegacyStartupCacheAndTimingFieldsStillPassValidation() async throws {
        let record = try XCTUnwrap(ScannerDiagnosticRecord.validated(envelope(["event": "pack_ready", "stage": "pack",
            "elapsedMS": 543.9, "downloadedBytes": 0, "cachedShards": 426, "cacheBackend": "native",
            "cacheState": "ok", "cacheSource": "cache", "storagePersisted": true])))
        XCTAssertEqual(record.fields, ["stage": "pack", "elapsed_ms": "543", "downloaded_bytes": "0", "cached_shards": "426",
            "cache_backend": "native", "cache": "ok", "source": "cache", "persisted": "true"])
        XCTAssertEqual(record.sampleEvery, 0)
    }

    func testDiagnosticExportPreservesGeometryAndDropsArbitraryTextAtStorageBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "ScannerDiagnosticsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        let record = try XCTUnwrap(ScannerDiagnosticRecord.validated(envelope(["scanStage": "full", "quadAspect": 0.75,
            "quadArea": 0.45, "meanLuma": 37, "solid": false, "candidateQuads": 0])))
        log.record(record.event, record.fields)
        for _ in 0..<3 { log.record(record.event, record.fields, sampleEvery: 5) }
        log.record("web.scan_stats", ["scan_stage": "PRIVATE_CARD", "quad_source": "PRIVATE_REF", "mean_luma": "PRIVATE_TOKEN",
            "quad_area": "2", "quad_support": "nan", "candidate_quads": "2.5", "solid": "PRIVATE_BOOL", "border_retry": "PRIVATE_BOOL", "border_retained": "1", "image": "PRIVATE_IMAGE"])
        let url = try log.export()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.contains("PRIVATE_"))
        let rows = try content.split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let samples = rows.filter { $0["event"] as? String == "web.scan_stats" }
        XCTAssertEqual(samples.count, 3, "The repeated sampled calls produce only one extra record")
        let fields = try XCTUnwrap(samples.first?["fields"] as? [String: String])
        XCTAssertEqual(fields["quad_aspect"], "0.750"); XCTAssertEqual(fields["mean_luma"], "37.000")
        XCTAssertEqual(fields["solid"], "false"); XCTAssertEqual(fields["candidate_quads"], "0")
        XCTAssertEqual((samples.last?["fields"] as? [String: String])?.count, 0)
    }
}
