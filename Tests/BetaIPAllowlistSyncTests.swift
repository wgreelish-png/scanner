import XCTest
@testable import CardShowScanner

@MainActor final class BetaIPAllowlistSyncTests: XCTestCase {
    private final class Runner: BetaAllowlistSyncRunning {
        var calls = 0
        var cancellations = 0
        var reply: BetaAllowlistSyncResult?
        var pending: [CheckedContinuation<BetaAllowlistSyncResult, Error>] = []
        func run() async throws -> BetaAllowlistSyncResult {
            calls += 1
            if let reply { return reply }
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        // Deliberately allow a canceled operation to finish late: generation
        // guards must protect the UI even when transport cancellation loses.
        func cancel() { cancellations += 1 }
        func complete(_ reply: BetaAllowlistSyncResult) { pending.removeFirst().resume(returning: reply) }
    }
    private final class Clock {
        var value = Date(timeIntervalSince1970: 1_800_000_000)
    }
    private final class Sleeper {
        var durations: [Duration] = []
        var pending: [CheckedContinuation<Void, Error>] = []
        func wait(_ duration: Duration) async throws {
            durations.append(duration)
            try await withCheckedThrowingContinuation { pending.append($0) }
        }
        func release() { pending.removeFirst().resume() }
    }
    private func defaults() -> UserDefaults {
        let name = "BetaIPAllowlistSyncTests." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }
    private func waitUntil(_ predicate: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The expected synchronization state did not arrive", file: file, line: line)
    }

    func testNoCheckBeforeForegroundAndRepeatedActivationIsSingleFlight() async {
        let runner = Runner(), clock = Clock()
        runner.reply = .init(status: .saved, ip: "8.8.8.8")
        let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { .direct },
                                      now: { clock.value }, automaticPolling: false)
        await sync.prepareForDirectRequest()
        XCTAssertEqual(runner.calls, 0)
        sync.setForeground(true)
        await sync.prepareForDirectRequest()
        XCTAssertEqual(runner.calls, 1)
        XCTAssertEqual(sync.lastIP, "8.8.8.8")
        XCTAssertEqual(sync.lastCheckedAt, clock.value)
        XCTAssertFalse(sync.busy)
        sync.setForeground(true)
        await sync.prepareForDirectRequest()
        XCTAssertEqual(runner.calls, 1)
    }

    func testDisabledPreferenceSurvivesRelaunchAndMakesNoWebsiteRequests() async {
        let preferences = defaults(), runner = Runner()
        let first = BetaIPAllowlistSync(runner: runner, defaults: preferences, configuration: { .direct }, automaticPolling: false)
        first.setEnabled(false)
        let reopened = BetaIPAllowlistSync(runner: runner, defaults: preferences, configuration: { .direct }, automaticPolling: false)
        reopened.setForeground(true)
        reopened.checkNow(); reopened.networkChanged()
        await reopened.prepareForDirectRequest()
        XCTAssertFalse(reopened.enabled)
        XCTAssertEqual(runner.calls, 0)
    }

