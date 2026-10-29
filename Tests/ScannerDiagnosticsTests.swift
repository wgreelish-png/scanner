import XCTest
@testable import CardShowScanner

@MainActor final class ScannerDiagnosticsTests: XCTestCase {
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
