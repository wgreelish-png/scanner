import Foundation
import XCTest
@testable import CardShowScanner

final class NiimbotProtocolTests: XCTestCase {
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
        XCTAssertThrowsError(try NiimbotProtocol.printRequests(for: .init(width: 96, height: 241,
            data: Data(repeating: 0xff, count: 241 * 12))))
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
        let identity = try await NiimbotD110Session.identify { request in
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
    }

    @MainActor func testD110MHandshakeUsesCapturedHeadFirmwareAndProtocolWithoutLegacyFirmwareQuery() async throws {
        var requests: [NiimbotRequest] = []
        let identity = try await NiimbotD110Session.identify { request in
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
        }
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
        for raster in [LabelRaster(width: 96, height: 241, data: Data(repeating: 0xff, count: 12 * 241)),
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
}
