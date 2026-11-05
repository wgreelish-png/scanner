import XCTest
@testable import CardShowScanner

@MainActor final class NiimbotRollReadCoordinatorTests: XCTestCase {
    private func estimate(used: Int = 9) -> NiimbotRollEstimate {
        NiimbotRollEstimate(productCode: "TESTSKU84", totalLabels: 84, usedLabels: used, labelType: 1)
    }

    private func waitForRead(_ gate: RollReadGate) async {
        for _ in 0..<100 where !gate.waiting { await Task.yield() }
        XCTAssertTrue(gate.waiting, "The optional read did not start")
    }

    func testRefreshIsSingleFlightAndPublishesOnlyAnActualCompletedRead() async {
        let reader = NiimbotRollReadCoordinator(), gate = RollReadGate()
        XCTAssertTrue(reader.refresh { try await gate.read() })
        XCTAssertFalse(reader.refresh { XCTFail("A second command cannot interleave"); return self.estimate() })
        await waitForRead(gate)
        XCTAssertTrue(reader.isReading); XCTAssertNil(reader.estimate); XCTAssertEqual(reader.freshness, .unknown)
        gate.finish(.success(estimate()))
        await reader.waitUntilIdle()
        XCTAssertFalse(reader.isReading); XCTAssertEqual(reader.freshness, .fresh)
        XCTAssertEqual(reader.estimate?.remainingLabels, 75)
    }

    func testPrintOrPaperChangeInvalidatesAnEarlierReadAndDrainsItBeforeNewWork() async {
        let reader = NiimbotRollReadCoordinator(), gate = RollReadGate()
        reader.refresh { self.estimate() }; await reader.waitUntilIdle()
        reader.refresh { try await gate.read() }; await waitForRead(gate)
        reader.markStale()
        var drained = false
        let foregroundWork = Task { @MainActor in await reader.waitUntilIdle(); drained = true }
        await Task.yield()
        XCTAssertFalse(drained, "Foreground commands wait until the existing request leaves the channel")
        XCTAssertEqual(reader.freshness, .stale)
        gate.finish(.success(estimate(used: 10)))
        await foregroundWork.value
        XCTAssertTrue(drained); XCTAssertFalse(reader.isReading)
        XCTAssertEqual(reader.estimate?.remainingLabels, 75, "The pre-print reply cannot refresh a post-print estimate")
        XCTAssertEqual(reader.freshness, .stale)
        reader.refresh { self.estimate(used: 10) }; await reader.waitUntilIdle()
        XCTAssertEqual(reader.estimate?.remainingLabels, 74); XCTAssertEqual(reader.freshness, .fresh)
    }

    func testDisconnectCancelsPublicationAndLateReplyCannotClearANewerConnectionRead() async {
        let reader = NiimbotRollReadCoordinator(), old = RollReadGate(), current = RollReadGate()
        reader.refresh { try await old.read() }; await waitForRead(old)
        reader.reset()
        XCTAssertNil(reader.estimate); XCTAssertEqual(reader.freshness, .unknown); XCTAssertFalse(reader.isReading)
        reader.refresh { try await current.read() }; await waitForRead(current)
        old.finish(.success(estimate()))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(reader.isReading); XCTAssertNil(reader.estimate)
        current.finish(.success(estimate(used: 20)))
        await reader.waitUntilIdle()
        XCTAssertEqual(reader.estimate?.remainingLabels, 64); XCTAssertEqual(reader.freshness, .fresh)
    }

    func testUnsupportedMissingAndFailedReadsRemainUnknownInsteadOfInventingZero() async {
        let reader = NiimbotRollReadCoordinator()
        reader.refresh { throw LabelPrinterIssue.unsupportedResponse }; await reader.waitUntilIdle()
        XCTAssertNil(reader.estimate); XCTAssertEqual(reader.freshness, .unavailable)
        reader.refresh { nil }; await reader.waitUntilIdle()
        XCTAssertNil(reader.estimate); XCTAssertEqual(reader.freshness, .unavailable)
        reader.refresh { self.estimate(used: 84) }; await reader.waitUntilIdle()
        XCTAssertEqual(reader.estimate?.remainingLabels, 0); XCTAssertEqual(reader.freshness, .fresh)
        reader.refresh { throw LabelPrinterIssue.responseTimeout }; await reader.waitUntilIdle()
        XCTAssertEqual(reader.estimate?.remainingLabels, 0); XCTAssertEqual(reader.freshness, .stale)
    }

    func testAbandonedReadQuarantinesFurtherReadsAndConsumesOnlyOneCompatibleLateReply() {
        for late: UInt8 in [0x00, 0x1b] {
            var guardState = NiimbotOptionalRollReplyGuard()
            guardState.abandonRead(wasSent: true)
            XCTAssertTrue(guardState.isQuarantined)
            XCTAssertFalse(guardState.consumeLateResponse(0x31), "A required density acknowledgement remains owned by its command")
            XCTAssertFalse(guardState.consumeLateResponse(0xdb), "A print error must remain fatal")
            XCTAssertTrue(guardState.consumeLateResponse(late))
            XCTAssertFalse(guardState.consumeLateResponse(0x00), "The exception cannot suppress unsupported replies indefinitely")
            XCTAssertFalse(guardState.consumeLateResponse(0x1b))
            XCTAssertTrue(guardState.isQuarantined, "Receiving a late reply cannot permit a same-opcode query on this connection")
            guardState = NiimbotOptionalRollReplyGuard()
            XCTAssertFalse(guardState.isQuarantined, "Only a new connection clears correlation ambiguity")
        }
    }

    func testUnsentCancellationNeedsNoLateReplyExceptionAndKnownUnsupportedDoesNotConsumeOtherCommands() {
        var guardState = NiimbotOptionalRollReplyGuard()
        guardState.abandonRead(wasSent: false)
        XCTAssertFalse(guardState.isQuarantined); XCTAssertFalse(guardState.consumeLateResponse(0x00))
        guardState.markUnsupported()
        XCTAssertTrue(guardState.isQuarantined); XCTAssertFalse(guardState.consumeLateResponse(0x00))
    }
}

@MainActor private final class RollReadGate {
    private var continuation: CheckedContinuation<NiimbotRollEstimate?, Error>?
    var waiting: Bool { continuation != nil }
    func read() async throws -> NiimbotRollEstimate? {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<NiimbotRollEstimate?, Error>) {
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}
