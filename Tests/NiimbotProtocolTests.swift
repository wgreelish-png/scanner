import Foundation
import XCTest
@testable import CardShowScanner

final class NiimbotProtocolTests: XCTestCase {
    /// Synthetic identifiers only. The default has the same 40-byte field
    /// layout as the reported discrete-label reply, without any personal data.
    private func syntheticRFIDPayload(product: String = "TESTSKU84", serial: String = "TEST000000000001",
                                      total: Int = 84, used: Int = 9, type: UInt8 = 1,
                                      tail: Data = Data(), uid: [UInt8] = [0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80]) -> Data {
        let productBytes = Array(product.utf8), serialBytes = Array(serial.utf8)
        let counts = [UInt8((total >> 8) & 0xff), UInt8(total & 0xff),
                      UInt8((used >> 8) & 0xff), UInt8(used & 0xff), type]
        var result = Data(uid)
        result.append(UInt8(productBytes.count))
        result.append(contentsOf: productBytes)
        result.append(UInt8(serialBytes.count))
        result.append(contentsOf: serialBytes)
        result.append(contentsOf: counts)
        result.append(tail)
        return result
    }

    func testRFIDCounterSnapshotParsesSyntheticFortyBytePayloadAsSeventyFiveRemaining() throws {
        let payload = syntheticRFIDPayload()
        XCTAssertEqual(payload.count, 40)
        let estimate = try XCTUnwrap(NiimbotProtocol.rollEstimate(.init(command: 0x1b, data: payload)))
        XCTAssertEqual(estimate.productCode, "TESTSKU84")
        XCTAssertEqual(estimate.totalLabels, 84)
        XCTAssertEqual(estimate.usedLabels, 9)
        XCTAssertEqual(estimate.remainingLabels, 75)
        XCTAssertEqual(estimate.labelType, 1)
    }

    func testRFIDCountersAreBigEndianAndTrueExhaustionRemainsDistinctFromUnknown() throws {
        let estimate = try XCTUnwrap(NiimbotProtocol.rollEstimate(.init(command: 0x1b,
            data: syntheticRFIDPayload(total: 0x1234, used: 0x0102))))
        XCTAssertEqual(estimate.totalLabels, 4_660)
        XCTAssertEqual(estimate.usedLabels, 258)
        XCTAssertEqual(estimate.remainingLabels, 4_402)
        for total in [1, 84, 65_535] {
            let exhausted = try XCTUnwrap(NiimbotProtocol.rollEstimate(.init(command: 0x1b,
                data: syntheticRFIDPayload(total: total, used: total))))
            XCTAssertEqual(exhausted.remainingLabels, 0)
        }
        let unused = try XCTUnwrap(NiimbotProtocol.rollEstimate(.init(command: 0x1b,
            data: syntheticRFIDPayload(used: 0))))
        XCTAssertEqual(unused.remainingLabels, 84)
        for (total, used) in [(0, 0), (0, 1), (84, 85), (1, 65_535)] {
            XCTAssertThrowsError(try NiimbotProtocol.rollEstimate(.init(command: 0x1b,
                data: syntheticRFIDPayload(total: total, used: used)))) {
                XCTAssertEqual($0 as? LabelPrinterIssue, .unsupportedResponse)
            }
        }
    }

    func testRFIDOneByteNoTagRepliesNeverInventAnEmptyRoll() throws {
        for value in [UInt8(0), 1, 0xff] {
            XCTAssertNil(try NiimbotProtocol.rollEstimate(.init(command: 0x1b, data: Data([value]))))
        }
        XCTAssertThrowsError(try NiimbotProtocol.rollEstimate(.init(command: 0x1b, data: Data())))
        XCTAssertThrowsError(try NiimbotProtocol.rollEstimate(.init(command: 0x00, data: Data([0]))))
    }

    func testRFIDOnlyDiscreteSupportedMediaCanEstablishAnEstimatedLabelCount() throws {
        for type in [UInt8(1), 5] {
            let estimate = try XCTUnwrap(NiimbotProtocol.rollEstimate(.init(command: 0x1b,
                data: syntheticRFIDPayload(type: type))))
            XCTAssertEqual(estimate.labelType, type)
            XCTAssertEqual(estimate.remainingLabels, 75)
        }
        for type in [UInt8(0), 2, 3, 4, 6, 10, 11, 0xff] {
            XCTAssertThrowsError(try NiimbotProtocol.rollEstimate(.init(command: 0x1b,
                data: syntheticRFIDPayload(type: type))))
        }
    }

    func testRFIDOptionalCapacityAndSecondUIDHaveExactSupportedTailLengths() throws {
        let capacity = Data([0, 100])
        let secondUID = Data([0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7])
        for tail in [Data(), capacity, capacity + secondUID] {
            let estimate = try XCTUnwrap(NiimbotProtocol.rollEstimate(.init(command: 0x1b,
                data: syntheticRFIDPayload(tail: tail))))
            XCTAssertEqual(estimate.totalLabels, 84)
            XCTAssertEqual(estimate.remainingLabels, 75, "Optional capacity never replaces the reported total/used counters")
        }
        for length in [1, 3, 4, 5, 6, 7, 8, 9, 11] {
            XCTAssertThrowsError(try NiimbotProtocol.rollEstimate(.init(command: 0x1b,
                data: syntheticRFIDPayload(tail: Data(repeating: 0, count: length)))))
        }
    }

    func testRFIDRejectsEveryTruncatedTaggedPayloadAndWrongOrOversizedPackets() throws {
        let payload = syntheticRFIDPayload()
        for length in 0..<payload.count where length != 1 {
            XCTAssertThrowsError(try NiimbotProtocol.rollEstimate(.init(command: 0x1b,
                data: Data(payload.prefix(length)))), "Truncated tagged payload length: \(length)")
        }
        XCTAssertThrowsError(try NiimbotProtocol.rollEstimate(.init(command: 0x1d, data: payload)))
        XCTAssertThrowsError(try NiimbotProtocol.rollEstimate(.init(command: 0x1b,
            data: Data(repeating: 0, count: 256))))
    }

    func testRFIDVStringsRequireBoundedPrintableASCIIWithoutOverreading() throws {
        for (product, serial) in [("", "TEST000000000001"), ("TESTSKU84", ""),
                                  ("TEST\tSKU", "TEST000000000001"), ("TESTSKU84", "TEST\u{0}000000000001"),
                                  ("TEST\u{7f}SKU", "TEST000000000001"), ("TéstSKU84", "TEST000000000001"),
                                  (String(repeating: "X", count: 128), "TEST000000000001")] {
            XCTAssertThrowsError(try NiimbotProtocol.rollEstimate(.init(command: 0x1b,
                data: syntheticRFIDPayload(product: product, serial: serial))))
        }
        for length in [UInt8(127), 255] {
            var overrun = syntheticRFIDPayload()
            overrun[8] = length
            XCTAssertThrowsError(try NiimbotProtocol.rollEstimate(.init(command: 0x1b, data: overrun)))
        }
        let boundary = syntheticRFIDPayload(product: String(repeating: "X", count: 127),
                                            serial: String(repeating: "S", count: 113))
        XCTAssertEqual(boundary.count, 255)
        XCTAssertEqual(try NiimbotProtocol.rollEstimate(.init(command: 0x1b, data: boundary))?.remainingLabels, 75)
    }

    func testRFIDSnapshotDoesNotRetainUniqueTagOrRollSerialIdentifiers() throws {
        let first = try NiimbotProtocol.rollEstimate(.init(command: 0x1b, data: syntheticRFIDPayload()))
        let second = try NiimbotProtocol.rollEstimate(.init(command: 0x1b,
            data: syntheticRFIDPayload(serial: "TEST000000000002", uid: Array(repeating: 0xee, count: 8))))
        XCTAssertEqual(first, second, "Only product and discrete counters belong in the transient estimate")
    }

    @MainActor func testRFIDReadMakesExactlyOneReadOnlyRequestWithoutPrintingOrChangingMedia() async throws {
        var requests: [NiimbotRequest] = []
        let estimate = try await NiimbotD110Session.readRollEstimate { request in
            requests.append(request)
            return .init(command: 0x1b, data: self.syntheticRFIDPayload())
        }
        XCTAssertEqual(estimate?.remainingLabels, 75)
        XCTAssertEqual(requests, [NiimbotRequest(0x1a, [1], response: 0x1b)])
        XCTAssertEqual(try NiimbotProtocol.encode(command: requests[0].command, data: requests[0].data),
                       Data([0x55, 0x55, 0x1a, 1, 1, 0x1a, 0xaa, 0xaa]))
        XCTAssertFalse(requests[0].beginsPrint)
        XCTAssertFalse(requests[0].requiresTrue)
    }

