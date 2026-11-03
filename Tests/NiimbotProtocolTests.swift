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

    func testDiscoveryNamesExcludeD110MAndProtocolRejectsOtherHardware() throws {
        XCTAssertTrue(NiimbotProtocol.isD110Advertisement("D110_BLE_1234"))
        XCTAssertTrue(NiimbotProtocol.isD110Advertisement("D110"))
        XCTAssertFalse(NiimbotProtocol.isD110Advertisement("D110M_BLE_1234"))
        XCTAssertFalse(NiimbotProtocol.isD110Advertisement("D110_M"))
        XCTAssertFalse(NiimbotProtocol.isD110Advertisement("B1_1234"))
        XCTAssertEqual(try NiimbotProtocol.modelID(.init(command: 0x48, data: Data([9]))), 2304)
        XCTAssertEqual(try NiimbotProtocol.modelID(.init(command: 0x48, data: Data([9, 1]))), 2305)
        XCTAssertThrowsError(try NiimbotProtocol.validateModel(2320))
        XCTAssertThrowsError(try NiimbotProtocol.validateModel(2305))
        XCTAssertThrowsError(try NiimbotProtocol.validateModel(2305, headInfo: .init(
            command: 0xdf, data: Data([1, 0, 1, 0, 0, 120, 2, 0, 0, 0]))))
        XCTAssertNoThrow(try NiimbotProtocol.validateModel(2305, headInfo: .init(
            command: 0xde, data: Data([1, 0, 1, 0, 0, 96, 2, 0, 0, 0]))))
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
