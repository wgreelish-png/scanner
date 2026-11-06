import XCTest
@testable import CardShowScanner

@MainActor final class NiimbotImageTransportTests: XCTestCase {
    func testDefaultConfigurationDoesNotOptInOrWriteExistingPreferences() throws {
        let suite = "ImageTransportDefault." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("medium40x12", forKey: "niimbotLabelSize")
        defaults.set("left", forKey: "niimbotLabelPricePosition")
        let preferences = NiimbotImageTransportPreferences(defaults: defaults)
        XCTAssertEqual(preferences.snapshot, NiimbotImageTransportConfiguration())
        XCTAssertEqual(preferences.mode, .acknowledged)
        XCTAssertEqual(preferences.pacingMilliseconds, 10)
        XCTAssertEqual(preferences.burstWriteLimit, 1)
        XCTAssertEqual(preferences.burstByteLimit, 64)
        XCTAssertNil(defaults.object(forKey: "niimbotImageTransportExperiment.mode"))
        XCTAssertEqual(defaults.string(forKey: "niimbotLabelSize"), "medium40x12")
        XCTAssertEqual(defaults.string(forKey: "niimbotLabelPricePosition"), "left")
    }

    func testPreferenceChangesPersistButCannotChangeAnExistingJobSnapshot() throws {
        let suite = "ImageTransportSnapshot." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = NiimbotImageTransportPreferences(defaults: defaults)
        let baseline = preferences.snapshot
        preferences.mode = .pacedWithoutResponse
        preferences.pacingMilliseconds = 25
        preferences.burstWriteLimit = 2
        preferences.burstByteLimit = 80
        let selectedJob = preferences.snapshot
        preferences.mode = .acknowledged
        preferences.pacingMilliseconds = 90
        XCTAssertEqual(baseline, NiimbotImageTransportConfiguration())
        XCTAssertEqual(selectedJob, NiimbotImageTransportConfiguration(mode: .pacedWithoutResponse,
            pacingMilliseconds: 25, burstWriteLimit: 2, burstByteLimit: 80))
        let reloaded = NiimbotImageTransportPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.snapshot, preferences.snapshot)
        XCTAssertEqual(reloaded.mode, .acknowledged)
        reloaded.reset()
        XCTAssertEqual(reloaded.snapshot, NiimbotImageTransportConfiguration())
        XCTAssertEqual(NiimbotImageTransportPreferences(defaults: defaults).snapshot, reloaded.snapshot)
        for key in ["mode", "pacingMilliseconds", "burstWriteLimit", "burstByteLimit"] {
            XCTAssertNil(defaults.object(forKey: "niimbotImageTransportExperiment." + key))
        }
    }

    func testMalformedSettingsNeverSelectAnUnknownModeOrEscapeConservativeBounds() throws {
        let suite = "ImageTransportBounds." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefix = "niimbotImageTransportExperiment"
        defaults.set("unlimited", forKey: prefix + ".mode")
        defaults.set("not-a-number", forKey: prefix + ".pacingMilliseconds")
        defaults.set(-10, forKey: prefix + ".burstWriteLimit")
        defaults.set(Int.max, forKey: prefix + ".burstByteLimit")
        let preferences = NiimbotImageTransportPreferences(defaults: defaults)
        XCTAssertEqual(preferences.mode, .acknowledged)
        XCTAssertEqual(preferences.pacingMilliseconds, 10)
        XCTAssertEqual(preferences.burstWriteLimit, 1)
        XCTAssertEqual(preferences.burstByteLimit, 256)
        defaults.set(true, forKey: prefix + ".pacingMilliseconds")
        defaults.set(false, forKey: prefix + ".burstWriteLimit")
        defaults.set(99.5, forKey: prefix + ".burstByteLimit")
        XCTAssertEqual(NiimbotImageTransportPreferences(defaults: defaults).snapshot, NiimbotImageTransportConfiguration(),
            "Booleans and fractional values must not silently become experiment limits")
        preferences.pacingMilliseconds = Int.min
        preferences.burstWriteLimit = Int.max
        preferences.burstByteLimit = Int.min
        XCTAssertEqual(preferences.snapshot, NiimbotImageTransportConfiguration(
            pacingMilliseconds: 10, burstWriteLimit: 4, burstByteLimit: 20))
        preferences.pacingMilliseconds = Int.max
        XCTAssertEqual(preferences.pacingMilliseconds, 1_000)
    }

    func testReadinessBeforePacingAndPacingBeforeReadinessBothRemainBlockedUntilReady() {
        let start = ContinuousClock().now
        var gate = NiimbotImageWriteGate(configuration: .init(mode: .pacedWithoutResponse))
        let initial = gate.decision(remainingBytes: 27, maximumWriteLength: 20, isReady: false, at: start)
        XCTAssertEqual(initial.allowedBytes, 0)
        XCTAssertTrue(initial.waitingForReadiness)
        XCTAssertNil(initial.resumeAt)
        XCTAssertEqual(gate.decision(remainingBytes: 27, maximumWriteLength: 20, isReady: true, at: start).allowedBytes, 20)
        gate.recordSubmission(byteCount: 20, at: start)
        let both = gate.decision(remainingBytes: 7, maximumWriteLength: 20, isReady: false,
            at: start.advanced(by: .milliseconds(2)))
        XCTAssertEqual(both.allowedBytes, 0)
        XCTAssertTrue(both.waitingForReadiness)
        XCTAssertEqual(both.resumeAt, start.advanced(by: .milliseconds(10)))
        let earlyReadiness = gate.decision(remainingBytes: 7, maximumWriteLength: 20, isReady: true,
            at: start.advanced(by: .milliseconds(5)))
        XCTAssertEqual(earlyReadiness.allowedBytes, 0)
        XCTAssertFalse(earlyReadiness.waitingForReadiness)
        XCTAssertEqual(earlyReadiness.resumeAt, both.resumeAt)
        let timerWhileBlocked = gate.decision(remainingBytes: 7, maximumWriteLength: 20, isReady: false,
            at: start.advanced(by: .milliseconds(10)))
        XCTAssertEqual(timerWhileBlocked.allowedBytes, 0)
        XCTAssertTrue(timerWhileBlocked.waitingForReadiness)
        XCTAssertNil(timerWhileBlocked.resumeAt, "An expired pacing deadline must not create a timer loop")
        XCTAssertEqual(gate.decision(remainingBytes: 7, maximumWriteLength: 20, isReady: true,
            at: start.advanced(by: .milliseconds(11))).allowedBytes, 7)
    }

    func testExhaustedBurstResumesOnTimerWithoutAnotherBluetoothReadinessEdge() {
        let start = ContinuousClock().now
        var gate = NiimbotImageWriteGate(configuration: .init(mode: .pacedWithoutResponse))
        XCTAssertEqual(gate.decision(remainingBytes: 27, maximumWriteLength: 100, isReady: true, at: start).allowedBytes, 27)
        gate.recordSubmission(byteCount: 27, at: start)
        let nextPacket = gate.decision(remainingBytes: 27, maximumWriteLength: 100, isReady: true,
            at: start.advanced(by: .milliseconds(1)))
        XCTAssertEqual(nextPacket.allowedBytes, 0, "Completing a packet must not reset the job-wide burst budget")
        XCTAssertFalse(nextPacket.waitingForReadiness)
        XCTAssertEqual(nextPacket.resumeAt, start.advanced(by: .milliseconds(10)))
        XCTAssertEqual(gate.decision(remainingBytes: 27, maximumWriteLength: 100, isReady: true,
            at: start.advanced(by: .milliseconds(10))).allowedBytes, 27)
        gate.recordSubmission(byteCount: 27, at: start.advanced(by: .milliseconds(10)))
        gate.reset()
        XCTAssertEqual(gate.decision(remainingBytes: 27, maximumWriteLength: 100, isReady: true,
            at: start.advanced(by: .milliseconds(11))).allowedBytes, 27,
            "A new job must not inherit an interrupted job's pacing state")
    }

    func testFragmentedPacketPreservesEveryByteThroughWriteAndBurstLimitsAndBackpressure() {
        let packet = Data((0..<NiimbotImageTransportConfiguration.maximumPendingPacketBytes).map { UInt8($0 % 256) })
        var gate = NiimbotImageWriteGate(configuration: .init(mode: .pacedWithoutResponse,
            pacingMilliseconds: 10, burstWriteLimit: 4, burstByteLimit: 45))
        var now = ContinuousClock().now
        var offset = 0
        var output = Data()
        var fragments: [Int] = []
        var byteBudget = 0
        var writeBudget = 0
        for turn in 0..<100 where offset < packet.count {
            let ready = turn % 5 != 2
            let decision = gate.decision(remainingBytes: packet.count - offset,
                maximumWriteLength: 17, isReady: ready, at: now)
            if decision.allowedBytes > 0 {
                XCTAssertTrue(ready)
                XCTAssertLessThanOrEqual(decision.allowedBytes, 17)
                let end = offset + decision.allowedBytes
                output.append(packet.subdata(in: offset..<end))
                fragments.append(decision.allowedBytes)
                offset = end
                gate.recordSubmission(byteCount: decision.allowedBytes, at: now)
                byteBudget += decision.allowedBytes
                writeBudget += 1
                XCTAssertLessThanOrEqual(byteBudget, 45)
                XCTAssertLessThanOrEqual(writeBudget, 4)
            } else if let deadline = decision.resumeAt {
                XCTAssertGreaterThan(deadline, now)
                now = deadline
                byteBudget = 0
                writeBudget = 0
            } else {
                XCTAssertTrue(decision.waitingForReadiness)
                now = now.advanced(by: .milliseconds(1))
            }
        }
        XCTAssertEqual(offset, packet.count)
        XCTAssertEqual(output, packet, "No split may drop, repeat or reorder protocol bytes")
        XCTAssertTrue(fragments.contains { $0 < 17 }, "The byte budget also limits a fragment independently of MTU")
    }

    func testInvalidWriteSizeAndEmptyPacketDoNotConsumeBudgetOrScheduleAnExpiredWakeup() {
        let now = ContinuousClock().now
        var gate = NiimbotImageWriteGate(configuration: .init(mode: .pacedWithoutResponse))
        for maximum in [-1, 0] {
            let blocked = gate.decision(remainingBytes: 27, maximumWriteLength: maximum, isReady: true, at: now)
            XCTAssertEqual(blocked.allowedBytes, 0)
            XCTAssertNil(blocked.resumeAt)
            XCTAssertFalse(blocked.waitingForReadiness)
        }
        XCTAssertEqual(gate.decision(remainingBytes: 0, maximumWriteLength: 20, isReady: false, at: now).allowedBytes, 0)
        XCTAssertEqual(gate.decision(remainingBytes: 27, maximumWriteLength: 20, isReady: true, at: now).allowedBytes, 20)
    }

    func testPacingWakeActuallyResumesReadyPumpWithoutAnotherBluetoothCallback() async {
        let sleeper = ImagePacingSleeper()
        let wake = NiimbotImagePacingWake(sleep: sleeper.sleep)
        defer { wake.cancel(); sleeper.releaseAll() }
        let start = ContinuousClock().now
        var now = start
        var gate = NiimbotImageWriteGate(configuration: .init(mode: .pacedWithoutResponse))
        gate.recordSubmission(byteCount: 20, at: start)
        let decision = gate.decision(remainingBytes: 7, maximumWriteLength: 20, isReady: true,
            at: start.advanced(by: .milliseconds(1)))
        let deadline = start.advanced(by: .milliseconds(10))
        XCTAssertEqual(decision.resumeAt, deadline)
        var resumedBytes = 0
        wake.schedule(transferID: UUID(), deadline: deadline) {
            XCTAssertNil(wake.scheduledDeadline, "Clear the old timer before a pump callback can schedule another one")
            resumedBytes = gate.decision(remainingBytes: 7, maximumWriteLength: 20, isReady: true, at: now).allowedBytes
        }
        await waitForSleepCount(1, sleeper: sleeper)
        XCTAssertEqual(resumedBytes, 0)
        now = deadline
        sleeper.release(0)
        for _ in 0..<100 where resumedBytes == 0 { await Task.yield() }
        XCTAssertEqual(resumedBytes, 7)
        XCTAssertNil(wake.scheduledDeadline)
    }

    func testEarlyReadinessReusesTimerAndTimerExpiryStillWaitsForBluetoothReadiness() async {
        let sleeper = ImagePacingSleeper()
        let wake = NiimbotImagePacingWake(sleep: sleeper.sleep)
        defer { wake.cancel(); sleeper.releaseAll() }
        let start = ContinuousClock().now, transfer = UUID()
        let deadline = start.advanced(by: .milliseconds(10))
        var gate = NiimbotImageWriteGate(configuration: .init(mode: .pacedWithoutResponse))
        gate.recordSubmission(byteCount: 20, at: start)
        var result: NiimbotImageWriteGate.Decision?
        wake.schedule(transferID: transfer, deadline: deadline) {
            result = gate.decision(remainingBytes: 7, maximumWriteLength: 20, isReady: false, at: deadline)
        }
        await waitForSleepCount(1, sleeper: sleeper)
        let early = gate.decision(remainingBytes: 7, maximumWriteLength: 20, isReady: true,
            at: start.advanced(by: .milliseconds(5)))
        XCTAssertEqual(early.allowedBytes, 0)
        XCTAssertEqual(early.resumeAt, deadline)
        wake.schedule(transferID: transfer, deadline: deadline) { XCTFail("A readiness wake must reuse the already scheduled timer") }
        await Task.yield()
        XCTAssertEqual(sleeper.count, 1)
        sleeper.release(0)
        for _ in 0..<100 where result == nil { await Task.yield() }
        XCTAssertEqual(result?.allowedBytes, 0)
        XCTAssertEqual(result?.waitingForReadiness, true)
        XCTAssertNil(result?.resumeAt)
        XCTAssertNil(wake.scheduledDeadline)
        XCTAssertEqual(gate.decision(remainingBytes: 7, maximumWriteLength: 20, isReady: true,
            at: deadline.advanced(by: .milliseconds(1))).allowedBytes, 7)
    }

    func testSupersededAndCancelledSleeperCannotWakeOrClearANewerTransfer() async {
        let sleeper = ImagePacingSleeper()
        let wake = NiimbotImagePacingWake(sleep: sleeper.sleep)
        defer { wake.cancel(); sleeper.releaseAll() }
        let start = ContinuousClock().now
        var calls: [String] = []
        wake.schedule(transferID: UUID(), deadline: start.advanced(by: .milliseconds(10))) { calls.append("old") }
        await waitForSleepCount(1, sleeper: sleeper)
        let currentDeadline = start.advanced(by: .milliseconds(20))
        wake.schedule(transferID: UUID(), deadline: currentDeadline) { calls.append("current") }
        await waitForSleepCount(2, sleeper: sleeper)
        sleeper.release(0) // The fake sleep deliberately ignores task cancellation.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(wake.scheduledDeadline, currentDeadline)
        sleeper.release(1)
        for _ in 0..<100 where calls.isEmpty { await Task.yield() }
        XCTAssertEqual(calls, ["current"])
        wake.schedule(transferID: UUID(), deadline: start.advanced(by: .milliseconds(30))) { calls.append("cancelled") }
        await waitForSleepCount(3, sleeper: sleeper)
        wake.cancel()
        sleeper.release(2)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, ["current"])
        XCTAssertNil(wake.scheduledDeadline)
    }

    func testEarlierDeadlineReplacesWakeWhileLaterDeadlineForSameTransferDoesNotDelayIt() async {
        let sleeper = ImagePacingSleeper()
        let wake = NiimbotImagePacingWake(sleep: sleeper.sleep)
        defer { wake.cancel(); sleeper.releaseAll() }
        let start = ContinuousClock().now, transfer = UUID()
        var calls: [String] = []
        wake.schedule(transferID: transfer, deadline: start.advanced(by: .milliseconds(20))) { calls.append("old") }
        await waitForSleepCount(1, sleeper: sleeper)
        wake.schedule(transferID: transfer, deadline: start.advanced(by: .milliseconds(30))) { calls.append("later") }
        await Task.yield()
        XCTAssertEqual(sleeper.count, 1)
        let earlier = start.advanced(by: .milliseconds(10))
        wake.schedule(transferID: transfer, deadline: earlier) { calls.append("earlier") }
        await waitForSleepCount(2, sleeper: sleeper)
        sleeper.release(0)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(wake.scheduledDeadline, earlier)
        sleeper.release(1)
        for _ in 0..<100 where calls.isEmpty { await Task.yield() }
        XCTAssertEqual(calls, ["earlier"])
        XCTAssertNil(wake.scheduledDeadline)
    }

    private func waitForSleepCount(_ count: Int, sleeper: ImagePacingSleeper) async {
        for _ in 0..<100 where sleeper.count < count { await Task.yield() }
        XCTAssertEqual(sleeper.count, count)
    }
}

/// Manual sleep lets tests release even cancelled work, proving UUID fencing
/// rather than assuming the operating system always cancels promptly.
@MainActor private final class ImagePacingSleeper {
    private struct Wait {
        let deadline: ContinuousClock.Instant
        var continuation: CheckedContinuation<Void, Never>?
    }
    private var waits: [Wait] = []
    var count: Int { waits.count }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        await withCheckedContinuation { waits.append(Wait(deadline: deadline, continuation: $0)) }
    }

    func release(_ index: Int) {
        guard waits.indices.contains(index) else { return }
        let continuation = waits[index].continuation
        waits[index].continuation = nil
        continuation?.resume()
    }

    func releaseAll() {
        for index in waits.indices { release(index) }
    }
}