    func testServerMissingCredentialsAndUnreadableConfigurationNeverModifyAllowlist() async {
        for configuration in [BetaIPAllowlistSync.Configuration.server, .missing, .unavailable] {
            let runner = Runner()
            let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { configuration }, automaticPolling: false)
            sync.setForeground(true); sync.checkNow(); sync.networkChanged()
            await sync.prepareForDirectRequest()
            XCTAssertEqual(runner.calls, 0)
            XCTAssertNil(sync.lastIP)
            XCTAssertFalse(sync.busy)
        }
    }

    func testReturningToForegroundRechecksEvenAfterRecentSuccess() async {
        let runner = Runner()
        runner.reply = .init(status: .alreadyCurrent, ip: "1.1.1.1")
        let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { .direct }, automaticPolling: false)
        sync.setForeground(true); await sync.prepareForDirectRequest()
        sync.setForeground(false)
        runner.reply = .init(status: .saved, ip: "8.8.4.4")
        sync.setForeground(true); await sync.prepareForDirectRequest()
        XCTAssertEqual(runner.calls, 2)
        XCTAssertEqual(sync.lastIP, "8.8.4.4")
    }

    func testBackgroundCancelsAndCannotPublishLateSuccess() async {
        let runner = Runner()
        let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { .direct }, automaticPolling: false)
        sync.setForeground(true)
        await waitUntil { runner.calls == 1 }
        sync.setForeground(false)
        XCTAssertEqual(runner.cancellations, 1)
        XCTAssertFalse(sync.busy)
        runner.complete(.init(status: .saved, ip: "8.8.8.8"))
        await Task.yield()
        XCTAssertNil(sync.lastIP)
        XCTAssertNil(sync.lastCheckedAt)
        sync.checkNow(); sync.networkChanged(); await sync.prepareForDirectRequest()
        XCTAssertEqual(runner.calls, 1)
    }

    func testDisablingCancelsAndCannotPublishLateSuccess() async {
        let runner = Runner()
        let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { .direct }, automaticPolling: false)
        sync.setForeground(true); await waitUntil { runner.calls == 1 }
        sync.setEnabled(false)
        runner.complete(.init(status: .saved, ip: "8.8.8.8"))
        await Task.yield()
        XCTAssertEqual(runner.cancellations, 1)
        XCTAssertNil(sync.lastIP)
        XCTAssertFalse(sync.enabled)
        XCTAssertFalse(sync.busy)
    }

    func testNetworkChangesCoalesceAndRetirePreviousRouteBeforePublishingNewIP() async {
        let runner = Runner()
        let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { .direct }, automaticPolling: false,
                                      wait: { _ in await Task.yield(); try Task.checkCancellation() })
        sync.setForeground(true); await waitUntil { runner.calls == 1 }
        sync.networkChanged(); sync.networkChanged(); sync.networkChanged()
        await waitUntil { runner.calls == 2 }
        XCTAssertEqual(runner.cancellations, 1)
        runner.complete(.init(status: .saved, ip: "8.8.8.8"))
        await Task.yield()
        XCTAssertNil(sync.lastIP)
        runner.complete(.init(status: .saved, ip: "1.1.1.1"))
        await sync.prepareForDirectRequest()
        XCTAssertEqual(sync.lastIP, "1.1.1.1")
        XCTAssertEqual(runner.calls, 2)
    }

    func testManualDoubleTapsShareOnePendingSave() async {
        let runner = Runner()
        let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { .direct }, automaticPolling: false)
        sync.setForeground(true); await waitUntil { runner.calls == 1 }
        sync.checkNow(); sync.checkNow(); sync.checkNow()
        XCTAssertEqual(runner.calls, 1)
        runner.complete(.init(status: .saved, ip: "8.8.8.8"))
        await sync.prepareForDirectRequest()
        XCTAssertEqual(runner.calls, 1)
    }

    func testRetryAfterSurvivesManualChecksNetworkChangesAndForegroundReturns() async {
        let runner = Runner(), clock = Clock()
        runner.reply = .init(status: .rateLimited, retryAfterSeconds: 120)
        let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { .direct },
                                      now: { clock.value }, automaticPolling: false,
                                      wait: { _ in await Task.yield(); try Task.checkCancellation() })
        sync.setForeground(true); await sync.prepareForDirectRequest()
        sync.checkNow(); sync.networkChanged(); await sync.prepareForDirectRequest()
        sync.setForeground(false); sync.setForeground(true); await sync.prepareForDirectRequest()
        sync.connectionChanged(); await sync.prepareForDirectRequest()
        XCTAssertEqual(runner.calls, 1)
        clock.value = clock.value.addingTimeInterval(119)
        sync.checkNow(); await sync.prepareForDirectRequest()
        XCTAssertEqual(runner.calls, 1)
        clock.value = clock.value.addingTimeInterval(1)
        runner.reply = .init(status: .saved, ip: "8.8.8.8")
        sync.checkNow(); await sync.prepareForDirectRequest()
        XCTAssertEqual(runner.calls, 2)
        XCTAssertEqual(sync.lastIP, "8.8.8.8")
    }

    func testUnconfirmedOrInvalidSuccessNeverBecomesConfirmedIP() async {
        for reply in [BetaAllowlistSyncResult(status: .saveFailed), .init(status: .saved),
                      .init(status: .alreadyCurrent, ip: "192.168.1.2"), .init(status: .saved, ip: "not-an-ip")] {
            let runner = Runner(); runner.reply = reply
            let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { .direct }, automaticPolling: false)
            sync.setForeground(true); await sync.prepareForDirectRequest()
            XCTAssertNil(sync.lastIP)
            XCTAssertNil(sync.lastCheckedAt)
            XCTAssertFalse(sync.busy)
        }
    }

    func testSignInAndAccountMismatchRequestMatchingLoginWithoutRetryLoop() async {
        for failure in [BetaAllowlistSyncResult.Status.signInRequired, .accountMismatch] {
            let runner = Runner(); runner.reply = .init(status: failure)
            let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { .direct }, automaticPolling: false)
            sync.setForeground(true); await sync.prepareForDirectRequest()
            XCTAssertTrue(sync.needsSignIn)
            sync.checkNow(); await sync.prepareForDirectRequest()
            XCTAssertEqual(runner.calls, 1)
            runner.reply = .init(status: .saved, ip: "8.8.8.8")
            sync.connectionChanged(); await sync.prepareForDirectRequest()
            XCTAssertEqual(runner.calls, 2)
            XCTAssertFalse(sync.needsSignIn)
            XCTAssertEqual(sync.lastIP, "8.8.8.8")
        }
    }

    func testChangingToServerCancelsPendingPhoneUpdateAndClearsConfirmedMetadata() async {
        var method = BetaIPAllowlistSync.Configuration.direct
        let runner = Runner(); runner.reply = .init(status: .saved, ip: "8.8.8.8")
        let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { method }, automaticPolling: false)
        sync.setForeground(true); await sync.prepareForDirectRequest()
        runner.reply = nil
        sync.checkNow(); await waitUntil { runner.calls == 2 }
        method = .server; sync.connectionChanged()
        runner.complete(.init(status: .saved, ip: "1.1.1.1"))
        await Task.yield()
        XCTAssertEqual(runner.cancellations, 1)
        XCTAssertNil(sync.lastIP)
        XCTAssertNil(sync.lastCheckedAt)
        XCTAssertFalse(sync.busy)
    }

    func testDirectRequestWaitsForOneExistingSynchronization() async {
        let runner = Runner()
        let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { .direct }, automaticPolling: false)
        sync.setForeground(true); await waitUntil { runner.calls == 1 }
        var finished = false
        let preflight = Task { await sync.prepareForDirectRequest(); finished = true }
        await Task.yield()
        XCTAssertFalse(finished)
        XCTAssertEqual(runner.calls, 1)
        runner.complete(.init(status: .alreadyCurrent, ip: "8.8.8.8"))
        await preflight.value
        XCTAssertTrue(finished)
        XCTAssertEqual(sync.lastIP, "8.8.8.8")
    }

    func testPeriodicPollingIsCanceledOnBackgroundAndLateTimerCannotStartWork() async {
        let runner = Runner(), sleeper = Sleeper()
        runner.reply = .init(status: .alreadyCurrent, ip: "8.8.8.8")
        let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { .direct },
                                      wait: { try await sleeper.wait($0) })
        sync.setForeground(true); await sync.prepareForDirectRequest()
        await waitUntil { sleeper.pending.count == 1 }
        XCTAssertEqual(sleeper.durations, [.seconds(60)])
        sync.setForeground(false)
        sleeper.release()
        await Task.yield()
        XCTAssertEqual(runner.calls, 1)
        XCTAssertFalse(sync.busy)
    }

    func testDebouncedNetworkCheckCannotStartAfterAppBecomesInactive() async {
        let runner = Runner(), sleeper = Sleeper()
        runner.reply = .init(status: .alreadyCurrent, ip: "8.8.8.8")
        let sync = BetaIPAllowlistSync(runner: runner, defaults: defaults(), configuration: { .direct }, automaticPolling: false,
                                      wait: { try await sleeper.wait($0) })
        sync.setForeground(true); await sync.prepareForDirectRequest()
        sync.networkChanged()
        await waitUntil { sleeper.pending.count == 1 }
        XCTAssertEqual(sleeper.durations, [.seconds(2)])
        sync.setForeground(false)
        sleeper.release()
        await Task.yield()
        XCTAssertEqual(runner.calls, 1)
    }
}
