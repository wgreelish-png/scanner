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

    func testAutomaticRefreshReusesRecentMetadataWithoutAnotherReadOrPublication() async {
        let reader = NiimbotRollReadCoordinator()
        let info = NiimbotRollInfo(estimate: estimate())
        var reads = 0, publications = 0
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: { reads += 1; return info },
            onUpdate: { _ in publications += 1 }), .read)
        await reader.waitUntilIdle()
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: {
            XCTFail("A recent successful read must satisfy automatic consumers"); return nil
        }, onUpdate: { _ in publications += 1 }), .cache)
        XCTAssertEqual(reads, 1); XCTAssertEqual(publications, 1)
        XCTAssertEqual(reader.info, info); XCTAssertEqual(reader.freshness, .fresh)
    }

    func testExplicitRefreshStillReadsWhenAutomaticMetadataCacheIsFresh() async {
        let reader = NiimbotRollReadCoordinator()
        let first = NiimbotRollInfo(estimate: estimate())
        let latest = NiimbotRollInfo(estimate: estimate(used: 12))
        reader.refreshInfoIfNeeded(load: { first }); await reader.waitUntilIdle()
        var reads = 0
        XCTAssertTrue(reader.refreshInfo(load: { reads += 1; return latest }))
        await reader.waitUntilIdle()
        XCTAssertEqual(reads, 1); XCTAssertEqual(reader.info, latest)
        XCTAssertEqual(reader.estimate?.remainingLabels, 72)
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: { XCTFail("The forced result is now cached"); return nil }), .cache)
    }

    func testAutomaticRefreshSharesThePendingReadInsteadOfUsingEarlierMetadata() async {
        let reader = NiimbotRollReadCoordinator(), gate = RollInfoReadGate()
        let first = NiimbotRollInfo(estimate: estimate())
        let latest = NiimbotRollInfo(estimate: estimate(used: 12))
        reader.refreshInfo(load: { first }); await reader.waitUntilIdle()
        reader.refreshInfo(load: { try await gate.read() }); await waitForInfoRead(gate)
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: { XCTFail("Only one metadata command may own the channel"); return nil }), .inFlight)
        gate.finish(latest)
        await reader.waitUntilIdle()
        XCTAssertEqual(reader.info, latest)
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: { XCTFail("The pending result should be cached"); return nil }), .cache)
    }

    func testAutomaticMetadataCacheExpiresAtThirtySecondsAndRejectsClockRollback() async {
        let clock = RollReadClock(), reader = NiimbotRollReadCoordinator(now: { clock.uptime })
        let info = NiimbotRollInfo(estimate: estimate())
        var reads = 0
        reader.refreshInfoIfNeeded(load: { reads += 1; return info }); await reader.waitUntilIdle()
        clock.uptime = 129.999
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: { reads += 1; return info }), .cache)
        clock.uptime = 130
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: { reads += 1; return info }), .read)
        await reader.waitUntilIdle()
        clock.uptime = 129
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: { reads += 1; return info }), .read)
        await reader.waitUntilIdle()
        XCTAssertEqual(reads, 3)
    }

    func testPrintingPhysicalChangesAndDisconnectImmediatelyInvalidateAutomaticCache() async {
        let reader = NiimbotRollReadCoordinator()
        let first = NiimbotRollInfo(estimate: estimate())
        let latest = NiimbotRollInfo(estimate: estimate(used: 12))
        reader.refreshInfoIfNeeded(load: { first }); await reader.waitUntilIdle()
        reader.markStale()
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: { latest }), .read)
        await reader.waitUntilIdle()
        XCTAssertEqual(reader.estimate?.remainingLabels, 72)
        reader.reset()
        XCTAssertNil(reader.info)
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: { first }), .read)
        await reader.waitUntilIdle()
        XCTAssertEqual(reader.estimate?.remainingLabels, 75)
    }

    func testMetadataWithoutRemainingCountersCachesButFailedAndMissingReadsDoNot() async {
        let reader = NiimbotRollReadCoordinator()
        let info = NiimbotRollInfo(productCode: "120425109", totalLabels: 0, usedLabels: 0, labelType: 1)
        reader.refreshInfoIfNeeded(load: { info }); await reader.waitUntilIdle()
        XCTAssertEqual(reader.freshness, .unavailable); XCTAssertNil(reader.estimate)
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: { XCTFail("Valid geometry can be cached without a remaining count"); return nil }), .cache)
        reader.refreshInfo(load: { throw LabelPrinterIssue.responseTimeout }); await reader.waitUntilIdle()
        XCTAssertNil(reader.info, "An unsuccessful fresh read cannot keep a stale physical stock identity")
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: { nil }), .read)
        await reader.waitUntilIdle()
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: { info }), .read)
        await reader.waitUntilIdle()
        XCTAssertEqual(reader.info, info)
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

    func testValidProductPublishesEvenWhenRemainingCountersAreUnavailable() async {
        let reader = NiimbotRollReadCoordinator()
        let info = NiimbotRollInfo(productCode: "120425109", totalLabels: 0, usedLabels: 0, labelType: 1)
        var updates: [NiimbotRollInfo?] = []
        reader.refreshInfo(load: { info }, onUpdate: { updates.append($0) })
        await reader.waitUntilIdle()
        XCTAssertEqual(updates, [info]); XCTAssertEqual(reader.info, info)
        XCTAssertNil(reader.estimate); XCTAssertEqual(reader.freshness, .unavailable)
        XCTAssertEqual(reader.info?.matchedProduct(in: .shared)?.code, "120425109")
    }

    func testMissingOrFailedReadClearsProductPublicationWithoutInventingCounters() async {
        let reader = NiimbotRollReadCoordinator()
        let info = NiimbotRollInfo(estimate: estimate())
        var updates: [NiimbotRollInfo?] = []
        reader.refreshInfo(load: { info }, onUpdate: { updates.append($0) }); await reader.waitUntilIdle()
        reader.refreshInfo(load: { throw LabelPrinterIssue.responseTimeout }, onUpdate: { updates.append($0) })
        await reader.waitUntilIdle()
        XCTAssertEqual(updates.count, 2); XCTAssertNil(updates[1]); XCTAssertNil(reader.info)
        XCTAssertEqual(reader.estimate?.remainingLabels, 75); XCTAssertEqual(reader.freshness, .stale)
        reader.refreshInfo(load: { nil }, onUpdate: { updates.append($0) }); await reader.waitUntilIdle()
        XCTAssertEqual(updates.count, 3); XCTAssertNil(updates[2]); XCTAssertNil(reader.info)
        XCTAssertNil(reader.estimate); XCTAssertEqual(reader.freshness, .unavailable)
    }

    func testForegroundWorkDrainsTheReadBeforeMarkingOnlyItsCountStale() async {
        let reader = NiimbotRollReadCoordinator(), gate = RollInfoReadGate()
        let info = NiimbotRollInfo(productCode: "120425109", totalLabels: 84, usedLabels: 9, labelType: 1)
        var published: NiimbotRollInfo?
        reader.refreshInfo(load: { try await gate.read() }, onUpdate: { published = $0 })
        await waitForInfoRead(gate)
        let foreground = Task { @MainActor in
            await reader.waitUntilIdle()
            reader.markStale()
        }
        gate.finish(info)
        await foreground.value
        XCTAssertEqual(published, info); XCTAssertEqual(reader.info, info)
        XCTAssertEqual(reader.estimate?.remainingLabels, 75); XCTAssertEqual(reader.freshness, .stale)
    }

    func testPhysicalChangeFenceDoesNotPublishAnEarlierProductIntoPaperPreferences() async {
        let reader = NiimbotRollReadCoordinator(), gate = RollInfoReadGate()
        let initial = NiimbotRollInfo(productCode: "02242207", totalLabels: 84, usedLabels: 9, labelType: 1)
        let incoming = NiimbotRollInfo(productCode: "120425109", totalLabels: 84, usedLabels: 10, labelType: 1)
        var published: NiimbotRollInfo?
        reader.refreshInfo(load: { initial }, onUpdate: { published = $0 }); await reader.waitUntilIdle()
        reader.refreshInfo(load: { try await gate.read() }, onUpdate: { published = $0 }); await waitForInfoRead(gate)
        reader.markStale()
        gate.finish(incoming)
        await reader.waitUntilIdle()
        XCTAssertEqual(published, initial); XCTAssertEqual(reader.info, initial)
        XCTAssertEqual(reader.freshness, .stale)
    }

    func testSupersededAutomaticReadReleasesTheChannelBeforeOneRecoveryPublishesCurrentStock() async {
        let reader = NiimbotRollReadCoordinator(), old = RollInfoReadGate(), current = RollInfoReadGate()
        let obsolete = NiimbotRollInfo(productCode: "02242207", totalLabels: 84, usedLabels: 9, labelType: 1)
        let replacement = NiimbotRollInfo(productCode: "120425109", totalLabels: 84, usedLabels: 10, labelType: 1)
        var publications: [NiimbotRollInfo?] = []
        var reads = 0, recoveries = 0
        XCTAssertEqual(reader.refreshInfoIfNeeded(load: {
            reads += 1
            return try await old.read()
        }, onUpdate: { publications.append($0) }, onSuperseded: {
            recoveries += 1
            XCTAssertFalse(reader.isReading, "Recovery must own a new single-flight read")
            XCTAssertTrue(publications.isEmpty, "The superseded response must not restore obsolete stock")
            XCTAssertEqual(reader.refreshInfoIfNeeded(load: {
                reads += 1
                return try await current.read()
            }, onUpdate: { publications.append($0) }), .read)
        }), .read)
        await waitForInfoRead(old)
        reader.markStale(); reader.markStale(); reader.markStale()
        old.finish(obsolete)
        await waitForInfoRead(current)
        XCTAssertEqual(reads, 2); XCTAssertEqual(recoveries, 1)
        XCTAssertTrue(reader.isReading); XCTAssertTrue(publications.isEmpty)
        current.finish(replacement)
        await reader.waitUntilIdle()
        XCTAssertEqual(publications, [replacement]); XCTAssertEqual(reader.info, replacement)
        XCTAssertEqual(reader.estimate?.remainingLabels, 74); XCTAssertEqual(reader.freshness, .fresh)
        XCTAssertEqual(recoveries, 1)
    }

    func testRecoveryReadThatIsAlsoSupersededStopsWithoutPublishingOrPolling() async {
        let reader = NiimbotRollReadCoordinator(), old = RollInfoReadGate(), recovery = RollInfoReadGate()
        let info = NiimbotRollInfo(estimate: estimate())
        var reads = 0, recoveries = 0, publications = 0
        reader.refreshInfo(load: {
            reads += 1
            return try await old.read()
        }, onUpdate: { _ in publications += 1 }, onSuperseded: {
            recoveries += 1
            // The printer omits recursive recovery for its replacement read.
            XCTAssertTrue(reader.refreshInfo(load: {
                reads += 1
                return try await recovery.read()
            }, onUpdate: { _ in publications += 1 }))
        })
        await waitForInfoRead(old)
        reader.markStale()
        old.finish(info)
        await waitForInfoRead(recovery)
        reader.markStale(); reader.markStale()
        recovery.finish(info)
        await reader.waitUntilIdle()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(reads, 2); XCTAssertEqual(recoveries, 1); XCTAssertEqual(publications, 0)
        XCTAssertNil(reader.info); XCTAssertFalse(reader.isReading)
    }

    func testCurrentSuccessfulMissingAndFailedReadsDoNotRequestSupersededRecovery() async {
        let reader = NiimbotRollReadCoordinator()
        let info = NiimbotRollInfo(estimate: estimate())
        var updates: [NiimbotRollInfo?] = [], recoveries = 0
        reader.refreshInfo(load: { info }, onUpdate: { updates.append($0) }, onSuperseded: { recoveries += 1 })
        await reader.waitUntilIdle()
        reader.refreshInfo(load: { nil }, onUpdate: { updates.append($0) }, onSuperseded: { recoveries += 1 })
        await reader.waitUntilIdle()
        reader.refreshInfo(load: { throw LabelPrinterIssue.responseTimeout },
            onUpdate: { updates.append($0) }, onSuperseded: { recoveries += 1 })
        await reader.waitUntilIdle()
        XCTAssertEqual(updates, [info, nil, nil]); XCTAssertEqual(recoveries, 0)
        XCTAssertNil(reader.info); XCTAssertEqual(reader.freshness, .unavailable)
    }

    func testResetSuppressesOldSupersededRecoveryWhileAReplacementConnectionIsReading() async {
        let reader = NiimbotRollReadCoordinator(), old = RollInfoReadGate(), current = RollInfoReadGate()
        let info = NiimbotRollInfo(estimate: estimate())
        var recoveries = 0, publications: [NiimbotRollInfo?] = []
        reader.refreshInfo(load: { try await old.read() }, onUpdate: { publications.append($0) },
            onSuperseded: { recoveries += 1 })
        await waitForInfoRead(old)
        reader.markStale()
        reader.reset()
        reader.refreshInfo(load: { try await current.read() }, onUpdate: { publications.append($0) })
        await waitForInfoRead(current)
        old.finish(info)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(recoveries, 0); XCTAssertTrue(publications.isEmpty)
        XCTAssertTrue(reader.isReading); XCTAssertNil(reader.info)
        current.finish(info)
        await reader.waitUntilIdle()
        XCTAssertEqual(publications, [info]); XCTAssertEqual(recoveries, 0)
    }

    func testReconnectLateIdentityCannotPublishOverTheNewConnectionsProduct() async {
        let reader = NiimbotRollReadCoordinator(), old = RollInfoReadGate(), current = RollInfoReadGate()
        var published: [NiimbotRollInfo?] = []
        reader.refreshInfo(load: { try await old.read() }, onUpdate: { published.append($0) })
        await waitForInfoRead(old)
        reader.reset()
        reader.refreshInfo(load: { try await current.read() }, onUpdate: { published.append($0) })
        await waitForInfoRead(current)
        old.finish(NiimbotRollInfo(productCode: "02242207", totalLabels: 84, usedLabels: 9, labelType: 1))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(published.isEmpty); XCTAssertTrue(reader.isReading); XCTAssertNil(reader.info)
        let replacement = NiimbotRollInfo(productCode: "120425109", totalLabels: 0, usedLabels: 0, labelType: 1)
        current.finish(replacement)
        await reader.waitUntilIdle()
        XCTAssertEqual(published, [replacement]); XCTAssertEqual(reader.info, replacement)
    }

    func testPrintStockSnapshotRejectsConnectionRollAndMediaChanges() throws {
        let connection = UUID()
        let product = try XCTUnwrap(NiimbotLabelCatalog.shared.product(code: "120425109"))
        let other = try XCTUnwrap(NiimbotLabelCatalog.shared.product(code: "02242207"))
        let snapshot = NiimbotPrintStockSnapshot(connection: connection, product: product, paperMode: .gap)
        XCTAssertTrue(snapshot.matches(connection: connection, product: product, paperMode: .gap))
        XCTAssertFalse(snapshot.matches(connection: UUID(), product: product, paperMode: .gap))
        XCTAssertFalse(snapshot.matches(connection: connection, product: other, paperMode: .gap))
        XCTAssertFalse(snapshot.matches(connection: connection, product: nil, paperMode: .gap))
        XCTAssertFalse(snapshot.matches(connection: connection, product: product, paperMode: .transparent))
        let manual = NiimbotPrintStockSnapshot(connection: connection, product: nil, paperMode: .transparent)
        XCTAssertTrue(manual.matches(connection: connection, product: nil, paperMode: .transparent))
        XCTAssertFalse(manual.matches(connection: connection, product: product, paperMode: .transparent))
    }

    private func waitForInfoRead(_ gate: RollInfoReadGate) async {
        for _ in 0..<100 where !gate.waiting { await Task.yield() }
        XCTAssertTrue(gate.waiting, "The optional metadata read did not start")
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

    func testOptionalRollWritePrefersAcknowledgementsAndFallsBackOnlyForAnUnacknowledgedOnlyChannel() {
        XCTAssertEqual(NiimbotOptionalRollWritePolicy.select(supportsWrite: true, supportsWriteWithoutResponse: true), .acknowledged)
        XCTAssertEqual(NiimbotOptionalRollWritePolicy.select(supportsWrite: true, supportsWriteWithoutResponse: false), .acknowledged)
        XCTAssertEqual(NiimbotOptionalRollWritePolicy.select(supportsWrite: false, supportsWriteWithoutResponse: true), .unacknowledged)
        XCTAssertNil(NiimbotOptionalRollWritePolicy.select(supportsWrite: false, supportsWriteWithoutResponse: false))
    }

    func testOptionalReadFailureRetiresAnOutstandingGattAcknowledgementButOnlyQuarantinesALatePrinterReply() {
        let awaiting = NiimbotOptionalRollWritePolicy.failureAction(mode: .acknowledged,
            wasDispatched: true, awaitingAcknowledgement: true)
        XCTAssertEqual(awaiting, .retireConnection, "A late GATT acknowledgement must never settle a later command")
        for mode in [NiimbotOptionalRollWritePolicy.Mode.acknowledged, .unacknowledged] {
            XCTAssertEqual(NiimbotOptionalRollWritePolicy.failureAction(mode: mode,
                wasDispatched: false, awaitingAcknowledgement: false), .keepConnection)
            let completedWrite = NiimbotOptionalRollWritePolicy.failureAction(mode: mode,
                wasDispatched: true, awaitingAcknowledgement: false)
            XCTAssertEqual(completedWrite, .quarantineRead, "A missing RFID reply alone need not tear down a verified link")
            var guardState = NiimbotOptionalRollReplyGuard()
            guardState.abandonRead(wasSent: completedWrite == .quarantineRead)
            let requiredReplies: [UInt8] = [0x14, 0x31, 0xb3, 0xdb, 0xe4, 0xf4]
            for required in requiredReplies {
                XCTAssertFalse(guardState.consumeLateResponse(required))
            }
            XCTAssertTrue(guardState.consumeLateResponse(0x1b))
            XCTAssertFalse(guardState.consumeLateResponse(0x00), "Only one compatible abandoned-read reply may be consumed")
            XCTAssertTrue(guardState.isQuarantined, "The old RFID opcode cannot become eligible again on this connection")
        }
    }

    func testRetiredOptionalReadCancellationAndFailureCannotSettleAReplacementConnectionRead() async {
        for issue in [LabelPrinterIssue.cancelled, .connectionLost] {
            let reader = NiimbotRollReadCoordinator(), old = RollReadGate(), current = RollReadGate()
            var publications: [NiimbotRollInfo?] = []
            reader.refreshInfo(load: {
                guard let estimate = try await old.read() else { return nil }
                return NiimbotRollInfo(estimate: estimate)
            }, onUpdate: { publications.append($0) })
            await waitForRead(old)
            reader.reset()
            reader.refreshInfo(load: {
                guard let estimate = try await current.read() else { return nil }
                return NiimbotRollInfo(estimate: estimate)
            }, onUpdate: { publications.append($0) })
            await waitForRead(current)
            old.finish(.failure(issue))
            for _ in 0..<5 { await Task.yield() }
            XCTAssertTrue(reader.isReading)
            XCTAssertNil(reader.info)
            XCTAssertTrue(publications.isEmpty, "An old cancellation or failure cannot publish nil into the new connection")
            let replacement = estimate(used: 20)
            current.finish(.success(replacement))
            await reader.waitUntilIdle()
            XCTAssertEqual(publications, [NiimbotRollInfo(estimate: replacement)])
            XCTAssertEqual(reader.estimate, replacement)
            XCTAssertEqual(reader.freshness, .fresh)
        }
    }
}

@MainActor private final class RollReadClock { var uptime: TimeInterval = 100 }

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

@MainActor private final class RollInfoReadGate {
    private var continuation: CheckedContinuation<NiimbotRollInfo?, Error>?
    var waiting: Bool { continuation != nil }
    func read() async throws -> NiimbotRollInfo? {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ info: NiimbotRollInfo?) {
        let pending = continuation; continuation = nil
        pending?.resume(returning: info)
    }
}