    @MainActor func testRFIDReadReturnsNoTagAndDoesNotRetryUnavailableOrMalformedReplies() async throws {
        var noTagRequests = 0
        let absent = try await NiimbotD110Session.readRollEstimate { _ in
            noTagRequests += 1
            return .init(command: 0x1b, data: Data([0]))
        }
        XCTAssertNil(absent)
        XCTAssertEqual(noTagRequests, 1)
        let replies: [NiimbotPacket?] = [nil, .init(command: 0x00, data: Data([0])),
                                       .init(command: 0x1b, data: Data([0, 0]))]
        for reply in replies {
            var requests = 0
            do {
                _ = try await NiimbotD110Session.readRollEstimate { _ in requests += 1; return reply }
                XCTFail("An unavailable or malformed RFID read must remain unknown")
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .unsupportedResponse) }
            XCTAssertEqual(requests, 1)
        }
        var attempts = 0
        do {
            _ = try await NiimbotD110Session.readRollEstimate { _ in
                attempts += 1
                throw LabelPrinterIssue.responseTimeout
            }
            XCTFail("An optional read timeout must propagate without retry")
        } catch { XCTAssertEqual(error as? LabelPrinterIssue, .responseTimeout) }
        XCTAssertEqual(attempts, 1)
    }

    func testRFIDIdentityRemainsUsableWhenItsOptionalCountersAreInvalid() throws {
        for (total, used) in [(0, 0), (0, 1), (84, 85)] {
            let info = try XCTUnwrap(NiimbotProtocol.rollInfo(.init(command: 0x1b,
                data: syntheticRFIDPayload(product: "120425109", total: total, used: used))))
            XCTAssertEqual(info.productCode, "120425109")
            XCTAssertEqual(info.labelType, 1)
            XCTAssertNil(info.estimate, "Invalid counters cannot fabricate an empty roll")
            let product = try XCTUnwrap(info.matchedProduct(in: .shared))
            XCTAssertEqual(product.width, 40)
            XCTAssertEqual(product.height, 12)
            XCTAssertThrowsError(try NiimbotProtocol.rollEstimate(.init(command: 0x1b,
                data: syntheticRFIDPayload(product: "120425109", total: total, used: used))))
        }
    }

    func testRFIDCatalogMatchPreservesLeadingZerosAndRequiresTheSameMediaType() throws {
        let info = try XCTUnwrap(NiimbotProtocol.rollInfo(.init(command: 0x1b,
            data: syntheticRFIDPayload(product: "02242207"))))
        XCTAssertEqual(info.matchedProduct(in: .shared)?.code, "02242207")
        let mismatched = NiimbotRollInfo(productCode: "02242207", totalLabels: 84, usedLabels: 9, labelType: 5)
        XCTAssertNil(mismatched.matchedProduct(in: .shared), "A known code cannot overrule contradictory chip media")
        let unknown = NiimbotRollInfo(productCode: "UNKNOWNTEST123", totalLabels: 84, usedLabels: 9, labelType: 1)
        XCTAssertNil(unknown.matchedProduct(in: .shared))
        XCTAssertEqual(unknown.estimate?.remainingLabels, 75, "A catalog miss does not erase a valid counter")
        let unsupported = NiimbotRollInfo(productCode: "02242207", totalLabels: 84, usedLabels: 9, labelType: 2)
        XCTAssertNil(unsupported.matchedProduct(in: .shared)); XCTAssertNil(unsupported.estimate)
    }

    func testRFIDIdentitySnapshotStillDiscardsUniqueTagAndRollSerial() throws {
        let first = try NiimbotProtocol.rollInfo(.init(command: 0x1b,
            data: syntheticRFIDPayload(product: "02242207", total: 0, used: 0)))
        let second = try NiimbotProtocol.rollInfo(.init(command: 0x1b,
            data: syntheticRFIDPayload(product: "02242207", serial: "TEST000000000002", total: 0, used: 0,
                                       uid: Array(repeating: 0xee, count: 8))))
        XCTAssertEqual(first, second)
    }

    @MainActor func testRFIDMetadataReadUsesOneRequestWithoutASecondCounterLookup() async throws {
        var requests: [NiimbotRequest] = []
        let info = try await NiimbotD110Session.readRollInfo { request in
            requests.append(request)
            return .init(command: 0x1b, data: self.syntheticRFIDPayload(product: "120425109", total: 0, used: 0))
        }
        XCTAssertEqual(requests, [NiimbotRequest(0x1a, [1], response: 0x1b)])
        XCTAssertEqual(info?.productCode, "120425109")
        XCTAssertNil(info?.estimate)
        var absentRequests = 0
        let absent = try await NiimbotD110Session.readRollInfo { _ in
            absentRequests += 1
            return .init(command: 0x1b, data: Data([0]))
        }
        XCTAssertNil(absent); XCTAssertEqual(absentRequests, 1)
    }

    func testDynamicCatalogFeedLengthsRetainTheBoundedNinetySixDotHead() throws {
        for height in [176, 200, 224, 241, 352, 432, 600, 800] {
            let raster = LabelRaster(width: 96, height: height, data: Data(repeating: 0xff, count: height * 12))
            for identity in [NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34])),
                             NiimbotD110Identity(modelID: 2320, protocolVersion: 4, firmwareBytes: Data([4, 23]))] {
                let requests = try NiimbotProtocol.printRequests(for: raster, identity: identity, paperMode: .transparent)
                let size = try XCTUnwrap(requests.first { $0.command == 0x13 })
                XCTAssertEqual(Array(size.data.prefix(4)), [UInt8(height >> 8), UInt8(height & 0xff), 0, 96])
                XCTAssertEqual(requests.first { $0.command == 0x23 }?.data, Data([5]))
            }
        }
        for height in [0, 801] {
            XCTAssertThrowsError(try NiimbotProtocol.printRequests(for: .init(width: 96, height: height,
                data: Data(repeating: 0xff, count: max(0, height) * 12))))
        }
    }

    func testFirstPermissionSearchSurvivesPromptAndResumesOnlyOnce() {
        var intent = NiimbotPermissionSearchIntent()
        XCTAssertFalse(intent.preserveOnInactive(permissionUndetermined: true))
        intent.request(permissionUndetermined: true)
        XCTAssertTrue(intent.preserveOnInactive(permissionUndetermined: true))
        // The app can become active before CoreBluetooth reports the decision.
        XCTAssertFalse(intent.resumeWhenActive(permissionGranted: false, permissionUndetermined: true))
        XCTAssertTrue(intent.awaitingDecision)
        XCTAssertTrue(intent.resumeWhenActive(permissionGranted: true, permissionUndetermined: false))
        XCTAssertFalse(intent.resumeWhenActive(permissionGranted: true, permissionUndetermined: false))
        XCTAssertFalse(intent.preserveOnInactive(permissionUndetermined: false))
    }

    func testCancelledOrDeniedPermissionSearchCannotResumeAfterGrant() {
        var intent = NiimbotPermissionSearchIntent()
        intent.request(permissionUndetermined: true)
        intent.cancel() // Closing the view or explicit Stop cancels Search.
        XCTAssertFalse(intent.resumeWhenActive(permissionGranted: true, permissionUndetermined: false))
        intent.request(permissionUndetermined: true)
        XCTAssertFalse(intent.resumeWhenActive(permissionGranted: false, permissionUndetermined: false))
        XCTAssertFalse(intent.awaitingDecision)
        XCTAssertFalse(intent.resumeWhenActive(permissionGranted: true, permissionUndetermined: false))
    }

    func testOrdinarySearchInactivityHasNoPermissionResumeIntent() {
        var intent = NiimbotPermissionSearchIntent()
        intent.request(permissionUndetermined: false)
        XCTAssertFalse(intent.preserveOnInactive(permissionUndetermined: false))
        XCTAssertFalse(intent.resumeWhenActive(permissionGranted: true, permissionUndetermined: false))
        intent.request(permissionUndetermined: true)
        XCTAssertFalse(intent.preserveOnInactive(permissionUndetermined: false))
    }

    func testConnectUsesReferenceWakeByteAndChecksum() throws {
        XCTAssertEqual(try NiimbotProtocol.encode(command: 0xc1, data: Data([1])),
                       Data([0x03, 0x55, 0x55, 0xc1, 1, 1, 0xc1, 0xaa, 0xaa]))
        XCTAssertEqual(try NiimbotProtocol.encode(command: 0x40, data: Data([8])),
                       Data([0x55, 0x55, 0x40, 1, 8, 0x49, 0xaa, 0xaa]))
        XCTAssertThrowsError(try NiimbotProtocol.encode(command: 0x85, data: Data(repeating: 0, count: 256)))
    }

    func testParserHandlesEveryFragmentBoundaryAndCoalescedNotifications() throws {
        // This is the D110 connect reply captured in the pinned reference.
        let frame = Data([0x55, 0x55, 0xc2, 1, 2, 0xc1, 0xaa, 0xaa])
        let expected = NiimbotPacket(command: 0xc2, data: Data([2]))
        for boundary in 0..<frame.count {
            var parser = NiimbotStreamParser()
            XCTAssertTrue(parser.append(Data(frame.prefix(boundary))).isEmpty)
            XCTAssertEqual(parser.append(Data(frame.dropFirst(boundary))), [expected])
        }
        var parser = NiimbotStreamParser()
        XCTAssertEqual(parser.append(frame + frame), [expected, expected])
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testParserDiscardsCorruptionAndBoundsIncompleteInput() throws {
        let valid = try NiimbotProtocol.encode(command: 0xb3, data: Data([0, 1, 100, 100]))
        var badChecksum = valid
        badChecksum[8] ^= 0xff
        var badTail = valid
        badTail[badTail.count - 1] = 0
        var parser = NiimbotStreamParser()
        XCTAssertEqual(parser.append(Data([0x13, 0x55, 0x01]) + badChecksum + badTail + valid),
                       [NiimbotPacket(command: 0xb3, data: Data([0, 1, 100, 100]))])
        XCTAssertTrue(parser.append(Data(repeating: 0x10, count: 10_000)).isEmpty)
        for byte in Data([0x55, 0x55, 0x48, 0xff]) + Data(repeating: 0x11, count: 250) {
            _ = parser.append(Data([byte]))
            XCTAssertLessThan(parser.bufferedByteCount, NiimbotStreamParser.maximumFrameBytes)
        }
    }

    func testDiscoveryRecognizesD110MNamesButProtocolStillRejectsUnverifiedHardware() throws {
        for name in ["D110_BLE_1234", "D110", "D110M_BLE_1234", "D110_M", "D110-M",
                     "D110_M-l000000000", "d110_m-L000000000", "D110-M_1234"] {
            XCTAssertTrue(NiimbotProtocol.isD110Advertisement(name), name)
        }
        for name in ["B1_1234", "D11_1234", "D1100", "D110PRO", "D110MACHINE", "Other D110"] {
            XCTAssertFalse(NiimbotProtocol.isD110Advertisement(name), name)
        }
        XCTAssertEqual(try NiimbotProtocol.modelID(.init(command: 0x48, data: Data([9]))), 2304)
        XCTAssertEqual(try NiimbotProtocol.modelID(.init(command: 0x48, data: Data([9, 1]))), 2305)
        XCTAssertEqual(try NiimbotProtocol.modelID(.init(command: 0x48, data: Data([9, 16]))), 2320)
        XCTAssertThrowsError(try NiimbotProtocol.validateModel(2320))
        XCTAssertThrowsError(try NiimbotProtocol.validateModel(2321, headInfo: d110MHead()))
        XCTAssertThrowsError(try NiimbotProtocol.validateModel(2305))
        XCTAssertThrowsError(try NiimbotProtocol.validateModel(2305, headInfo: .init(
            command: 0xdf, data: Data([1, 0, 1, 0, 0, 120, 2, 0, 0, 0]))))
        XCTAssertNoThrow(try NiimbotProtocol.validateModel(2305, headInfo: .init(
            command: 0xde, data: Data([1, 0, 1, 0, 0, 96, 2, 0, 0, 0]))))
        XCTAssertNoThrow(try NiimbotProtocol.validateModel(2320, headInfo: d110MHead()))
        for head in [d110MHead(width: 120), d110MHead(resolution: 3), d110MHead(firmware: [0, 0]),
                     NiimbotPacket(command: 0xdd, data: d110MHead().data),
                     NiimbotPacket(command: 0xde, data: Data([4, 1, 4, 23]))] {
            XCTAssertThrowsError(try NiimbotProtocol.validateModel(2320, headInfo: head))
        }
    }

    // Head/status payloads from the pinned reference's D110M_V4_23 capture.
    // Device serial/advertisement suffixes are not needed for identity tests.
    private func d110MHead(width: UInt8 = 96, resolution: UInt8 = 2,
                          firmware: [UInt8] = [4, 23]) -> NiimbotPacket {
        .init(command: 0xde, data: Data([4, 1] + firmware + [0, width, resolution, 2, 1, 0]))
    }

    private var d110MProtocolStatus: NiimbotPacket {
        .init(command: 0xb5,
              data: Data([0x30, 0x30, 0x23, 0x28, 0, 0xc8, 0, 0, 0, 0x0a, 0, 3, 1, 0x12, 0xee, 0]))
    }

    private var d110MReadiness: NiimbotPacket {
        .init(command: 0xd9, data: Data([0x0f, 0xd1, 4, 0x4d, 0, 0, 0, 0, 0, 0, 0]))
    }

    private func d110MIdentity(version: Int = 4) -> NiimbotD110Identity {
        .init(modelID: 2320, protocolVersion: version, firmwareBytes: Data([4, 23]))
    }

    private var denseRaster: LabelRaster {
        .init(width: 96, height: 240, data: Data(repeating: 0xff, count: 12 * 240))
    }

    func testProtocolNegotiationRequiresSupportedGenerationsAndReplyShapes() throws {
        XCTAssertEqual(try NiimbotProtocol.negotiatedVersion(connect: .init(command: 0xc2, data: Data([1]))), 0)
        XCTAssertEqual(try NiimbotProtocol.negotiatedVersion(connect: .init(command: 0xc2, data: Data([2]))), 1)
        for (major, minor, expected) in [(2, 4, 3), (3, 0, 4), (3, 2, 5)] {
            var bytes = Data(repeating: 0, count: 13)
            bytes[11] = UInt8(major)
            bytes[12] = UInt8(minor)
            XCTAssertEqual(try NiimbotProtocol.negotiatedVersion(connect: .init(command: 0xc2, data: Data([3])),
                status: .init(command: 0xb5, data: bytes)), expected)
        }
        XCTAssertThrowsError(try NiimbotProtocol.negotiatedVersion(connect: .init(command: 0xc2, data: Data([90]))))
        XCTAssertThrowsError(try NiimbotProtocol.negotiatedVersion(connect: .init(command: 0xc2, data: Data([3]))))
        var unknown = Data(repeating: 0, count: 13)
        unknown[11] = 4
        XCTAssertThrowsError(try NiimbotProtocol.negotiatedVersion(connect: .init(command: 0xc2, data: Data([3])),
            status: .init(command: 0xb5, data: unknown)))
    }

    func testNativeRowsUseMSBIndexesThreeHeadCountsAndExactFeedSize() throws {
        var bytes = Data(repeating: 0, count: 12 * 240)
        // Three dots in different 32-dot head sections.
        bytes[0] = 0x80
        bytes[4] = 0x01
        bytes[11] = 0x01
        // Dense second row exercises the full bitmap command.
        for index in 12..<24 { bytes[index] = 0xff }
        let requests = try NiimbotProtocol.printRequests(for: .init(width: 96, height: 240, data: bytes))
        XCTAssertEqual(Array(requests.prefix(7)).map(\.command), [0x21, 0x23, 0x01, 0x20, 0x03, 0x13, 0x15])
        XCTAssertEqual(requests[5].data, Data([0, 240, 0, 96]))
        XCTAssertEqual(requests[6].data, Data([0, 1]))
        let indexed = try XCTUnwrap(requests.first(where: { $0.command == 0x83 }))
        XCTAssertEqual(indexed.data, Data([0, 0, 1, 1, 1, 1, 0, 0, 0, 39, 0, 95]))
        let dense = try XCTUnwrap(requests.first(where: { $0.command == 0x85 }))
        XCTAssertEqual(dense.data, Data([0, 1, 32, 32, 32, 1]) + Data(repeating: 0xff, count: 12))
        XCTAssertEqual(requests.last?.command, 0xe3)
        XCTAssertEqual(requests.filter(\.beginsPrint).map(\.command), [0x01])
    }

    func testRepeatedRowsStayInsideByteLimitAndAllSelectedStockHeights() throws {
        for height in [240, 320, 400] {
            let requests = try NiimbotProtocol.printRequests(for: .init(width: 96, height: height,
                data: Data(repeating: 0xff, count: height * 12)))
            let rows = requests.filter { $0.command == 0x85 }
            XCTAssertEqual(rows.map { Int($0.data[5]) }.reduce(0, +), height)
            XCTAssertTrue(rows.allSatisfy { $0.data[5] > 0 })
            XCTAssertTrue(rows.allSatisfy { $0.response == nil })
            XCTAssertEqual(rows.first?.data[5], 200)
        }
        XCTAssertThrowsError(try NiimbotProtocol.printRequests(for: .init(width: 96, height: 801,
            data: Data(repeating: 0xff, count: 801 * 12))))
        XCTAssertThrowsError(try NiimbotProtocol.printRequests(for: .init(width: 120, height: 240,
            data: Data(repeating: 0xff, count: 15 * 240))))
    }

    func testReadinessUsesD110LidInversionAndCompletionRequiresPrinterPageCounter() throws {
        let identity = NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34]))
        var heartbeat = Data(repeating: 0, count: 10)
        heartbeat[8] = 1
        XCTAssertNoThrow(try NiimbotProtocol.validateReadiness(.init(command: 0xdd, data: heartbeat), identity: identity))
        heartbeat[8] = 0
        XCTAssertThrowsError(try NiimbotProtocol.validateReadiness(.init(command: 0xdd, data: heartbeat), identity: identity))
        XCTAssertFalse(try NiimbotProtocol.printStatus(.init(command: 0xb3, data: Data([0, 0, 100, 100]))).finishedOneLabel)
        XCTAssertTrue(try NiimbotProtocol.printStatus(.init(command: 0xb3, data: Data([0, 1, 100, 100]))).finishedOneLabel)
        XCTAssertThrowsError(try NiimbotProtocol.printStatus(.init(command: 0xb3, data: Data([0, 1, 100]))))
        XCTAssertThrowsError(try NiimbotProtocol.printStatus(.init(command: 0xb3, data: Data([0, 1, 100, 100, 0, 0, 2, 0, 0, 0]))))
        XCTAssertEqual(NiimbotProtocol.issueForPrintError(.init(command: 0xdb, data: Data([0x10]))), .paperMismatch)
    }

    @MainActor func testHandshakeUsesCapturedD110ResponsesWithoutRequiringOptionalHeadHeartbeat() async throws {
        var requests: [NiimbotRequest] = []
        var steps: [NiimbotIdentificationStep] = []
        let identity = try await NiimbotD110Session.identify(onStep: { steps.append($0) }) { request in
            requests.append(request)
            switch (request.command, Array(request.data)) {
            case (0xc1, [1]): return NiimbotPacket(command: 0xc2, data: Data([2]))
            case (0x40, [8]): return NiimbotPacket(command: 0x48, data: Data([9, 0]))
            case (0x40, [9]): return NiimbotPacket(command: 0x49, data: Data([5, 34]))
            default: throw LabelPrinterIssue.unsupportedResponse
            }
        }
        XCTAssertEqual(identity.modelID, 2304)
        XCTAssertEqual(identity.protocolVersion, 1)
        XCTAssertEqual(requests.map(\.command), [0xc1, 0x40, 0x40])
        XCTAssertEqual(steps, [.connect, .model, .firmware])
    }

    @MainActor func testD110MHandshakeUsesCapturedHeadFirmwareAndProtocolWithoutLegacyFirmwareQuery() async throws {
        var requests: [NiimbotRequest] = []
        var steps: [NiimbotIdentificationStep] = []
        let identity = try await NiimbotD110Session.identify(onStep: { steps.append($0) }) { request in
            XCTAssertEqual(steps.count, requests.count + 1, "The diagnostic step must be reported before its request")
            requests.append(request)
            switch (request.command, Array(request.data)) {
            case (0xc1, [1]): return .init(command: 0xc2, data: Data([3]))
            case (0x40, [8]): return .init(command: 0x48, data: Data([9, 16]))
            case (0xa5, [1]): return self.d110MProtocolStatus
            case (0xdc, [3]): return self.d110MHead()
            default: throw LabelPrinterIssue.unsupportedResponse
            }
        }
        XCTAssertEqual(identity.modelID, 2320)
        XCTAssertEqual(identity.protocolVersion, 4)
        XCTAssertEqual(identity.firmwareBytes, Data([4, 23]))
        XCTAssertEqual(identity.modelName, "D110-M")
        XCTAssertEqual(requests.map(\.command), [0xc1, 0x40, 0xa5, 0xdc], "Match the captured D110-M app handshake order")
        XCTAssertEqual(steps, [.connect, .model, .protocolVersion, .head])
        XCTAssertEqual(steps.map(\.rawValue), ["connect_command", "model", "protocol_version", "print_head"])
        XCTAssertEqual(requests.filter { $0.command == 0x40 }.map(\.data), [Data([8])],
                       "D110-M firmware comes from the documented head heartbeat, not the older D110 query")
        XCTAssertEqual(requests.filter { $0.command == 0xdc }.map(\.data), [Data([3])])
        XCTAssertFalse(requests.contains(where: \.beginsPrint), "Discovery/identification cannot start printing")
    }

    @MainActor func testD110MHandshakeRejectsUnknownHeadOrProtocolBeforeAnyPrintCommand() async throws {
        for failure in 0..<5 {
            var requests: [NiimbotRequest] = []
            do {
                _ = try await NiimbotD110Session.identify { request in
                    requests.append(request)
                    switch (request.command, Array(request.data)) {
                    case (0xc1, [1]): return .init(command: 0xc2, data: Data([3]))
                    case (0x40, [8]): return .init(command: 0x48, data: Data([9, failure == 0 ? 17 : 16]))
                    case (0xa5, [1]):
                        if failure == 1 {
                            var data = self.d110MProtocolStatus.data
                            data[11] = 4
                            return .init(command: 0xb5, data: data)
                        }
                        return self.d110MProtocolStatus
                    case (0xdc, [3]):
                        return failure == 2 ? self.d110MHead(width: 120)
                            : failure == 3 ? self.d110MHead(resolution: 3)
                            : self.d110MHead(firmware: [0, 0])
                    default: throw LabelPrinterIssue.unsupportedResponse
                    }
                }
                XCTFail("Unverified D110-M identity must not connect, case \(failure)")
            } catch {
                XCTAssertEqual(error as? LabelPrinterIssue, .unsupportedPrinter)
            }
            XCTAssertFalse(requests.contains(where: \.beginsPrint))
            XCTAssertFalse(requests.contains { [UInt8(0x01), 0x13, 0x83, 0x84, 0x85, 0xe3].contains($0.command) })
            XCTAssertFalse(requests.contains { $0.command == 0x40 && $0.data == Data([9]) })
            if failure == 1 {
                XCTAssertEqual(requests.map(\.command), [0xc1, 0x40, 0xa5])
            }
        }
    }

    @MainActor func testIdentificationTimeoutStopsAtEachReportedStepWithoutRetryOrPrint() async throws {
        let commands: [UInt8] = [0xc1, 0x40, 0xa5, 0xdc]
        let expectedSteps: [NiimbotIdentificationStep] = [.connect, .model, .protocolVersion, .head]
        for failedIndex in commands.indices {
            var requests: [NiimbotRequest] = []
            var steps: [NiimbotIdentificationStep] = []
            do {
                _ = try await NiimbotD110Session.identify(onStep: { steps.append($0) }) { request in
                    requests.append(request)
                    if requests.count == failedIndex + 1 { throw LabelPrinterIssue.responseTimeout }
                    switch request.command {
                    case 0xc1: return .init(command: 0xc2, data: Data([3]))
                    case 0x40: return .init(command: 0x48, data: Data([9, 16]))
                    case 0xa5: return self.d110MProtocolStatus
                    case 0xdc: return self.d110MHead()
                    default: throw LabelPrinterIssue.unsupportedResponse
                    }
                }
                XCTFail("A timed-out handshake cannot identify or continue")
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .responseTimeout) }
            XCTAssertEqual(requests.map(\.command), Array(commands.prefix(failedIndex + 1)))
            XCTAssertEqual(steps, Array(expectedSteps.prefix(failedIndex + 1)))
            XCTAssertFalse(requests.contains(where: \.beginsPrint))
        }
    }

    @MainActor func testIdentificationCancellationStopsBeforeTheNextStepAndNeverStartsPrinting() async {
        var requests: [NiimbotRequest] = []
        var steps: [NiimbotIdentificationStep] = []
        let operation = Task { @MainActor in
            try await NiimbotD110Session.identify(onStep: { steps.append($0) }) { request in
                requests.append(request)
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(command: 0xc2, data: Data([3]))
            }
        }
        do {
            _ = try await operation.value
            XCTFail("A cancelled handshake must stop before another request")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests.map(\.command), [0xc1])
        XCTAssertEqual(steps, [.connect])
        XCTAssertFalse(requests.contains(where: \.beginsPrint))
    }

    func testD110MVersionFourUsesItsDocumentedNineByteStartAndThirteenBytePage() throws {
        let requests = try NiimbotProtocol.printRequests(for: denseRaster, identity: d110MIdentity())
        XCTAssertEqual(Array(requests.prefix(5)).map(\.command), [0x23, 0x21, 0x01, 0xa3, 0x13])
        XCTAssertEqual(requests[0].data, Data([1]), "Use the loaded gap-label type")
        XCTAssertEqual(requests[1].data, Data([3]), "Use the model's documented default density")
        XCTAssertEqual(requests[2].data, Data([0, 1, 0, 0, 0, 0, 0, 1, 0]))
        XCTAssertEqual(requests[3].data, Data([1]))
        XCTAssertNil(requests[3].response, "The v4 task's pre-page status request is explicitly one-way")
        XCTAssertEqual(requests[4].data, Data([0, 240, 0, 96, 0, 1, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertFalse(requests.contains { [UInt8(0x20), 0x03, 0x15].contains($0.command) },
                       "D110-M v4 does not use the older Clear/PageStart/PrintQuantity sequence")
        XCTAssertEqual(requests.filter(\.beginsPrint).map(\.command), [0x01])
        let rows = requests.filter { $0.command == 0x85 }
        XCTAssertEqual(rows.map { Int($0.data[5]) }.reduce(0, +), 240)
        XCTAssertTrue(rows.allSatisfy { $0.data.suffix(12) == Data(repeating: 0xff, count: 12) })
        XCTAssertEqual(requests.last?.command, 0xe3)
        XCTAssertEqual(requests.last?.response, 0xe4)
        XCTAssertEqual(requests.last?.requiresTrue, true)
    }

    func testOtherSupportedD110MProtocolsUseB1TaskWithoutChangingStandardD110Packets() throws {
        for version in [0, 1, 3, 5] {
            let requests = try NiimbotProtocol.printRequests(for: denseRaster, identity: d110MIdentity(version: version))
            XCTAssertEqual(Array(requests.prefix(5)).map(\.command), [0x21, 0x23, 0x01, 0x03, 0x13])
            XCTAssertEqual(requests[0].data, Data([3]))
            XCTAssertEqual(requests[1].data, Data([1]))
            XCTAssertEqual(requests[2].data, Data([0, 1, 0, 0, 0, 0, 0]))
            XCTAssertEqual(requests[4].data, Data([0, 240, 0, 96, 0, 1]))
            XCTAssertFalse(requests.contains { [UInt8(0x20), 0x15, 0xa3].contains($0.command) })
            XCTAssertEqual(requests.filter(\.beginsPrint).map(\.command), [0x01])
        }
        let standard = NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34]))
        XCTAssertEqual(try NiimbotProtocol.printRequests(for: denseRaster, identity: standard),
                       try NiimbotProtocol.printRequests(for: denseRaster),
                       "Adding M support cannot change the standard D110 job's wire packets")
    }

    @MainActor func testD110MVersionFourWaitsForPageCompletionThenEndsAndSendsItsOneWayHeartbeat() async throws {
        var requests: [NiimbotRequest] = []
        var polls = 0, pauses = 0
        try await NiimbotD110Session.printLabel(denseRaster, identity: d110MIdentity()) { request in
            requests.append(request)
            if request.command == 0xdc {
                if request.response == nil { return nil }
                return self.d110MReadiness
            }
            if request.command == 0xa3 {
                if request.response == nil { return nil }
                polls += 1
                return .init(command: 0xb3, data: Data([0, polls == 1 ? 0 : 1, 100, 100]))
            }
            if request.command == 0xf3 { XCTAssertEqual(polls, 2, "PageEnd acknowledgment alone cannot complete the saved queue entry") }
            return request.response.map { .init(command: $0, data: Data([1])) }
        } pause: { pauses += 1 }

        XCTAssertEqual(polls, 2); XCTAssertEqual(pauses, 2)
        XCTAssertEqual(Array(requests.suffix(5)).map(\.command), [0xe3, 0xa3, 0xa3, 0xf3, 0xdc])
        XCTAssertEqual(requests.last?.data, Data([1]))
        XCTAssertNil(requests.last?.response)
        XCTAssertEqual(requests.filter(\.beginsPrint).map(\.command), [0x01])
    }

    @MainActor func testD110MOpenLidOrMissingPaperStopsBeforeDispatchingPrintStart() async throws {
        XCTAssertNoThrow(try NiimbotProtocol.validateReadiness(d110MReadiness, identity: d110MIdentity()))
        for statusIndex in [4, 5] {
            var data = d110MReadiness.data
            data[statusIndex] = 1
            var requests: [NiimbotRequest] = []
            do {
                try await NiimbotD110Session.printLabel(denseRaster, identity: d110MIdentity()) { request in
                    requests.append(request)
                    return .init(command: 0xd9, data: data)
                } pause: {}
                XCTFail("Open lid or missing paper cannot start a label")
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .printerNotReady) }
            XCTAssertEqual(requests.map(\.command), [0xdc])
            XCTAssertFalse(requests.contains(where: \.beginsPrint))
        }
    }

    @MainActor func testD110MRejectedPageTimeoutAndCancellationNeverReplayThePrintJob() async throws {
        for failure in 0..<3 {
            var requests: [NiimbotRequest] = []
            var polls = 0
            do {
                try await NiimbotD110Session.printLabel(denseRaster, identity: d110MIdentity()) { request in
                    requests.append(request)
                    if request.command == 0xdc { return self.d110MReadiness }
                    if request.command == 0xa3 {
                        if request.response == nil { return nil }
                        polls += 1
                        return .init(command: 0xb3, data: Data([0, 0, 100, 100]))
                    }
                    return request.response.map { .init(command: $0, data: Data([failure == 0 && request.command == 0xe3 ? 0 : 1])) }
                } pause: {
                    if failure == 2 { throw LabelPrinterIssue.cancelled }
                }
                XCTFail("The failed job must not be reported as completed")
            } catch {
                XCTAssertEqual(error as? LabelPrinterIssue,
                               failure == 0 ? .printerNotReady : failure == 1 ? .responseTimeout : .cancelled)
            }
            XCTAssertEqual(requests.filter(\.beginsPrint).map(\.command), [0x01])
            XCTAssertFalse(requests.contains { $0.command == 0xf3 })
            XCTAssertEqual(polls, failure == 1 ? 100 : 0)
        }
    }

    @MainActor func testInvalidD110MIdentityOrRasterIsRejectedBeforeAnyRadioExchange() async throws {
        let invalidIdentities = [
            NiimbotD110Identity(modelID: 9999, protocolVersion: 4, firmwareBytes: Data([4, 23])),
            d110MIdentity(version: 2), d110MIdentity(version: 6),
            NiimbotD110Identity(modelID: 2320, protocolVersion: 4, firmwareBytes: Data()),
            NiimbotD110Identity(modelID: 2320, protocolVersion: 4, firmwareBytes: Data([0, 0]))
        ]
        for identity in invalidIdentities {
            var exchanges = 0
            do {
                try await NiimbotD110Session.printLabel(denseRaster, identity: identity) { _ in
                    exchanges += 1
                    return nil
                } pause: {}
                XCTFail("Invalid identity must fail before sending bytes")
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .unsupportedPrinter) }
            XCTAssertEqual(exchanges, 0)
        }
        for raster in [LabelRaster(width: 96, height: 801, data: Data(repeating: 0xff, count: 12 * 801)),
                       LabelRaster(width: 120, height: 240, data: Data(repeating: 0xff, count: 15 * 240))] {
            var exchanges = 0
            do {
                try await NiimbotD110Session.printLabel(raster, identity: d110MIdentity()) { _ in
                    exchanges += 1
                    return nil
                } pause: {}
                XCTFail("Invalid raster must fail before sending bytes")
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .invalidLabel) }
            XCTAssertEqual(exchanges, 0)
        }
    }

    func testTransparentModeChangesOnlyTheMediaCommandAcrossAllThreePrintTasks() throws {
        let standard = NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34]))
        for identity in [standard, d110MIdentity(version: 3), d110MIdentity()] {
            let defaultGap = try NiimbotProtocol.printRequests(for: denseRaster, identity: identity)
            let explicitGap = try NiimbotProtocol.printRequests(for: denseRaster, identity: identity, paperMode: .gap)
            let transparent = try NiimbotProtocol.printRequests(for: denseRaster, identity: identity, paperMode: .transparent)

            XCTAssertEqual(defaultGap, explicitGap, "Existing calls keep their original Gap packets")
            XCTAssertEqual(defaultGap.filter { $0.command == 0x23 }.map(\.data), [Data([1])])
            XCTAssertEqual(transparent.filter { $0.command == 0x23 }.map(\.data), [Data([5])])
            XCTAssertEqual(transparent.filter { $0.command != 0x23 }, defaultGap.filter { $0.command != 0x23 },
                           "Paper mode cannot alter the raster, page dimensions, print task or completion commands")
            XCTAssertEqual(transparent.filter(\.beginsPrint).map(\.command), [0x01])
            XCTAssertFalse(transparent.contains { $0.command == 0x8e }, "Changing media is not an undocumented calibration/feed command")
        }
        XCTAssertEqual(NiimbotPaperMode.gap.title, "Gap")
        XCTAssertEqual(NiimbotPaperMode.transparent.title, "Transparent")
    }

    @MainActor func testReadPaperModeReadsOnlyTheConfiguredPropertyAndRejectsUnknownResponses() async throws {
        for expected in NiimbotPaperMode.allCases {
            var requests: [NiimbotRequest] = []
            let mode = try await NiimbotD110Session.readPaperMode { request in
                requests.append(request)
                return .init(command: 0x43, data: Data([expected.commandValue]))
            }
            XCTAssertEqual(mode, expected)
            XCTAssertEqual(requests.map(\.command), [0x40])
            XCTAssertEqual(requests.first?.data, Data([3]))
            XCTAssertEqual(requests.first?.response, 0x43)
            XCTAssertFalse(requests.contains(where: \.beginsPrint))
        }
        let invalid: [NiimbotPacket?] = [nil, .init(command: 0x33, data: Data([5])),
            .init(command: 0x43, data: Data()), .init(command: 0x43, data: Data([1, 5])),
            .init(command: 0x43, data: Data([0])), .init(command: 0x43, data: Data([2])),
            .init(command: 0x43, data: Data([3])), .init(command: 0x43, data: Data([255]))]
        for response in invalid {
            var exchanges = 0
            do {
                _ = try await NiimbotD110Session.readPaperMode { _ in exchanges += 1; return response }
                XCTFail("Unsupported or malformed configured media must not become a guessed paper mode")
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .unsupportedResponse) }
            XCTAssertEqual(exchanges, 1)
        }
    }

    @MainActor func testApplyPaperModeAcceptsEchoedTransparentAcknowledgmentWithoutStartingOrFeeding() async throws {
        for mode in NiimbotPaperMode.allCases {
            var requests: [NiimbotRequest] = []
            try await NiimbotD110Session.applyPaperMode(mode) { request in
                requests.append(request)
                return .init(command: 0x33, data: Data([mode.commandValue]))
            }
            XCTAssertEqual(requests.map(\.command), [0x23])
            XCTAssertEqual(requests.first?.data, Data([mode.commandValue]))
            XCTAssertEqual(requests.first?.response, 0x33)
            XCTAssertEqual(requests.first?.requiresTrue, false, "SetLabelType replies can echo 5 rather than boolean 1")
            XCTAssertFalse(requests.contains(where: \.beginsPrint))
        }
        let rejected: [NiimbotPacket?] = [nil, NiimbotPacket(command: 0x43, data: Data([5]))]
        for response in rejected {
            do {
                try await NiimbotD110Session.applyPaperMode(.transparent) { _ in response }
                XCTFail("A missing or unrelated reply cannot confirm the new printer mode")
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .unsupportedResponse) }
        }
    }

    @MainActor func testSessionPrintUsesTheSelectedTransparentModeBeforePrintingAndNeverCalibrates() async throws {
        let standard = NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34]))
        for identity in [standard, d110MIdentity(version: 3), d110MIdentity()] {
            var requests: [NiimbotRequest] = []
            try await NiimbotD110Session.printLabel(denseRaster, identity: identity, paperMode: .transparent) { request in
                requests.append(request)
                if request.command == 0xdc {
                    if request.response == nil { return nil }
                    return identity.modelID == 2320 ? self.d110MReadiness
                        : .init(command: 0xdd, data: Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 4]))
                }
                if request.command == 0xa3 {
                    if request.response == nil { return nil }
                    return .init(command: 0xb3, data: Data([0, 1, 100, 100]))
                }
                return request.response.map { .init(command: $0, data: Data([request.command == 0x23 ? 5 : 1])) }
            } pause: {}
            XCTAssertEqual(requests.filter { $0.command == 0x23 }.map(\.data), [Data([5])])
            let mediaIndex = try XCTUnwrap(requests.firstIndex { $0.command == 0x23 })
            let printIndex = try XCTUnwrap(requests.firstIndex(where: \.beginsPrint))
            XCTAssertLessThan(mediaIndex, printIndex)
            XCTAssertEqual(requests.filter(\.beginsPrint).count, 1)
            XCTAssertTrue(requests.contains { $0.command == 0xf3 })
            XCTAssertFalse(requests.contains { $0.command == 0x8e })
        }
    }

    @MainActor func testFullWorkflowPollsUntilCompletedAndOnlyThenEndsPrint() async throws {
        var seen: [UInt8] = []
        var statusPolls = 0
        var pauses = 0
        let identity = NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34]))
        let raster = LabelRaster(width: 96, height: 240, data: Data(repeating: 0xff, count: 12 * 240))
        try await NiimbotD110Session.printLabel(raster, identity: identity) { request in
            seen.append(request.command)
            if request.command == 0xdc {
                return NiimbotPacket(command: 0xdd, data: Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 4]))
            }
            if request.command == 0xa3 {
                statusPolls += 1
                return NiimbotPacket(command: 0xb3, data: Data([0, statusPolls == 1 ? 0 : 1, 100, 100]))
            }
            return request.response.map { NiimbotPacket(command: $0, data: Data([1])) }
        } pause: { pauses += 1 }
        XCTAssertEqual(statusPolls, 2)
        XCTAssertEqual(pauses, 2)
        XCTAssertEqual(Array(seen.suffix(4)), [0xe3, 0xa3, 0xa3, 0xf3])
        XCTAssertEqual(seen.filter { $0 == 0x01 }.count, 1)
    }

    @MainActor func testRejectedPageAndMissingCompletionThrowWithoutReplayingPrint() async throws {
        let identity = NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34]))
        let raster = LabelRaster(width: 96, height: 240, data: Data(repeating: 0xff, count: 12 * 240))
        for rejectPage in [true, false] {
            var seen: [UInt8] = []
            do {
                try await NiimbotD110Session.printLabel(raster, identity: identity) { request in
                    seen.append(request.command)
                    if request.command == 0xdc {
                        return NiimbotPacket(command: 0xdd, data: Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 4]))
                    }
                    if request.command == 0xa3 {
                        return NiimbotPacket(command: 0xb3, data: Data([0, 0, 100, 100]))
                    }
                    return request.response.map { NiimbotPacket(command: $0, data: Data([rejectPage && request.command == 0x03 ? 0 : 1])) }
                } pause: {}
                XCTFail("A rejected page or an uncompleted print must not succeed")
            } catch {
                XCTAssertEqual(error as? LabelPrinterIssue, rejectPage ? .printerNotReady : .responseTimeout)
            }
            XCTAssertEqual(seen.filter { $0 == 0x01 }.count, 1)
            XCTAssertFalse(seen.contains(0xf3))
            XCTAssertEqual(seen.filter { $0 == 0xa3 }.count, rejectPage ? 0 : 100)
        }
    }

    func testBatchStatusCounterIsBoundedByTheDeclaredCountAndKeepsSingleLabelDefault() throws {
        for pages in [0, 1, 2, 250] {
            let packet = NiimbotPacket(command: 0xb3, data: Data([0, UInt8(pages), 100, 100]))
            XCTAssertEqual(try NiimbotProtocol.printStatus(packet, maximumPages: 250).completedPages, pages)
        }
        XCTAssertThrowsError(try NiimbotProtocol.printStatus(.init(command: 0xb3, data: Data([0, 2, 100, 100]))))
        for (bytes, maximum) in [([UInt8(0), 3, 100, 100], 2), ([0, 251, 100, 100], 250),
                                 ([0, 1, 101, 100], 2), ([0, 1, 100, 101], 2),
                                 ([0, 0, 0, 0], 0), ([0, 1, 100, 100], 251)] {
            XCTAssertThrowsError(try NiimbotProtocol.printStatus(.init(command: 0xb3, data: Data(bytes)), maximumPages: maximum))
        }
    }

    func testMProfilesDeclareOneBatchAndRetainEveryRawPageAndPaperMode() throws {
        var secondBytes = Data(repeating: 0, count: 12 * 320)
        secondBytes[0] = 0x80
        let second = LabelRaster(width: 96, height: 320, data: secondBytes)
        for version in [0, 1, 3, 4, 5] {
            let batch = try NiimbotProtocol.batchRequests(for: [denseRaster, second],
                identity: d110MIdentity(version: version), paperMode: .transparent)
            XCTAssertTrue(batch.usesCumulativePageCounter)
            XCTAssertEqual(batch.initialization.filter { $0.command == 0x23 }.map(\.data), [Data([5])])
            let start = try XCTUnwrap(batch.initialization.first { $0.command == 0x01 })
            XCTAssertEqual(start.data, Data(version == 4
                ? [0, 2, 0, 0, 0, 0, 0, 1, 0] : [0, 2, 0, 0, 0, 0, 0]))
            XCTAssertTrue(start.beginsPrint)
            XCTAssertEqual(batch.pages.count, 2)
            XCTAssertEqual(batch.pages.map { $0.last?.command }, [0xe3, 0xe3])
            XCTAssertEqual(batch.pages.flatMap { $0 }.filter(\.beginsPrint).map(\.command),
                           version == 4 ? [0x13, 0x13] : [0x03, 0x03])
            XCTAssertEqual(batch.pages.map { $0.first { $0.command == 0x13 }?.data.prefix(4) },
                           [Data([0, 240, 0, 96]), Data([1, 64, 0, 96])])
            // Batch changes only task framing and conservative dispatch markers.
            // Its row packets must still contain each exact prepared raster.
            for (page, raster) in zip(batch.pages, [denseRaster, second]) {
                let single = try NiimbotProtocol.printRequests(for: raster, identity: d110MIdentity(version: version))
                let imageCommands: Set<UInt8> = [0x83, 0x84, 0x85]
                XCTAssertEqual(page.filter { imageCommands.contains($0.command) },
                               single.filter { imageCommands.contains($0.command) })
            }
            XCTAssertFalse(batch.pages.flatMap { $0 }.contains { [UInt8(0x01), 0xf3, 0x21, 0x23].contains($0.command) })
        }
    }

    @MainActor func testMContinuousTaskConfirmsAndPersistsEachPageBeforeTheNextPageThenEndsOnce() async throws {
        for version in [3, 4] {
            var requests: [NiimbotRequest] = []
            var events: [String] = []
            var sentPages = 0, pollsForPage = 0, pauses = 0
            var confirmed: [Int] = []
            try await NiimbotD110Session.printBatch([denseRaster, denseRaster, denseRaster],
                identity: d110MIdentity(version: version), exchange: { request in
                    requests.append(request)
                    if request.command == 0xdc { return request.response == nil ? nil : self.d110MReadiness }
                    if request.command == 0x01 { XCTAssertEqual(events, ["will0"]) }
                    if request.command == 0x13 {
                        XCTAssertEqual(events.last, "will\(sentPages)")
                        XCTAssertEqual(confirmed, Array(0..<sentPages))
                        XCTAssertEqual(request.beginsPrint, version == 4)
                    }
                    if request.command == 0xe3 {
                        events.append("received\(sentPages)")
                        sentPages += 1
                        pollsForPage = 0
                    }
                    if request.command == 0xa3 {
                        guard request.response != nil else { return nil }
                        pollsForPage += 1
                        let count = pollsForPage == 1 ? sentPages - 1 : sentPages
                        // Completed-page proof is authoritative even if the
                        // independent progress percentages have not reached 100.
                        return .init(command: 0xb3, data: Data([0, UInt8(count), 80, 0]))
                    }
                    if request.command == 0xf3 { XCTAssertEqual(confirmed, [0, 1, 2]) }
                    return request.response.map { .init(command: $0, data: Data([1])) }
                }, pause: { pauses += 1 }, onPageWillSend: { index in
                    events.append("will\(index)")
                }, onPageCompleted: { index in
                    confirmed.append(index)
                    events.append("saved\(index)")
                })
            XCTAssertEqual(events, ["will0", "received0", "saved0", "will1", "received1", "saved1",
                                    "will2", "received2", "saved2"])
            XCTAssertEqual(pauses, 6)
            XCTAssertEqual(requests.filter { $0.command == 0x01 }.count, 1)
            XCTAssertEqual(requests.filter { $0.command == 0xf3 }.count, 1)
            XCTAssertEqual(requests.filter { $0.command == 0x21 }.count, 1)
            XCTAssertEqual(requests.filter { $0.command == 0x23 }.count, 1)
            XCTAssertEqual(requests.filter { $0.command == 0xe3 }.count, 3)
            XCTAssertEqual(requests.filter(\.beginsPrint).map(\.command),
                           version == 4 ? [0x01, 0x13, 0x13, 0x13] : [0x01, 0x03, 0x03, 0x03])
            XCTAssertEqual(Array(requests.suffix(version == 4 ? 2 : 1)).map(\.command),
                           version == 4 ? [0xf3, 0xdc] : [0xf3])
        }
    }

    @MainActor func testLegacyD110BatchKeepsTheEstablishedOneLabelTasksAndCallbacks() async throws {
        let identity = NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34]))
        let batch = try NiimbotProtocol.batchRequests(for: [denseRaster, denseRaster], identity: identity)
        XCTAssertFalse(batch.usesCumulativePageCounter)
        XCTAssertTrue(batch.initialization.isEmpty)
        XCTAssertEqual(batch.pages, Array(repeating: try NiimbotProtocol.printRequests(for: denseRaster), count: 2))
        var requests: [NiimbotRequest] = []
        var events: [String] = []
        try await NiimbotD110Session.printBatch([denseRaster, denseRaster], identity: identity, exchange: { request in
            requests.append(request)
            if request.command == 0xdc { return .init(command: 0xdd, data: Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 4])) }
            if request.command == 0xa3 { return .init(command: 0xb3, data: Data([0, 1, 100, 100])) }
            if request.command == 0xf3 { events.append("ended") }
            return request.response.map { .init(command: $0, data: Data([1])) }
        }, pause: {}, onPageWillSend: { events.append("will\($0)") },
           onPageCompleted: { events.append("saved\($0)") })
        XCTAssertEqual(events, ["will0", "ended", "saved0", "will1", "ended", "saved1"])
        XCTAssertEqual(requests.filter { $0.command == 0x01 }.count, 2)
        XCTAssertEqual(requests.filter { $0.command == 0xf3 }.count, 2)
    }

    @MainActor func testBatchValidatesAllPagesAndCountBeforeAnyRadioOrJournalCallback() async throws {
        let invalid = LabelRaster(width: 96, height: 801, data: Data(repeating: 0xff, count: 12 * 801))
        for rasters in [[], [denseRaster, invalid], Array(repeating: denseRaster, count: 251)] {
            var exchanges = 0, callbacks = 0
            do {
                try await NiimbotD110Session.printBatch(rasters, identity: d110MIdentity(),
                    exchange: { _ in exchanges += 1; return nil }, pause: {},
                    onPageWillSend: { _ in callbacks += 1 }, onPageCompleted: { _ in callbacks += 1 })
                XCTFail("No part of an invalid batch may print")
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .invalidLabel) }
            XCTAssertEqual(exchanges, 0)
            XCTAssertEqual(callbacks, 0)
        }
        let bounded = try NiimbotProtocol.batchRequests(for: Array(repeating: denseRaster, count: 250), identity: d110MIdentity())
        XCTAssertEqual(bounded.initialization.first { $0.command == 0x01 }?.data.prefix(2), Data([0, 250]))
    }

    @MainActor func testFailedWriteAheadOrCompletionPersistenceStopsTheBatchBeforeFuturePageBytes() async throws {
        for failure in 0..<3 {
            var requests: [NiimbotRequest] = []
            var sentPages = 0
            var will: [Int] = [], completed: [Int] = []
            do {
                try await NiimbotD110Session.printBatch([denseRaster, denseRaster], identity: d110MIdentity(), exchange: { request in
                    requests.append(request)
                    if request.command == 0xdc { return self.d110MReadiness }
                    if request.command == 0xe3 { sentPages += 1 }
                    if request.command == 0xa3 {
                        return request.response == nil ? nil : .init(command: 0xb3, data: Data([0, UInt8(sentPages), 100, 100]))
                    }
                    return request.response.map { .init(command: $0, data: Data([1])) }
                }, pause: {}, onPageWillSend: { index in
                    will.append(index)
                    if (failure == 0 && index == 0) || (failure == 1 && index == 1) { throw LabelPrinterIssue.writeFailed }
                }, onPageCompleted: { index in
                    completed.append(index)
                    if failure == 2 { throw LabelPrinterIssue.writeFailed }
                })
                XCTFail("A failed queue save must stop future dispatch")
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .writeFailed) }
            XCTAssertEqual(sentPages, failure == 0 ? 0 : 1)
            XCTAssertEqual(completed, failure == 0 ? [] : [0])
            XCTAssertEqual(will, failure == 1 ? [0, 1] : [0])
            XCTAssertEqual(requests.filter { $0.command == 0x01 }.count, failure == 0 ? 0 : 1)
            XCTAssertFalse(requests.contains { $0.command == 0xf3 })
            if failure == 0 { XCTAssertFalse(requests.contains(where: \.beginsPrint)) }
        }
    }

    @MainActor func testBatchRejectsRegressedOrUnsentPageCountersWithoutCompletingOrSendingFutureCopies() async throws {
        for invalidCount in [UInt8(0), 3] {
            var requests: [NiimbotRequest] = []
            var sentPages = 0
            var will: [Int] = [], completed: [Int] = []
            do {
                try await NiimbotD110Session.printBatch([denseRaster, denseRaster, denseRaster], identity: d110MIdentity(), exchange: { request in
                    requests.append(request)
                    if request.command == 0xdc { return self.d110MReadiness }
                    if request.command == 0xe3 { sentPages += 1 }
                    if request.command == 0xa3 {
                        return request.response == nil ? nil : .init(command: 0xb3,
                            data: Data([0, sentPages == 1 ? 1 : invalidCount, 100, 100]))
                    }
                    return request.response.map { .init(command: $0, data: Data([1])) }
                }, pause: {}, onPageWillSend: { will.append($0) }, onPageCompleted: { completed.append($0) })
                XCTFail("A counter outside the sent range cannot prove a physical copy")
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .unsupportedResponse) }
            XCTAssertEqual(will, [0, 1]); XCTAssertEqual(completed, [0])
            XCTAssertEqual(sentPages, 2)
            XCTAssertEqual(requests.filter { $0.command == 0x01 }.count, 1)
            XCTAssertFalse(requests.contains { $0.command == 0xf3 })
        }
    }

    @MainActor func testPartialBatchErrorsTimeoutAndCancellationNeverReplayOrSendRemainingPages() async throws {
        let expectedIssues: [LabelPrinterIssue] = [.printerNotReady, .responseTimeout, .cancelled, .connectionLost]
        for failure in 0..<4 {
            var requests: [NiimbotRequest] = []
            var sentPages = 0, secondPagePolls = 0
            var will: [Int] = [], completed: [Int] = []
            do {
                try await NiimbotD110Session.printBatch([denseRaster, denseRaster, denseRaster], identity: d110MIdentity(), exchange: { request in
                    requests.append(request)
                    if request.command == 0xdc { return self.d110MReadiness }
                    if request.command == 0x13 && sentPages == 1 && failure == 3 { throw LabelPrinterIssue.connectionLost }
                    if request.command == 0xe3 { sentPages += 1 }
                    if request.command == 0xa3 {
                        guard request.response != nil else { return nil }
                        if sentPages == 2 { secondPagePolls += 1 }
                        return .init(command: 0xb3, data: Data([0, 1, 100, 100]))
                    }
                    let value: UInt8 = failure == 0 && request.command == 0xe3 && sentPages == 2 ? 0 : 1
                    return request.response.map { .init(command: $0, data: Data([value])) }
                }, pause: {
                    if failure == 2 && sentPages == 2 { throw LabelPrinterIssue.cancelled }
                }, onPageWillSend: { will.append($0) }, onPageCompleted: { completed.append($0) })
                XCTFail("An interrupted batch must retain proof only for its first page")
            } catch {
                XCTAssertEqual(error as? LabelPrinterIssue, expectedIssues[failure])
            }
            XCTAssertEqual(will, [0, 1]); XCTAssertEqual(completed, [0])
            XCTAssertEqual(sentPages, failure == 3 ? 1 : 2)
            XCTAssertEqual(secondPagePolls, failure == 1 ? 100 : 0)
            XCTAssertEqual(requests.filter { $0.command == 0x01 }.count, 1)
            XCTAssertFalse(requests.contains { $0.command == 0xf3 })
        }
    }

    @MainActor func testCancellationImmediatelyAfterPhysicalCounterStillRecordsThatProofAndStopsFuturePages() async {
        var will: [Int] = [], completed: [Int] = []
        var sentPages = 0
        let operation = Task { @MainActor in
            try await NiimbotD110Session.printBatch([denseRaster, denseRaster], identity: d110MIdentity(), exchange: { request in
                if request.command == 0xdc { return self.d110MReadiness }
                if request.command == 0xe3 { sentPages += 1 }
                if request.command == 0xa3 {
                    guard request.response != nil else { return nil }
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .init(command: 0xb3, data: Data([0, 1, 100, 100]))
                }
                return request.response.map { .init(command: $0, data: Data([1])) }
            }, pause: {}, onPageWillSend: { will.append($0) }, onPageCompleted: { completed.append($0) })
        }
        do {
            try await operation.value
            XCTFail("Cancellation cannot send the second page")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(will, [0]); XCTAssertEqual(completed, [0])
        XCTAssertEqual(sentPages, 1)
    }

    private func variantRaster(_ byte: UInt8) -> LabelRaster {
        .init(width: 96, height: 240, data: Data(repeating: byte, count: 12 * 240))
    }

    func testContinuousPlanUsesBoundedAdjacentNativeCopiesAndNeverChangesRasterRows() throws {
        let other = variantRaster(0x7f)
        let rasters = Array(repeating: denseRaster, count: 10) + [other, denseRaster]
        for version in [0, 1, 3, 4, 5] {
            let identity = d110MIdentity(version: version)
            let plan = try NiimbotProtocol.continuousRequests(for: rasters, identity: identity, paperMode: .transparent)
            XCTAssertTrue(plan.usesCumulativePageCounter)
            XCTAssertEqual(plan.groups.map(\.indices), [0..<8, 8..<10, 10..<11, 11..<12])
            XCTAssertEqual(plan.initialization.first { $0.command == 0x01 }?.data.prefix(2), Data([0, 12]))
            XCTAssertEqual(plan.initialization.first { $0.command == 0x23 }?.data, Data([5]))
            for group in plan.groups {
                let size = try XCTUnwrap(group.requests.first { $0.command == 0x13 })
                XCTAssertEqual(size.data.count, version == 4 ? 13 : 6)
                XCTAssertEqual(size.data.subdata(in: 4..<6), Data([0, UInt8(group.indices.count)]))
                XCTAssertLessThanOrEqual(group.indices.count, 8)
                XCTAssertEqual(group.requests.filter(\.beginsPrint).map(\.command), version == 4 ? [0x13] : [0x03])
                let single = try NiimbotProtocol.printRequests(for: rasters[group.indices.lowerBound], identity: identity)
                let imageCommands: Set<UInt8> = [0x83, 0x84, 0x85]
                XCTAssertEqual(group.requests.filter { imageCommands.contains($0.command) },
                               single.filter { imageCommands.contains($0.command) },
                               "Each native-copy group uploads its exact image once, irrespective of quantity")
            }
        }
    }

    @MainActor func testContinuousWindowUploadsTwoGroupsBeforePollingAndDurablyForwardsPartialAndCombinedReceipts() async throws {
        for version in [3, 4] {
            let rasters = Array(repeating: denseRaster, count: 3) + Array(repeating: variantRaster(0x7f), count: 2) + [variantRaster(0x3f)]
            var requests: [NiimbotRequest] = []
            var will: [[Int]] = [], receipts: [[Int]] = []
            var submitted = 0, quantity = 0, groups = 0, polls = 0, pauses = 0
            let counters = [2, 3, 6]
            try await NiimbotD110Session.printContinuously(rasters, identity: d110MIdentity(version: version), exchange: { request in
                requests.append(request)
                if request.command == 0xdc { return request.response == nil ? nil : self.d110MReadiness }
                if request.command == 0x01 { XCTAssertEqual(will, [[0, 1, 2]]) }
                if request.command == 0x13 { quantity = Int(request.data[4]) << 8 | Int(request.data[5]) }
                if request.command == 0xe3 { submitted += quantity; groups += 1 }
                if request.command == 0xa3 {
                    guard request.response != nil else { return nil }
                    if polls == 0 { XCTAssertEqual(groups, 2); XCTAssertEqual(submitted, 5) }
                    if polls == 2 { XCTAssertEqual(groups, 3); XCTAssertEqual(submitted, 6) }
                    let count = counters[min(polls, counters.count - 1)]
                    polls += 1
                    return .init(command: 0xb3, data: Data([0, UInt8(count), 75, 0]))
                }
                if request.command == 0xf3 { XCTAssertEqual(receipts.flatMap { $0 }, Array(0..<6)) }
                return request.response.map { .init(command: $0, data: Data([1])) }
            }, pause: { pauses += 1 }, onPagesWillSend: { indices in
                if indices == [5] {
                    XCTAssertEqual(receipts, [[0, 1], [2]])
                    XCTAssertEqual(pauses, 0, "Physical progress must refill without an extra polling delay")
                }
                will.append(indices)
            }, onPagesCompleted: { receipts.append($0) })
            XCTAssertEqual(will, [[0, 1, 2], [3, 4], [5]])
            XCTAssertEqual(receipts, [[0, 1], [2], [3, 4, 5]])
            XCTAssertEqual(polls, 3); XCTAssertEqual(pauses, 0)
            XCTAssertEqual(requests.filter { $0.command == 0x01 }.count, 1)
            XCTAssertEqual(requests.filter { $0.command == 0xf3 }.count, 1)
            XCTAssertEqual(requests.filter { $0.command == 0xe3 }.count, 3)
            XCTAssertEqual(requests.last?.command, version == 4 ? 0xdc : 0xf3)
        }
    }

    @MainActor func testContinuousPollingWaitsOnlyAfterBusyStatusAndRefillsBeforePollingAgain() async throws {
        var events: [String] = []
        var polls = 0
        let rasters = [denseRaster, variantRaster(0x7f), variantRaster(0x3f)]
        try await NiimbotD110Session.printContinuously(rasters, identity: d110MIdentity(), exchange: { request in
            if request.command == 0xdc { return request.response == nil ? nil : self.d110MReadiness }
            if request.command == 0xa3 && request.response != nil {
                events.append("poll")
                let count = [0, 1, 1, 3][polls]
                polls += 1
                return .init(command: 0xb3, data: Data([0, UInt8(count), 100, 100]))
            }
            return request.response.map { .init(command: $0, data: Data([1])) }
        }, pause: { events.append("pause") }, onPagesWillSend: { pages in
            events.append("send\(pages[0])")
        }, onPagesCompleted: { pages in events.append("proof\(pages.last!)") })
        XCTAssertEqual(events, ["send0", "send1", "poll", "pause", "poll", "proof0", "send2",
                                "poll", "pause", "poll", "proof2"])
    }

    @MainActor func testContinuousCancellationDuringBusyWaitPreventsAnotherPollOrRefill() async {
        var polls = 0
        var will: [[Int]] = []
        let operation = Task { @MainActor in
            try await NiimbotD110Session.printContinuously(
                [denseRaster, variantRaster(0x7f), variantRaster(0x3f)], identity: d110MIdentity(), exchange: { request in
                    if request.command == 0xdc { return self.d110MReadiness }
                    if request.command == 0xa3 {
                        guard request.response != nil else { return nil }
                        polls += 1
                        return .init(command: 0xb3, data: Data([0, 0, 100, 100]))
                    }
                    return request.response.map { .init(command: $0, data: Data([1])) }
                }, pause: { withUnsafeCurrentTask { $0?.cancel() } },
                onPagesWillSend: { will.append($0) }, onPagesCompleted: { _ in XCTFail("Busy is not physical completion") })
        }
        do { try await operation.value; XCTFail("Cancellation must stop the polling loop") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(polls, 1)
        XCTAssertEqual(will, [[0], [1]])
    }

    func testExperimentalTransportAllowsOnlyOneWayImageRowsAndRetainsEveryCheckpoint() {
        for value in UInt8.min...UInt8.max {
            let request = NiimbotRequest(value)
            XCTAssertEqual(request.allowsExperimentalImageWrite, [UInt8(0x83), 0x84, 0x85].contains(value))
        }
        for command in [UInt8(0x83), 0x84, 0x85] {
            XCTAssertFalse(NiimbotRequest(command, response: 0x86).allowsExperimentalImageWrite)
            XCTAssertFalse(NiimbotRequest(command, responseAlternatives: [0x86]).allowsExperimentalImageWrite)
            XCTAssertFalse(NiimbotRequest(command, beginsPrint: true).allowsExperimentalImageWrite)
            XCTAssertFalse(NiimbotRequest(command, requiresTrue: true).allowsExperimentalImageWrite)
        }
        for command in [UInt8(0x01), 0x13, 0xa3, 0xe3, 0xf3] {
            XCTAssertFalse(NiimbotRequest(command).allowsExperimentalImageWrite,
                           "A one-way control request must retain the existing transport")
        }
    }

    func testExperimentalTransportSelectsSupportBeforeTransmissionAndSnapshotsItsLimits() {
        let requested = NiimbotImageTransportConfiguration(mode: .pacedWithoutResponse,
            pacingMilliseconds: 20, burstWriteLimit: 2, burstByteLimit: 80)
        let selected = NiimbotImageTransportSelection(requested: requested, identity: d110MIdentity(),
            supportsWithoutResponse: true, maximumResponseWrite: 20, maximumWithoutResponseWrite: 185)
        XCTAssertEqual(selected.mode, .pacedWithoutResponse)
        XCTAssertEqual(selected.fallback, .none)
        XCTAssertEqual(selected.requested, requested)
        XCTAssertEqual(selected.maximumResponseWrite, 20)
        XCTAssertEqual(selected.maximumWithoutResponseWrite, 185)
        XCTAssertTrue(selected.usesWithoutResponse(for: NiimbotRequest(0x85)))
        XCTAssertFalse(selected.usesWithoutResponse(for: NiimbotRequest(0x85, response: 0x86)))

        let legacy = NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34]))
        let cases: [(NiimbotD110Identity, Bool, Int, NiimbotImageTransportSelection.Fallback)] = [
            (legacy, true, 185, .unsupportedModel),
            (d110MIdentity(version: 2), true, 185, .unsupportedModel),
            (d110MIdentity(), false, 185, .unsupportedCharacteristic),
            (d110MIdentity(), true, 0, .invalidWriteSize),
            (d110MIdentity(), true, -1, .invalidWriteSize)
        ]
        for (identity, supported, maximum, reason) in cases {
            let fallback = NiimbotImageTransportSelection(requested: requested, identity: identity,
                supportsWithoutResponse: supported, maximumResponseWrite: 20, maximumWithoutResponseWrite: maximum)
            XCTAssertEqual(fallback.mode, .acknowledged)
            XCTAssertEqual(fallback.fallback, reason)
            XCTAssertFalse(fallback.usesWithoutResponse(for: NiimbotRequest(0x85)))
            XCTAssertGreaterThanOrEqual(fallback.maximumWithoutResponseWrite, 0)
        }
        let baseline = NiimbotImageTransportSelection(requested: .init(), identity: d110MIdentity(),
            supportsWithoutResponse: false, maximumResponseWrite: 20, maximumWithoutResponseWrite: 0)
        XCTAssertEqual(baseline.mode, .acknowledged)
        XCTAssertEqual(baseline.fallback, .none, "The baseline is never silently opted into the experiment")
        XCTAssertFalse(baseline.usesWithoutResponse(for: NiimbotRequest(0x83)))
    }

    func testExperimentalClassificationPreservesCompleteFramesAndPageControlBoundaries() throws {
        var bytes = Data(repeating: 0, count: 12 * 240)
        bytes[12] = 0x80
        for index in 24..<36 { bytes[index] = 0xff }
        let raster = LabelRaster(width: 96, height: 240, data: bytes)
        let selection = NiimbotImageTransportSelection(requested: .init(mode: .pacedWithoutResponse),
            identity: d110MIdentity(), supportsWithoutResponse: true,
            maximumResponseWrite: 20, maximumWithoutResponseWrite: 17)
        let plan = try NiimbotProtocol.continuousRequests(for: [raster, raster, denseRaster], identity: d110MIdentity())
        XCTAssertEqual(plan.groups.map(\.indices), [0..<2, 2..<3], "Adjacent identical copies retain their native grouping")
        var eligibleCommands: Set<UInt8> = []
        for group in plan.groups {
            let rows = group.requests.filter { selection.usesWithoutResponse(for: $0) }
            XCTAssertFalse(rows.isEmpty)
            XCTAssertEqual(group.requests.first?.command, 0xa3)
            XCTAssertEqual(group.requests.last, NiimbotRequest(0xe3, response: 0xe4, requiresTrue: true))
            let firstRow = try XCTUnwrap(group.requests.firstIndex { selection.usesWithoutResponse(for: $0) })
            let lastRow = try XCTUnwrap(group.requests.lastIndex { selection.usesWithoutResponse(for: $0) })
            XCTAssertEqual(Array(group.requests[firstRow...lastRow]), rows,
                           "No control request can be reclassified as an image row inside the upload")
            for request in group.requests {
                let frame = try NiimbotProtocol.encode(command: request.command, data: request.data)
                if selection.usesWithoutResponse(for: request) {
                    eligibleCommands.insert(request.command)
                    XCTAssertLessThanOrEqual(frame.count, NiimbotImageTransportConfiguration.maximumPendingPacketBytes)
                    XCTAssertNil(request.response)
                }
                var parser = NiimbotStreamParser()
                var decoded: [NiimbotPacket] = []
                for offset in stride(from: 0, to: frame.count, by: selection.maximumWithoutResponseWrite) {
                    decoded += parser.append(frame.subdata(in: offset..<min(frame.count, offset + selection.maximumWithoutResponseWrite)))
                }
                XCTAssertEqual(decoded, [NiimbotPacket(command: request.command, data: request.data)],
                               "A negotiated-size split must preserve the entire framed request")
            }
        }
        XCTAssertEqual(eligibleCommands, [0x83, 0x84, 0x85])
        XCTAssertTrue(plan.initialization.allSatisfy { !selection.usesWithoutResponse(for: $0) })
    }

    @MainActor func testExperimentalSelectionKeepsMixedCardOrderRepliesAndPhysicalCompletionTrace() async throws {
        let rasters = [denseRaster, variantRaster(0x7f), variantRaster(0x7f), denseRaster]
        var traces: [[NiimbotRequest]] = []
        for mode in NiimbotImageTransportMode.allCases {
            let selection = NiimbotImageTransportSelection(requested: .init(mode: mode), identity: d110MIdentity(),
                supportsWithoutResponse: true, maximumResponseWrite: 20, maximumWithoutResponseWrite: 185)
            var requests: [NiimbotRequest] = [], groups: [[Int]] = [], receipts: [Int] = []
            var copies = 0, submitted = 0, physicalProof = 0, experimentalRows = 0
            try await NiimbotD110Session.printContinuously(rasters, identity: d110MIdentity(), exchange: { request in
                requests.append(request)
                if selection.usesWithoutResponse(for: request) {
                    experimentalRows += 1
                    XCTAssertNil(request.response, "Experimental rows do not introduce a new printer-reply wait")
                    return nil
                }
                if request.command == 0xdc { return request.response == nil ? nil : self.d110MReadiness }
                if request.command == 0x13 { copies = Int(request.data[4]) << 8 | Int(request.data[5]) }
                if request.command == 0xe3 {
                    submitted += copies
                    XCTAssertLessThanOrEqual(receipts.count, physicalProof,
                                             "Submitting image data and PageEnd acceptance cannot invent physical receipts")
                }
                if request.command == 0xa3 && request.response != nil {
                    physicalProof = submitted
                    return .init(command: 0xb3, data: Data([0, UInt8(physicalProof), 100, 100]))
                }
                if request.command == 0xf3 { XCTAssertEqual(receipts, Array(rasters.indices)) }
                return request.response.map { .init(command: $0, data: Data([1])) }
            }, pause: {}, onPagesWillSend: { groups.append($0) }, onPagesCompleted: { pages in
                XCTAssertEqual(pages.last.map { $0 + 1 }, physicalProof)
                receipts.append(contentsOf: pages)
            })
            XCTAssertEqual(groups, [[0], [1, 2], [3]])
            XCTAssertEqual(receipts, Array(rasters.indices))
            XCTAssertEqual(experimentalRows > 0, mode == .pacedWithoutResponse)
            traces.append(requests)
        }
        XCTAssertEqual(traces[0], traces[1], "Transport selection cannot change a NIIMBOT command, page or copy count")
        XCTAssertEqual(try traces[0].map { try NiimbotProtocol.encode(command: $0.command, data: $0.data) },
                       try traces[1].map { try NiimbotProtocol.encode(command: $0.command, data: $0.data) })
    }

    @MainActor func testExperimentalImageRowsStillRequirePageAcknowledgementAndNeverReplayRejectedPages() async {
        let selection = NiimbotImageTransportSelection(requested: .init(mode: .pacedWithoutResponse),
            identity: d110MIdentity(), supportsWithoutResponse: true,
            maximumResponseWrite: 20, maximumWithoutResponseWrite: 185)
        for failure in ["missing", "wrong-opcode", "rejected"] {
            var requests: [NiimbotRequest] = [], receipts: [Int] = []
            do {
                try await NiimbotD110Session.printContinuously([denseRaster, variantRaster(0x7f)],
                    identity: d110MIdentity(), exchange: { request in
                        requests.append(request)
                        if selection.usesWithoutResponse(for: request) { return nil }
                        if request.command == 0xdc { return self.d110MReadiness }
                        if request.command == 0xe3 {
                            switch failure {
                            case "missing": return nil
                            case "wrong-opcode": return .init(command: 0xf4, data: Data([1]))
                            default: return .init(command: 0xe4, data: Data([0]))
                            }
                        }
                        return request.response.map { .init(command: $0, data: Data([1])) }
                    }, pause: {}, onPagesWillSend: { _ in }, onPagesCompleted: { receipts.append(contentsOf: $0) })
                XCTFail("A submitted page still needs its established positive printer reply")
            } catch {
                XCTAssertEqual(error as? LabelPrinterIssue, failure == "rejected" ? .printerNotReady : .unsupportedResponse)
            }
            XCTAssertTrue(receipts.isEmpty)
            XCTAssertEqual(requests.filter { $0.command == 0xe3 }.count, 1)
            XCTAssertEqual(requests.filter(\.beginsPrint).map(\.command), [0x01, 0x13])
            XCTAssertFalse(requests.contains { $0.command == 0xf3 })
        }
    }

    func testExperimentalMetricsSeparateSubmittedWriteTypesFromConfirmedAndUncertainLabels() {
        let selection = NiimbotImageTransportSelection(requested: .init(mode: .pacedWithoutResponse),
            identity: d110MIdentity(), supportsWithoutResponse: true,
            maximumResponseWrite: 20, maximumWithoutResponseWrite: 185)
        var metrics = NiimbotPrintTransferMetrics(identity: d110MIdentity(), continuous: true, total: 4, transport: selection)
        metrics.recordWrite(command: 0x85, response: nil, copies: 1, byteCount: 17, startsRequest: true, acknowledged: false)
        metrics.recordWrite(command: 0x85, response: nil, copies: 1, byteCount: 8, startsRequest: false, acknowledged: false)
        metrics.recordWrite(command: 0x83, response: 0x86, copies: 1, byteCount: 12, startsRequest: true, acknowledged: true)
        metrics.recordWrite(command: 0xe3, response: 0xe4, copies: 1, byteCount: 8, startsRequest: true, acknowledged: true)
        let submitted = metrics.diagnosticFields(elapsedMilliseconds: 100, uncertainLabels: 2)
        XCTAssertEqual(submitted["response_write_count"], "2")
        XCTAssertEqual(submitted["without_response_write_count"], "2")
        XCTAssertEqual(submitted["wire_bytes"], "45")
        XCTAssertEqual(submitted["image_response_bytes"], "12")
        XCTAssertEqual(submitted["image_without_response_bytes"], "25")
        XCTAssertEqual(submitted["image_response_write_count"], "1")
        XCTAssertEqual(submitted["image_without_response_write_count"], "2")
        XCTAssertEqual(submitted["image_packets"], "2", "Fragments are counted as writes, not additional image requests")
        XCTAssertEqual(submitted["expected_labels"], "4")
        XCTAssertEqual(submitted["confirmed_labels"], "0", "Even an acknowledged control write is not physical proof")
        XCTAssertEqual(submitted["uncertain_labels"], "2")
        metrics.recordPhysicalProof([0, 1])
        metrics.recordPhysicalProof([1])
        metrics.recordPhysicalProof([2, 4]) // Reject the whole malformed receipt.
        let confirmed = metrics.diagnosticFields(elapsedMilliseconds: 120, uncertainLabels: 99)
        XCTAssertEqual(confirmed["confirmed_labels"], "2")
        XCTAssertEqual(confirmed["uncertain_labels"], "2")
        XCTAssertEqual(confirmed["transport_selected"], "paced_without_response")
        XCTAssertEqual(confirmed["firmware_byte_0"], "4")
        XCTAssertEqual(confirmed["firmware_byte_1"], "23")
        XCTAssertEqual(metrics.diagnosticFields(elapsedMilliseconds: 120, uncertainLabels: -1)["uncertain_labels"], "0")
    }

    func testExperimentalCommandMetricsAggregateRequiredResponseOpcodesWithoutImageRowRecords() {
        var metrics = NiimbotPrintTransferMetrics(identity: d110MIdentity(), continuous: true, total: 1)
        metrics.recordRequestSpan(command: 0x85, response: nil, duration: .milliseconds(15))
        metrics.recordCommandWait(command: 0x85, response: nil, actualResponse: nil,
                                  acknowledgement: .zero, reply: .zero)
        for _ in 0..<2 {
            metrics.recordRequestSpan(command: 0xdc, response: 0xdf, duration: .milliseconds(40))
            metrics.recordCommandWait(command: 0xdc, response: 0xdf, actualResponse: 0xde,
                                      acknowledgement: .milliseconds(25), reply: .milliseconds(5))
        }
        metrics.recordRequestSpan(command: 0xe3, response: 0xe4, duration: .milliseconds(30))
        metrics.recordCommandWait(command: 0xe3, response: 0xe4, actualResponse: 0xe4,
                                  acknowledgement: .milliseconds(20), reply: .milliseconds(1))
        XCTAssertEqual(metrics.commandDiagnosticFields, [
            ["request_code": "220", "response_code": "223", "last_response_code": "222", "request_count": "2",
             "elapsed_ms": "80", "att_ack_wait_ms": "50", "printer_reply_wait_ms": "10"],
            ["request_code": "227", "response_code": "228", "last_response_code": "228", "request_count": "1",
             "elapsed_ms": "30", "att_ack_wait_ms": "20", "printer_reply_wait_ms": "1"]
        ])
        XCTAssertEqual(metrics.diagnosticFields(elapsedMilliseconds: 110)["image_transfer_ms"], "15")
        metrics.recordCommandWait(command: 0xdc, response: 0xdf, actualResponse: 0xdf,
                                  acknowledgement: .zero, reply: .zero)
        XCTAssertNil(metrics.commandDiagnosticFields.first?["last_response_code"],
                     "Mixed alternative replies must not be misreported as one exact observed opcode")
    }

    func testExperimentalReadinessAndPacingTimersOverlapAndFlushInterruptionOnlyOnce() {
        let origin = ContinuousClock().now
        var wait = NiimbotImagePumpWaitTiming()
        wait.update(readiness: true, pacing: true, at: origin)
        wait.update(readiness: true, pacing: true, at: origin.advanced(by: .milliseconds(2)))
        wait.update(readiness: false, pacing: true, at: origin.advanced(by: .milliseconds(5)))
        wait.update(readiness: true, pacing: false, at: origin.advanced(by: .milliseconds(10)))
        wait.finish(at: origin.advanced(by: .milliseconds(20)))
        wait.finish(at: origin.advanced(by: .milliseconds(100)))
        XCTAssertEqual(wait.readiness, .milliseconds(15))
        XCTAssertEqual(wait.pacing, .milliseconds(10))
        XCTAssertGreaterThan(wait.readiness + wait.pacing, .milliseconds(20),
                             "These accumulated waits overlap and cannot be summed as job wall time")
        var metrics = NiimbotPrintTransferMetrics(identity: d110MIdentity(), continuous: true, total: 1)
        metrics.add(.withoutResponseReadiness, duration: wait.readiness)
        metrics.add(.withoutResponsePacing, duration: wait.pacing)
        let fields = metrics.diagnosticFields(elapsedMilliseconds: 20)
        XCTAssertEqual(fields["wor_readiness_wait_ms"], "15")
        XCTAssertEqual(fields["wor_pacing_wait_ms"], "10")
        XCTAssertEqual(fields["att_ack_wait_ms"], "0", "Without-response waits must not invent GATT acknowledgement time")
    }

    func testPrintTransferMetricsCountDispatchedFragmentsAndNativeCopiesWithoutArtwork() {
        var metrics = NiimbotPrintTransferMetrics(identity: d110MIdentity(), continuous: true, total: 9)
        let pageData = Data([0, 96, 1, 64, 0, 8, 0, 0, 0, 0, 0, 0, 0])
        let copies = NiimbotPrintTransferMetrics.pageCopies(command: 0x13, data: pageData)
        metrics.recordWrite(command: 0x13, response: 0x14, copies: copies, byteCount: 10, startsRequest: true)
        metrics.recordWrite(command: 0x13, response: 0x14, copies: copies, byteCount: 10, startsRequest: false)
        for command in [UInt8(0x83), 0x84, 0x85] {
            metrics.recordWrite(command: command, response: nil, copies: 1, byteCount: 12, startsRequest: true)
        }
        metrics.recordWrite(command: 0xa3, response: nil, copies: 1, byteCount: 7, startsRequest: true)
        metrics.recordWrite(command: 0xa3, response: 0xb3, copies: 1, byteCount: 7, startsRequest: true)
        metrics.recordWrite(command: 0x13, response: 0x14, copies: 1, byteCount: 20, startsRequest: true)
        XCTAssertEqual(metrics.diagnosticFields(elapsedMilliseconds: 4_000), ["print_task": "buffered_copies", "total": "9",
            "native_groups": "2", "native_copies": "7", "image_packets": "3", "request_count": "7",
            "wire_bytes": "90", "transfer_elapsed_ms": "4000", "status_polls": "1", "print_start_count": "0", "print_end_count": "0",
            "printer_model": "2320", "protocol_version": "4", "command_path": "d110m_v4",
            "firmware_byte_0": "4", "firmware_byte_1": "23", "response_write_count": "8", "without_response_write_count": "0",
            "image_response_bytes": "36", "image_without_response_bytes": "0", "image_response_write_count": "3",
            "image_without_response_write_count": "0", "expected_labels": "9", "confirmed_labels": "0", "uncertain_labels": "0",
            "plan_encode_ms": "0", "packet_encode_ms": "0", "packet_pacing_ms": "0", "att_ack_wait_ms": "0",
            "printer_reply_wait_ms": "0", "status_poll_ms": "0", "status_backoff_ms": "0", "print_start_ms": "0", "print_end_ms": "0",
            "image_transfer_ms": "0", "wor_readiness_wait_ms": "0", "wor_pacing_wait_ms": "0", "page_completion_wait_ms": "0"])
        XCTAssertEqual(metrics.diagnosticFields(elapsedMilliseconds: -1)["transfer_elapsed_ms"], "0")
        XCTAssertEqual(metrics.diagnosticFields(elapsedMilliseconds: 3_600_001)["transfer_elapsed_ms"], "3600000")
        XCTAssertEqual(NiimbotPrintTransferMetrics.pageCopies(command: 0x13, data: Data([0, 96, 1, 64])), 1)
        XCTAssertEqual(NiimbotPrintTransferMetrics.pageCopies(command: 0x85, data: pageData), 1)
        XCTAssertEqual(NiimbotPrintTransferMetrics(identity: d110MIdentity(), continuous: false, total: 1).task, "declared_serial")
        let legacy = NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34]))
        XCTAssertEqual(NiimbotPrintTransferMetrics(identity: legacy, continuous: true, total: 1).task, "legacy_serial")
    }

    func testTransferWaitTimersSeparateEarlyRepliesFromATTAndFlushInterruptedIntervalsOnce() {
        let origin = ContinuousClock().now
        var early = NiimbotTransferWaitTiming()
        early.startAcknowledgement(at: origin)
        early.startReply(at: origin.advanced(by: .milliseconds(10)))
        early.finishReply(at: origin.advanced(by: .milliseconds(20)))
        early.finishAcknowledgement(at: origin.advanced(by: .milliseconds(50)))
        early.finish(at: origin.advanced(by: .milliseconds(60)))
        XCTAssertEqual(early.acknowledgement, .milliseconds(50))
        XCTAssertEqual(early.reply, .zero, "A reply arriving during ATT acknowledgement adds no overlapping reply wait")

        var normal = NiimbotTransferWaitTiming()
        normal.startAcknowledgement(at: origin)
        normal.finishAcknowledgement(at: origin.advanced(by: .milliseconds(20)))
        normal.startAcknowledgement(at: origin.advanced(by: .milliseconds(20)))
        normal.finishAcknowledgement(at: origin.advanced(by: .milliseconds(50)))
        normal.startReply(at: origin.advanced(by: .milliseconds(50)))
        normal.finishReply(at: origin.advanced(by: .milliseconds(80)))
        normal.finish(at: origin.advanced(by: .milliseconds(90)))
        XCTAssertEqual(normal.acknowledgement, .milliseconds(50))
        XCTAssertEqual(normal.reply, .milliseconds(30))

        var failedWrite = NiimbotTransferWaitTiming()
        failedWrite.startAcknowledgement(at: origin)
        failedWrite.finish(at: origin.advanced(by: .milliseconds(120)))
        failedWrite.finish(at: origin.advanced(by: .milliseconds(200)))
        XCTAssertEqual(failedWrite.acknowledgement, .milliseconds(120))
        XCTAssertEqual(failedWrite.reply, .zero)

        var cancelledReply = NiimbotTransferWaitTiming()
        cancelledReply.startReply(at: origin)
        cancelledReply.finish(at: origin.advanced(by: .milliseconds(75)))
        cancelledReply.finish(at: origin.advanced(by: .milliseconds(150)))
        XCTAssertEqual(cancelledReply.reply, .milliseconds(75))
    }

    func testTimingSummaryKeepsCommandPathAndDispatchSpansSeparateFromComponentDurations() {
        let legacy = NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34]))
        XCTAssertEqual(NiimbotProtocol.diagnosticCommandPath(for: legacy), "d110")
        XCTAssertEqual(NiimbotProtocol.diagnosticCommandPath(for: d110MIdentity()), "d110m_v4")
        for version in [0, 1, 3, 5] {
            XCTAssertEqual(NiimbotProtocol.diagnosticCommandPath(for: d110MIdentity(version: version)), "d110m_b1")
        }
        var metrics = NiimbotPrintTransferMetrics(identity: d110MIdentity(), continuous: true, total: 1,
                                                  previousJobGap: .milliseconds(1250))
        metrics.add(.attAcknowledgement, duration: .microseconds(1500))
        metrics.add(.attAcknowledgement, duration: .microseconds(1500))
        metrics.add(.printerReply, duration: .milliseconds(4))
        metrics.add(.packetPacing, duration: .milliseconds(10))
        metrics.add(.statusBackoff, duration: .milliseconds(300))
        metrics.add(.planEncode, duration: .milliseconds(2))
        metrics.add(.packetEncode, duration: .milliseconds(1))
        metrics.recordRequestSpan(command: 0xa3, response: nil, duration: .milliseconds(999))
        metrics.recordRequestSpan(command: 0xa3, response: 0xb3, duration: .milliseconds(17))
        metrics.recordRequestSpan(command: 0x01, response: 0x02, duration: .milliseconds(18))
        metrics.recordRequestSpan(command: 0xf3, response: 0xf4, duration: .milliseconds(19))
        metrics.recordWrite(command: 0x01, response: 0x02, copies: 1, byteCount: 16, startsRequest: true)
        metrics.recordWrite(command: 0x01, response: 0x02, copies: 1, byteCount: 1, startsRequest: false)
        metrics.recordWrite(command: 0xf3, response: 0xf4, copies: 1, byteCount: 8, startsRequest: true)
        let fields = metrics.diagnosticFields(elapsedMilliseconds: 400)
        XCTAssertEqual(fields["att_ack_wait_ms"], "3", "Sum precise durations before truncating to milliseconds")
        XCTAssertEqual(fields["printer_reply_wait_ms"], "4")
        XCTAssertEqual(fields["status_poll_ms"], "17", "The one-way v4 preamble is not a polled status request")
        XCTAssertEqual(fields["print_start_count"], "1"); XCTAssertEqual(fields["print_end_count"], "1")
        XCTAssertEqual(fields["print_start_ms"], "18"); XCTAssertEqual(fields["print_end_ms"], "19")
        XCTAssertEqual(fields["previous_job_gap_ms"], "1250")
        XCTAssertEqual(fields["plan_encode_ms"], "2"); XCTAssertEqual(fields["packet_encode_ms"], "1")
        XCTAssertEqual(fields["packet_pacing_ms"], "10"); XCTAssertEqual(fields["status_backoff_ms"], "300")
        XCTAssertEqual(fields["page_completion_wait_ms"], "317", "Completion waiting combines query spans and deliberate poll pauses")
        XCTAssertNil(NiimbotPrintTransferMetrics(identity: legacy, continuous: false, total: 1)
            .diagnosticFields(elapsedMilliseconds: 0)["previous_job_gap_ms"])
        XCTAssertEqual(NiimbotPrintTransferMetrics.milliseconds(.seconds(7200)), 3_600_000)
        XCTAssertEqual(NiimbotPrintTransferMetrics.milliseconds(.milliseconds(-1)), 0)
    }

    @MainActor func testTenRepeatedAndTenMixedDesignsKeepOneJobAndReportActualCopyReuse() async throws {
        for identical in [true, false] {
            let rasters = identical ? Array(repeating: denseRaster, count: 10) : (1...10).map { variantRaster(UInt8($0)) }
            var metrics = NiimbotPrintTransferMetrics(identity: d110MIdentity(), continuous: true, total: 10)
            var requests: [NiimbotRequest] = [], receipts: [Int] = [], groups: [[Int]] = []
            var submitted = 0, copies = 0, plans = 0, measuredGroups = 0
            var baseline: NiimbotPrintTransferMetrics?
            try await NiimbotD110Session.printContinuously(rasters, identity: d110MIdentity(), exchange: { request in
                requests.append(request)
                metrics.recordWrite(command: request.command, response: request.response,
                    copies: NiimbotPrintTransferMetrics.pageCopies(command: request.command, data: request.data),
                    byteCount: try NiimbotProtocol.encode(command: request.command, data: request.data).count, startsRequest: true)
                if request.command == 0xdc { return request.response == nil ? nil : self.d110MReadiness }
                if request.command == 0x13 { copies = Int(request.data[4]) << 8 | Int(request.data[5]) }
                if request.command == 0xe3 { submitted += copies }
                if request.command == 0xa3 && request.response != nil {
                    return .init(command: 0xb3, data: Data([0, UInt8(submitted), 100, 100]))
                }
                if request.command == 0xf3 { XCTAssertEqual(receipts, Array(0..<10)) }
                return request.response.map { .init(command: $0, data: Data([1])) }
            }, pause: {}, onPagesWillSend: { groups.append($0) }, onPagesCompleted: { receipts.append(contentsOf: $0) },
            onMeasurement: { measurement in
                switch measurement {
                case let .planEncoded(duration):
                    plans += 1; XCTAssertTrue(requests.isEmpty); XCTAssertGreaterThanOrEqual(duration, .zero)
                case .groupStarted: baseline = metrics
                case .groupProgress: break
                case let .groupSubmitted(pages, duration, accepted):
                    measuredGroups += 1
                    XCTAssertTrue(accepted)
                    let fields = metrics.groupFields(since: baseline!, elapsed: duration, pages: pages, accepted: accepted)
                    XCTAssertGreaterThan(Int(fields["group_image_packets"]!)!, 0)
                    XCTAssertEqual(fields["quantity"], String(pages.count))
                }
            })
            XCTAssertEqual(plans, 1); XCTAssertEqual(receipts, Array(0..<10))
            XCTAssertEqual(metrics.groups, identical ? 2 : 10)
            XCTAssertEqual(metrics.nativeCopies, identical ? 8 : 0)
            XCTAssertEqual(measuredGroups, identical ? 2 : 10)
            XCTAssertEqual(groups.map(\.count), identical ? [8, 2] : Array(repeating: 1, count: 10))
            XCTAssertEqual(requests.filter { $0.command == 0x01 }.count, 1)
            XCTAssertEqual(requests.filter { $0.command == 0xf3 }.count, 1)
            XCTAssertEqual(requests.first { $0.command == 0x01 }?.data.prefix(2), Data([0, 10]))
        }
    }

    @MainActor func testPreparedLegacyBatchIsEncodedOnceAndMeasurementsRetainFailedGroup() async throws {
        let identity = NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34]))
        var plans = 0, measured: [(Range<Int>, Bool)] = []
        var page = 0
        do {
            try await NiimbotD110Session.printBatch([denseRaster, variantRaster(0x7f)], identity: identity, exchange: { request in
                if request.command == 0xdc { return .init(command: 0xdd, data: Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 4])) }
                if request.command == 0x85 && page == 1 { throw LabelPrinterIssue.connectionLost }
                if request.command == 0xa3 { return .init(command: 0xb3, data: Data([0, 1, 100, 100])) }
                return request.response.map { .init(command: $0, data: Data([1])) }
            }, pause: {}, onPageWillSend: { page = $0 }, onMeasurement: { measurement in
                switch measurement {
                case .planEncoded: plans += 1
                case let .groupSubmitted(pages, _, accepted): measured.append((pages, accepted))
                case .groupStarted, .groupProgress: break
                }
            })
            XCTFail("Failed upload must not be reported as accepted")
        } catch { XCTAssertEqual(error as? LabelPrinterIssue, .connectionLost) }
        XCTAssertEqual(plans, 1, "The validated legacy plan is reused instead of re-encoding during each print")
        XCTAssertEqual(measured.map { Array($0.0) }, [[0], [1]])
        XCTAssertEqual(measured.map { $0.1 }, [true, false])
    }

    func testUploadFractionAndThrottlePreserveGroupBoundariesAndFinalAcceptance() {
        let origin = ContinuousClock().now
        var throttle = NiimbotUploadProgressThrottle()
        func progress(_ completed: Int, pages: Range<Int> = 0..<8) -> NiimbotUploadProgress {
            .init(pages: pages, completedRequests: completed, totalRequests: 100)
        }
        XCTAssertEqual(progress(0).fraction, 0)
        XCTAssertEqual(progress(25).fraction, 0.25)
        XCTAssertEqual(progress(100).fraction, 1)
        XCTAssertEqual(progress(150).fraction, 1)
        XCTAssertEqual(progress(-1).fraction, 0)
        XCTAssertEqual(NiimbotUploadProgress(pages: 0..<1, completedRequests: 1, totalRequests: 0).fraction, 0)
        XCTAssertTrue(throttle.shouldPublish(progress(0), at: origin))
        XCTAssertFalse(throttle.shouldPublish(progress(1), at: origin.advanced(by: .milliseconds(50))))
        XCTAssertFalse(throttle.shouldPublish(progress(25), at: origin.advanced(by: .milliseconds(199))))
        XCTAssertTrue(throttle.shouldPublish(progress(26), at: origin.advanced(by: .milliseconds(200))))
        XCTAssertFalse(throttle.shouldPublish(progress(90), at: origin.advanced(by: .milliseconds(250))))
        XCTAssertTrue(throttle.shouldPublish(progress(100), at: origin.advanced(by: .milliseconds(251))))
        XCTAssertTrue(throttle.shouldPublish(progress(0, pages: 8..<10), at: origin.advanced(by: .milliseconds(252))))
        throttle.reset()
        XCTAssertTrue(throttle.shouldPublish(progress(0, pages: 8..<10), at: origin.advanced(by: .milliseconds(253))))
    }

    @MainActor func testUploadProgressFollowsValidatedExchangesWithoutPhysicalProofOrReorderingABA() async throws {
        let identity = d110MIdentity()
        let rasters = [denseRaster, variantRaster(0x7f), denseRaster]
        let plan = try NiimbotProtocol.continuousRequests(for: rasters, identity: identity)
        var requests: [NiimbotRequest] = [], receipts: [Int] = [], will: [[Int]] = []
        var progress: [Int: [NiimbotUploadProgress]] = [:]
        var activeGroup: Int?, exchangedInGroup = 0, submitted = 0
        var receiptsAtUploadAcceptance: [Int] = []
        try await NiimbotD110Session.printContinuously(rasters, identity: identity, exchange: { request in
            requests.append(request)
            if activeGroup != nil { exchangedInGroup += 1 }
            if request.command == 0xdc { return request.response == nil ? nil : self.d110MReadiness }
            if request.command == 0xe3 { submitted += 1 }
            if request.command == 0xa3 && request.response != nil {
                return .init(command: 0xb3, data: Data([0, UInt8(submitted), 100, 100]))
            }
            return request.response.map { .init(command: $0, data: Data([1])) }
        }, pause: {}, onPagesWillSend: { will.append($0) }, onPagesCompleted: { pages in
            XCTAssertEqual(requests.last?.command, 0xa3)
            XCTAssertEqual(requests.last?.response, 0xb3)
            receipts.append(contentsOf: pages)
        }, onMeasurement: { measurement in
            switch measurement {
            case .planEncoded: break
            case let .groupStarted(pages): activeGroup = pages.lowerBound; exchangedInGroup = 0
            case let .groupProgress(value):
                XCTAssertEqual(value.completedRequests, exchangedInGroup,
                               "Progress must follow a returned and validated exchange")
                progress[value.pages.lowerBound, default: []].append(value)
                if value.fraction == 1 { receiptsAtUploadAcceptance.append(receipts.count) }
            case .groupSubmitted: activeGroup = nil
            }
        })
        XCTAssertEqual(will, [[0], [1], [2]], "A/B/A keeps its original physical card order")
        XCTAssertEqual(receipts, [0, 1, 2])
        XCTAssertEqual(receiptsAtUploadAcceptance, [0, 0, 2], "Upload acceptance is not physical printing proof")
        for group in plan.groups {
            let values = try XCTUnwrap(progress[group.indices.lowerBound])
            XCTAssertEqual(values.map(\.completedRequests), Array(0...group.requests.count))
            XCTAssertTrue(values.allSatisfy { $0.pages == group.indices && $0.totalRequests == group.requests.count })
            XCTAssertEqual(values.last?.fraction, 1)
        }
        let status = NiimbotRequest(0xa3, response: 0xb3)
        let readiness = NiimbotRequest(0xdc, [4], response: 0xd9, responseAlternatives: [0xdd, 0xd9])
        let expected = [readiness] + plan.initialization + plan.groups[0].requests + plan.groups[1].requests
            + [status] + plan.groups[2].requests + [status, NiimbotRequest(0xf3, response: 0xf4, requiresTrue: true), NiimbotRequest(0xdc, [1])]
        XCTAssertEqual(requests, expected, "Progress introduces no new commands, waits, regrouping or reordered artwork")
    }

    @MainActor func testFailedOrCancelledUploadNeverPublishesFinalAcceptanceOrPhysicalCompletion() async {
        for failure in 0..<3 {
            var progress: [NiimbotUploadProgress] = [], accepted: [Bool] = [], receipts: [Int] = []
            let operation = Task { @MainActor in
                try await NiimbotD110Session.printContinuously([denseRaster, variantRaster(0x7f)], identity: d110MIdentity(),
                    exchange: { request in
                        if request.command == 0xdc { return self.d110MReadiness }
                        if request.command == 0x85 && failure == 0 { throw LabelPrinterIssue.connectionLost }
                        if request.command == 0xe3 && failure == 1 { return .init(command: 0xe4, data: Data([0])) }
                        if request.command == 0x85 && failure == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                        return request.response.map { .init(command: $0, data: Data([1])) }
                    }, pause: {}, onPagesWillSend: { _ in }, onPagesCompleted: { receipts.append(contentsOf: $0) },
                    onMeasurement: { measurement in
                        if case let .groupProgress(value) = measurement { progress.append(value) }
                        if case let .groupSubmitted(_, _, value) = measurement { accepted.append(value) }
                    })
            }
            do { try await operation.value; XCTFail("Interrupted or rejected uploads cannot succeed") }
            catch {
                if failure == 2 { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? LabelPrinterIssue, failure == 0 ? .connectionLost : .printerNotReady) }
            }
            XCTAssertEqual(progress.first?.fraction, 0)
            XCTAssertFalse(progress.contains { $0.fraction == 1 })
            XCTAssertEqual(accepted, [false])
            XCTAssertTrue(receipts.isEmpty)
        }
    }

    func testErrorRepliesPreserveVerifiedIdleOrCompletedLinksWithoutWeakeningRequiredWork() {
        typealias Policy = NiimbotErrorReplyDisposition
        // DB/00 errors and post-end unsolicited 1B/DD/D9 state changes share
        // this operation boundary; required expected statuses stay fatal.
        let requests: [Policy.Request] = [.none, .required, .optionalRoll, .cleanupHeartbeat]
        for request in requests {
            XCTAssertEqual(Policy.resolve(verified: false, settingUp: false, printing: false, configuring: false,
                                          printEndAcknowledged: true, request: request), .disconnect)
            XCTAssertEqual(Policy.resolve(verified: true, settingUp: true, printing: false, configuring: false,
                                          printEndAcknowledged: true, request: request), .disconnect)
            for printing in [false, true] {
                XCTAssertEqual(Policy.resolve(verified: true, settingUp: false, printing: printing, configuring: true,
                    printEndAcknowledged: true, request: request), request == .optionalRoll ? .rejectOptionalRoll : .disconnect)
            }
            XCTAssertEqual(Policy.resolve(verified: true, settingUp: false, printing: false, configuring: false,
                printEndAcknowledged: false, request: request), request == .none ? .warnConnected
                    : request == .optionalRoll ? .rejectOptionalRoll : .disconnect)
            XCTAssertEqual(Policy.resolve(verified: true, settingUp: false, printing: true, configuring: false,
                printEndAcknowledged: false, request: request), request == .optionalRoll ? .rejectOptionalRoll : .disconnect)
            XCTAssertEqual(Policy.resolve(verified: true, settingUp: false, printing: true, configuring: false,
                printEndAcknowledged: true, request: request), request == .optionalRoll ? .rejectOptionalRoll
                    : request == .required ? .disconnect : .warnConnected)
        }
    }

    @MainActor func testContinuousIdenticalCopiesUploadOncePerEightCopyGroupAndBoundTheWindowToSixteen() async throws {
        var requests: [NiimbotRequest] = []
        var will: [[Int]] = [], receipts: [[Int]] = []
        var submitted = 0, quantity = 0, polls = 0
        try await NiimbotD110Session.printContinuously(Array(repeating: denseRaster, count: 17), identity: d110MIdentity(), exchange: { request in
            requests.append(request)
            if request.command == 0xdc { return request.response == nil ? nil : self.d110MReadiness }
            if request.command == 0x13 { quantity = Int(request.data[4]) << 8 | Int(request.data[5]) }
            if request.command == 0xe3 { submitted += quantity }
            if request.command == 0xa3 {
                guard request.response != nil else { return nil }
                XCTAssertEqual(submitted, polls == 0 ? 16 : 17)
                polls += 1
                return .init(command: 0xb3, data: Data([0, polls == 1 ? 8 : 17, 100, 100]))
            }
            return request.response.map { .init(command: $0, data: Data([1])) }
        }, pause: {}, onPagesWillSend: { will.append($0) }, onPagesCompleted: { receipts.append($0) })
        XCTAssertEqual(will, [Array(0..<8), Array(8..<16), [16]])
        XCTAssertEqual(receipts, [Array(0..<8), Array(8..<17)])
        XCTAssertEqual(requests.filter { $0.command == 0x13 }.map { $0.data.subdata(in: 4..<6) },
                       [Data([0, 8]), Data([0, 8]), Data([0, 1])])
        let singleRows = try NiimbotProtocol.printRequests(for: denseRaster, identity: d110MIdentity()).filter { $0.command == 0x85 }
        XCTAssertEqual(requests.filter { $0.command == 0x85 }.count, singleRows.count * 3)
        XCTAssertEqual(polls, 2)
    }

    @MainActor func testContinuousStorageFailuresHaltBeforeAnyFurtherGroupAndNeverReplay() async throws {
        let rasters = [denseRaster, variantRaster(0x7f), variantRaster(0x3f), variantRaster(0x1f)]
        for failure in 0..<4 {
            var requests: [NiimbotRequest] = []
            var will: [[Int]] = [], receipts: [[Int]] = []
            var submitted = 0
            do {
                try await NiimbotD110Session.printContinuously(rasters, identity: d110MIdentity(), exchange: { request in
                    requests.append(request)
                    if request.command == 0xdc { return self.d110MReadiness }
                    if request.command == 0xe3 { submitted += 1 }
                    if request.command == 0xa3 {
                        return request.response == nil ? nil : .init(command: 0xb3, data: Data([0, 1, 100, 100]))
                    }
                    return request.response.map { .init(command: $0, data: Data([1])) }
                }, pause: {}, onPagesWillSend: { indices in
                    will.append(indices)
                    if failure < 3 && indices == [failure] { throw LabelPrinterIssue.writeFailed }
                }, onPagesCompleted: { indices in
                    receipts.append(indices)
                    if failure == 3 { throw LabelPrinterIssue.writeFailed }
                })
                XCTFail("A failed durable callback cannot permit another upload")
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .writeFailed) }
            XCTAssertEqual(submitted, failure == 0 ? 0 : failure == 1 ? 1 : 2)
            XCTAssertEqual(will, failure == 0 ? [[0]] : failure == 2 ? [[0], [1], [2]] : [[0], [1]])
            XCTAssertEqual(receipts, failure < 2 ? [] : [[0]])
            XCTAssertEqual(requests.filter { $0.command == 0x01 }.count, failure == 0 ? 0 : 1)
            XCTAssertFalse(requests.contains { $0.command == 0xf3 })
        }
    }

    @MainActor func testContinuousPartialCopyReceiptSaveFailurePreservesProofAndLeavesLaterGroupsUnsent() async throws {
        var will: [[Int]] = [], receipts: [[Int]] = []
        var submitted = 0, quantity = 0
        do {
            try await NiimbotD110Session.printContinuously(Array(repeating: denseRaster, count: 24), identity: d110MIdentity(), exchange: { request in
                if request.command == 0xdc { return self.d110MReadiness }
                if request.command == 0x13 { quantity = Int(request.data[5]) }
                if request.command == 0xe3 { submitted += quantity }
                if request.command == 0xa3 {
                    return request.response == nil ? nil : .init(command: 0xb3, data: Data([0, 3, 100, 100]))
                }
                return request.response.map { .init(command: $0, data: Data([1])) }
            }, pause: {}, onPagesWillSend: { will.append($0) }, onPagesCompleted: {
                receipts.append($0)
                throw LabelPrinterIssue.writeFailed
            })
            XCTFail("Known physical copies must be forwarded without dispatching another group after a failed save")
        } catch { XCTAssertEqual(error as? LabelPrinterIssue, .writeFailed) }
        XCTAssertEqual(submitted, 16)
        XCTAssertEqual(will, [Array(0..<8), Array(8..<16)])
        XCTAssertEqual(receipts, [[0, 1, 2]])
    }

    @MainActor func testContinuousCounterMustStayMonotonicAndWithinPhysicallySubmittedCopies() async throws {
        let rasters = [denseRaster, variantRaster(0x7f), variantRaster(0x3f), variantRaster(0x1f)]
        for counters in [[3], [5], [1, 0]] {
            var will: [[Int]] = [], receipts: [[Int]] = []
            var requests: [NiimbotRequest] = []
            var polls = 0
            do {
                try await NiimbotD110Session.printContinuously(rasters, identity: d110MIdentity(), exchange: { request in
                    requests.append(request)
                    if request.command == 0xdc { return self.d110MReadiness }
                    if request.command == 0xa3 {
                        guard request.response != nil else { return nil }
                        let count = counters[min(polls, counters.count - 1)]
                        polls += 1
                        return .init(command: 0xb3, data: Data([0, UInt8(count), 100, 100]))
                    }
                    return request.response.map { .init(command: $0, data: Data([1])) }
                }, pause: {}, onPagesWillSend: { will.append($0) }, onPagesCompleted: { receipts.append($0) })
                XCTFail("A regressed counter or proof for an unsent copy must be rejected")
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .unsupportedResponse) }
            XCTAssertEqual(will, counters.count == 1 ? [[0], [1]] : [[0], [1], [2]])
            XCTAssertEqual(receipts, counters.count == 1 ? [] : [[0]])
            XCTAssertEqual(requests.filter { $0.command == 0x01 }.count, 1)
            XCTAssertFalse(requests.contains { $0.command == 0xf3 })
        }
    }

    @MainActor func testContinuousDisconnectDuringSecondGroupCannotDispatchFutureCopiesOrReplay() async throws {
        var will: [[Int]] = [], receipts: [[Int]] = []
        var requests: [NiimbotRequest] = []
        var groupSizes = 0, pageEnds = 0
        do {
            try await NiimbotD110Session.printContinuously(Array(repeating: denseRaster, count: 24), identity: d110MIdentity(), exchange: { request in
                requests.append(request)
                if request.command == 0xdc { return self.d110MReadiness }
                if request.command == 0x13 { groupSizes += 1 }
                if request.command == 0x85 && groupSizes == 2 { throw LabelPrinterIssue.connectionLost }
                if request.command == 0xe3 { pageEnds += 1 }
                return request.response.map { .init(command: $0, data: Data([1])) }
            }, pause: {}, onPagesWillSend: { will.append($0) }, onPagesCompleted: { receipts.append($0) })
            XCTFail("A failed upload must leave future groups untouched")
        } catch { XCTAssertEqual(error as? LabelPrinterIssue, .connectionLost) }
        XCTAssertEqual(will, [Array(0..<8), Array(8..<16)])
        XCTAssertTrue(receipts.isEmpty)
        XCTAssertEqual(pageEnds, 1)
        XCTAssertEqual(requests.filter { $0.command == 0x01 }.count, 1)
        XCTAssertFalse(requests.contains { $0.command == 0xf3 })
    }

    @MainActor func testContinuousCancellationAfterCounterStillForwardsEveryProvenCopyBeforeStoppingRefill() async {
        let rasters = [denseRaster, variantRaster(0x7f), variantRaster(0x3f)]
        var will: [[Int]] = [], receipts: [[Int]] = []
        var pageEnds = 0
        let operation = Task { @MainActor in
            try await NiimbotD110Session.printContinuously(rasters, identity: d110MIdentity(), exchange: { request in
                if request.command == 0xdc { return self.d110MReadiness }
                if request.command == 0xe3 { pageEnds += 1 }
                if request.command == 0xa3 {
                    guard request.response != nil else { return nil }
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .init(command: 0xb3, data: Data([0, 1, 100, 100]))
                }
                return request.response.map { .init(command: $0, data: Data([1])) }
            }, pause: {}, onPagesWillSend: { will.append($0) }, onPagesCompleted: { receipts.append($0) })
        }
        do {
            try await operation.value
            XCTFail("A cancelled task must not refill the third group")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(will, [[0], [1]])
        XCTAssertEqual(receipts, [[0]])
        XCTAssertEqual(pageEnds, 2)
    }

    @MainActor func testContinuousPollingTimesOutOnlyAfterOneHundredPollsWithoutPhysicalProgress() async throws {
        let rasters = [denseRaster, variantRaster(0x7f), variantRaster(0x3f)]
        for makesProgress in [false, true] {
            var polls = 0, pauses = 0
            var receipts: [[Int]] = []
            do {
                try await NiimbotD110Session.printContinuously(rasters, identity: d110MIdentity(), exchange: { request in
                    if request.command == 0xdc { return self.d110MReadiness }
                    if request.command == 0xa3 {
                        guard request.response != nil else { return nil }
                        polls += 1
                        let count = !makesProgress || polls < 100 ? 0 : polls < 200 ? 1 : 3
                        return .init(command: 0xb3, data: Data([0, UInt8(count), 100, 100]))
                    }
                    return request.response.map { .init(command: $0, data: Data([1])) }
                }, pause: { pauses += 1 }, onPagesWillSend: { _ in }, onPagesCompleted: { receipts.append($0) })
                XCTAssertTrue(makesProgress)
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .responseTimeout); XCTAssertFalse(makesProgress) }
            XCTAssertEqual(polls, makesProgress ? 200 : 100)
            XCTAssertEqual(pauses, makesProgress ? 198 : 99, "Every unfinished counter waits before its next poll")
            XCTAssertEqual(receipts, makesProgress ? [[0], [1, 2]] : [])
        }
    }

    @MainActor func testContinuousLegacyFallbackRemainsSerialAndPreflightRejectsInvalidLaterPages() async throws {
        let identity = NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34]))
        var will: [[Int]] = [], receipts: [[Int]] = []
        var starts = 0, ends = 0
        try await NiimbotD110Session.printContinuously([denseRaster, denseRaster], identity: identity, exchange: { request in
            if request.command == 0xdc { return .init(command: 0xdd, data: Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 4])) }
            if request.command == 0x01 { starts += 1; XCTAssertEqual(receipts.count, starts - 1) }
            if request.command == 0xf3 { ends += 1 }
            if request.command == 0xa3 { return .init(command: 0xb3, data: Data([0, 1, 100, 100])) }
            return request.response.map { .init(command: $0, data: Data([1])) }
        }, pause: {}, onPagesWillSend: { will.append($0) }, onPagesCompleted: { receipts.append($0) })
        XCTAssertEqual(will, [[0], [1]]); XCTAssertEqual(receipts, [[0], [1]])
        XCTAssertEqual(starts, 2); XCTAssertEqual(ends, 2)

        let invalid = LabelRaster(width: 96, height: 801, data: Data(repeating: 0xff, count: 12 * 801))
        for rasters in [[], [denseRaster, invalid], Array(repeating: denseRaster, count: 251)] {
            var exchanges = 0, callbacks = 0
            do {
                try await NiimbotD110Session.printContinuously(rasters, identity: d110MIdentity(),
                    exchange: { _ in exchanges += 1; return nil }, pause: {},
                    onPagesWillSend: { _ in callbacks += 1 }, onPagesCompleted: { _ in callbacks += 1 })
                XCTFail("The whole batch must validate before radio or write-ahead activity")
            } catch { XCTAssertEqual(error as? LabelPrinterIssue, .invalidLabel) }
            XCTAssertEqual(exchanges, 0); XCTAssertEqual(callbacks, 0)
        }
    }

    @MainActor func testSingleLabelContinuousTraceExactlyMatchesTheEstablishedSerialWorkflow() async throws {
        let legacy = NiimbotD110Identity(modelID: 2304, protocolVersion: 1, firmwareBytes: Data([5, 34]))
        for identity in [legacy, d110MIdentity(version: 1), d110MIdentity()] {
            var traces: [[NiimbotRequest]] = []
            for continuous in [false, true] {
                var requests: [NiimbotRequest] = []
                var will: [[Int]] = [], receipts: [[Int]] = []
                let exchange: NiimbotD110Session.Exchange = { request in
                    requests.append(request)
                    if request.command == 0xdc {
                        guard request.response != nil else { return nil }
                        return identity.modelID == 2320 ? self.d110MReadiness
                            : .init(command: 0xdd, data: Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 4]))
                    }
                    if request.command == 0xa3 {
                        return request.response == nil ? nil : .init(command: 0xb3, data: Data([0, 1, 100, 100]))
                    }
                    return request.response.map { .init(command: $0, data: Data([1])) }
                }
                if continuous {
                    try await NiimbotD110Session.printContinuously([denseRaster], identity: identity,
                        exchange: exchange, pause: {}, onPagesWillSend: { will.append($0) },
                        onPagesCompleted: { receipts.append($0) })
                } else {
                    try await NiimbotD110Session.printBatch([denseRaster], identity: identity,
                        exchange: exchange, pause: {}, onPageWillSend: { will.append([$0]) },
                        onPageCompleted: { receipts.append([$0]) })
                }
                XCTAssertEqual(will, [[0]]); XCTAssertEqual(receipts, [[0]])
                traces.append(requests)
            }
            XCTAssertEqual(traces[0], traces[1], "One-label jobs retain every command, ordering and dispatch marker")
            XCTAssertEqual(try traces[0].map { try NiimbotProtocol.encode(command: $0.command, data: $0.data) },
                           try traces[1].map { try NiimbotProtocol.encode(command: $0.command, data: $0.data) },
                           "Continuous buffering cannot change the proven single-label wire bytes or checksums")
        }
    }
}
