import XCTest
import Network
@testable import CardShowScanner

@MainActor final class LocalScannerServerTests: XCTestCase {
    func testConcurrentStartsShareOneListenerAndReadyStartDoesNotRecreateIt() async throws {
        let listener = FakeLocalScannerListener(), factory = FakeLocalScannerFactory()
        factory.listeners = [listener]
        let server = server(factory); defer { server.stop() }
        let first = Task { try await server.start() }
        try await waitFor { listener.starts == 1 }
        var secondEntered = false
        let second = Task { secondEntered = true; try await server.start() }
        try await waitFor { secondEntered }
        XCTAssertEqual(factory.calls, 1)
        listener.emit(.ready)
        try await first.value; try await second.value; try await server.start()
        XCTAssertEqual(factory.calls, 1); XCTAssertEqual(listener.starts, 1)
    }

    func testFailureAfterReadyInvalidatesListenerAndAllowsFreshStart() async throws {
        let old = FakeLocalScannerListener(), replacement = FakeLocalScannerListener(), factory = FakeLocalScannerFactory()
        factory.listeners = [old, replacement]
        let server = server(factory); defer { server.stop() }
        let first = Task { try await server.start() }
        try await waitFor { old.starts == 1 }; old.emit(.ready); try await first.value
        old.emit(.failed(.posix(.ECONNABORTED)))
        let next = Task { try await server.start() }
        try await waitFor { replacement.starts == 1 }
        replacement.emit(.ready); try await next.value
        XCTAssertEqual(factory.calls, 2); XCTAssertEqual(old.cancels, 1)
    }

    func testWaitingAfterReadyInvalidatesButWaitingDuringStartupCanRecover() async throws {
        let old = FakeLocalScannerListener(), replacement = FakeLocalScannerListener(), factory = FakeLocalScannerFactory()
        factory.listeners = [old, replacement]
        let server = server(factory); defer { server.stop() }
        let first = Task { try await server.start() }
        try await waitFor { old.starts == 1 }
        old.emit(.waiting); old.emit(.ready); try await first.value
        XCTAssertEqual(old.cancels, 0)
        old.emit(.waiting)
        let next = Task { try await server.start() }
        try await waitFor { replacement.starts == 1 }
        replacement.emit(.ready); try await next.value
        XCTAssertEqual(old.cancels, 1); XCTAssertEqual(factory.calls, 2)
    }

    func testStaleListenerCallbacksCannotCompleteOrInvalidateReplacement() async throws {
        let old = FakeLocalScannerListener(), replacement = FakeLocalScannerListener(), factory = FakeLocalScannerFactory()
        factory.listeners = [old, replacement]
        let server = server(factory); defer { server.stop() }
        let first = Task { try await server.start() }
        try await waitFor { old.starts == 1 }; old.emit(.ready); try await first.value
        var recovered = false
        let restart = Task { try await server.restart(); recovered = true }
        try await waitFor { replacement.starts == 1 }
        old.emit(.ready); old.emit(.failed(.posix(.ENETDOWN))); old.emit(.cancelled); old.emit(.waiting)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(recovered); XCTAssertEqual(replacement.cancels, 0)
        replacement.emit(.ready); try await restart.value
        XCTAssertTrue(recovered); XCTAssertEqual(factory.calls, 2)
    }

    func testStartupListenerFailureIsRetriedInsteadOfCachingFailedTask() async throws {
        let old = FakeLocalScannerListener(), replacement = FakeLocalScannerListener(), factory = FakeLocalScannerFactory()
        factory.listeners = [old, replacement]
        let server = server(factory); defer { server.stop() }
        let first = Task { try await server.start() }
        try await waitFor { old.starts == 1 }; old.emit(.failed(.posix(.EADDRINUSE)))
        do { try await first.value; XCTFail("Startup must fail") }
        catch { XCTAssertEqual(error as? NWError, .posix(.EADDRINUSE)) }
        let retry = Task { try await server.start() }
        try await waitFor { replacement.starts == 1 }; replacement.emit(.ready); try await retry.value
        XCTAssertEqual(factory.calls, 2)
    }

    func testFactoryFailureAllowsRetry() async throws {
        let listener = FakeLocalScannerListener()
        var calls = 0
        let server = LocalScannerServer(listenerFactory: {
            calls += 1
            if calls == 1 { throw URLError(.cannotConnectToHost) }
            return listener
        }, resourcesAvailable: { true })
        defer { server.stop() }
        do { try await server.start(); XCTFail("Creation failure must be surfaced") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        let retry = Task { try await server.start() }
        try await waitFor { listener.starts == 1 }; listener.emit(.ready); try await retry.value
        XCTAssertEqual(calls, 2)
    }

    func testPendingStartupTimesOutAndNextStartCanSucceed() async throws {
        let old = FakeLocalScannerListener(), replacement = FakeLocalScannerListener(), factory = FakeLocalScannerFactory()
        factory.listeners = [old, replacement]
        let server = server(factory, timeout: .milliseconds(150)); defer { server.stop() }
        let first = Task { try await server.start() }
        try await waitFor { old.starts == 1 }; old.emit(.waiting)
        do { try await first.value; XCTFail("An unready listener must time out") }
        catch { XCTAssertEqual(error as? LocalScannerFailure, .startupTimedOut) }
        let retry = Task { try await server.start() }
        try await waitFor { replacement.starts == 1 }; replacement.emit(.ready); try await retry.value
        XCTAssertEqual(old.cancels, 1); XCTAssertEqual(factory.calls, 2)
    }

    func testOverlappingRestartsCancelOldStartupAndShareReplacement() async throws {
        let old = FakeLocalScannerListener(), replacement = FakeLocalScannerListener(), factory = FakeLocalScannerFactory()
        factory.listeners = [old, replacement]
        let server = server(factory); defer { server.stop() }
        let pending = Task { try await server.start() }
        try await waitFor { old.starts == 1 }
        let first = Task { try await server.restart() }
        try await waitFor { replacement.starts == 1 }
        var secondEntered = false
        let second = Task { secondEntered = true; try await server.restart() }
        try await waitFor { secondEntered }
        XCTAssertEqual(factory.calls, 2)
        do { try await pending.value; XCTFail("Restart must cancel obsolete startup waiters") }
        catch { XCTAssertTrue(error is CancellationError) }
        replacement.emit(.ready); try await first.value; try await second.value
        XCTAssertEqual(old.cancels, 1); XCTAssertEqual(replacement.cancels, 0)
    }

    func testCancellingOneStartupWaiterDoesNotCancelAnother() async throws {
        let listener = FakeLocalScannerListener(), factory = FakeLocalScannerFactory()
        factory.listeners = [listener]
        let server = server(factory); defer { server.stop() }
        let first = Task { try await server.start() }
        try await waitFor { listener.starts == 1 }
        var secondEntered = false
        let second = Task { secondEntered = true; try await server.start() }
        try await waitFor { secondEntered }
        first.cancel()
        do { try await first.value; XCTFail("Cancelled waiter must stop waiting") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(listener.cancels, 0)
        listener.emit(.ready); try await second.value
        XCTAssertEqual(factory.calls, 1)
    }

    func testRestartWaitsForOldSocketReleaseBeforeCreatingReplacement() async throws {
        let old = FakeLocalScannerListener(), replacement = FakeLocalScannerListener(), factory = FakeLocalScannerFactory()
        old.holdCancellation = true; factory.listeners = [old, replacement]
        let server = server(factory); defer { server.stop() }
        let first = Task { try await server.start() }
        try await waitFor { old.starts == 1 }; old.emit(.ready); try await first.value
        let recovery = Task { try await server.restart() }
        try await waitFor { old.cancels == 1 }
        XCTAssertEqual(factory.calls, 1); XCTAssertEqual(replacement.starts, 0)
        old.releaseCancellation()
        try await waitFor { replacement.starts == 1 }; replacement.emit(.ready); try await recovery.value
        XCTAssertEqual(factory.calls, 2)
    }

    func testActualLoopbackServesBundledPageBeforeAndAfterRestartOnSameOrigin() async throws {
        let server = LocalScannerServer()
        defer { server.stop() }
        let token = server.cacheToken
        try await server.start()
        // This checks real loopback delivery across a listener restart, not a
        // three-second performance target on a shared simulator runner. Keep its
        // connection/cache state independent of other URLSession-based tests.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: LocalScannerServer.pageURL)
        request.timeoutInterval = 10; request.cachePolicy = .reloadIgnoringLocalCacheData
        let (before, firstResponse) = try await session.data(for: request)
        XCTAssertEqual((firstResponse as? HTTPURLResponse)?.statusCode, 200); XCTAssertFalse(before.isEmpty)
        try await server.restart()
        let (after, nextResponse) = try await session.data(for: request)
        XCTAssertEqual((nextResponse as? HTTPURLResponse)?.statusCode, 200); XCTAssertEqual(after, before)
        XCTAssertEqual(server.cacheToken, token)
        XCTAssertEqual(LocalScannerServer.pageURL.absoluteString, "http://127.0.0.1:18764/index.html")
    }

    func testReachabilityChecksShareOneProbeAndDoNotReplaceHealthyListener() async throws {
        let listener = FakeLocalScannerListener(), factory = FakeLocalScannerFactory(), probe = ControlledLocalHealthProbe()
        factory.listeners = [listener]
        let server = server(factory, probe: probe.check); defer { server.stop() }
        let first = Task { try await server.ensureReachable() }
        try await waitFor { listener.starts == 1 }; listener.emit(.ready)
        try await waitFor { probe.calls == 1 }
        var secondEntered = false
        let second = Task { secondEntered = true; try await server.ensureReachable() }
        try await waitFor { secondEntered }
        XCTAssertEqual(probe.calls, 1); XCTAssertEqual(factory.calls, 1)
        probe.finish(0, reachable: true)
        try await first.value; try await second.value
        XCTAssertEqual(listener.cancels, 0)
        // Each later foreground opening verifies liveness; ready is not cached
        // forever, and successful verification does not recreate the listener.
        let later = Task { try await server.ensureReachable() }
        try await waitFor { probe.calls == 2 }; probe.finish(1, reachable: true)
        try await later.value
        XCTAssertEqual(factory.calls, 1)
        XCTAssertEqual(probe.tokens, [server.cacheToken, server.cacheToken])
        XCTAssertEqual(probe.generations[0], probe.generations[1])
    }

    func testUnreachableCachedListenerGetsOneReplacementAndVerification() async throws {
        let old = FakeLocalScannerListener(), replacement = FakeLocalScannerListener(), factory = FakeLocalScannerFactory()
        let probe = ControlledLocalHealthProbe(); factory.listeners = [old, replacement]
        let server = server(factory, probe: probe.check); defer { server.stop() }
        let check = Task { try await server.ensureReachable() }
        try await waitFor { old.starts == 1 }; old.emit(.ready)
        try await waitFor { probe.calls == 1 }; probe.finish(0, reachable: false)
        try await waitFor { replacement.starts == 1 }; replacement.emit(.ready)
        try await waitFor { probe.calls == 2 }; probe.finish(1, reachable: true)
        try await check.value
        XCTAssertEqual(factory.calls, 2); XCTAssertEqual(old.cancels, 1)
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertNotEqual(probe.generations[0], probe.generations[1])
        XCTAssertEqual(probe.tokens[0], probe.tokens[1])
    }

    func testFailedReplacementVerificationStopsInsteadOfLooping() async throws {
        let old = FakeLocalScannerListener(), replacement = FakeLocalScannerListener(), factory = FakeLocalScannerFactory()
        let probe = ControlledLocalHealthProbe(); factory.listeners = [old, replacement]
        let server = server(factory, probe: probe.check); defer { server.stop() }
        let check = Task { try await server.ensureReachable() }
        try await waitFor { old.starts == 1 }; old.emit(.ready)
        try await waitFor { probe.calls == 1 }; probe.finish(0, reachable: false)
        try await waitFor { replacement.starts == 1 }; replacement.emit(.ready)
        try await waitFor { probe.calls == 2 }; probe.finish(1, reachable: false)
        do { try await check.value; XCTFail("A second unreachable socket must fail, not restart indefinitely") }
        catch { XCTAssertEqual(error as? LocalScannerFailure, .listenerUnavailable) }
        XCTAssertEqual(factory.calls, 2); XCTAssertEqual(probe.calls, 2)
    }

    func testCancelingOneHealthWaiterKeepsAnotherProbeAndListenerActive() async throws {
        let listener = FakeLocalScannerListener(), factory = FakeLocalScannerFactory(), probe = ControlledLocalHealthProbe()
        factory.listeners = [listener]
        let server = server(factory, probe: probe.check); defer { server.stop() }
        let first = Task { try await server.ensureReachable() }
        try await waitFor { listener.starts == 1 }; listener.emit(.ready)
        try await waitFor { probe.calls == 1 }
        var secondEntered = false
        let second = Task { secondEntered = true; try await server.ensureReachable() }
        try await waitFor { secondEntered }
        first.cancel()
        do { try await first.value; XCTFail("Cancelled caller must stop waiting") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(listener.cancels, 0); XCTAssertEqual(probe.calls, 1)
        probe.finish(0, reachable: true); try await second.value
        XCTAssertEqual(factory.calls, 1)
    }

    func testCancelledOldProbeCannotRestartOrCompleteANewerHealthOperation() async throws {
        let listener = FakeLocalScannerListener(), factory = FakeLocalScannerFactory(), probe = ControlledLocalHealthProbe()
        factory.listeners = [listener]
        let server = server(factory, probe: probe.check); defer { server.stop() }
        let first = Task { try await server.ensureReachable() }
        try await waitFor { listener.starts == 1 }; listener.emit(.ready)
        try await waitFor { probe.calls == 1 }
        first.cancel()
        do { try await first.value; XCTFail("Cancelled caller must stop waiting") }
        catch { XCTAssertTrue(error is CancellationError) }
        var completed = false
        let next = Task { try await server.ensureReachable(); completed = true }
        try await waitFor { probe.calls == 2 }
        // Deliberately ignore cancellation in the fake transport, modeling a
        // late browser/network callback from the previous owner.
        probe.finish(0, reachable: false)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(completed); XCTAssertEqual(listener.cancels, 0)
        XCTAssertEqual(factory.calls, 1)
        probe.finish(1, reachable: true); try await next.value
        XCTAssertTrue(completed)
    }

    func testOldFailedProbeDoesNotRestartListenerAlreadyReplacedByAnotherClient() async throws {
        let old = FakeLocalScannerListener(), replacement = FakeLocalScannerListener(), factory = FakeLocalScannerFactory()
        let probe = ControlledLocalHealthProbe(); factory.listeners = [old, replacement]
        let server = server(factory, probe: probe.check); defer { server.stop() }
        let check = Task { try await server.ensureReachable() }
        try await waitFor { old.starts == 1 }; old.emit(.ready)
        try await waitFor { probe.calls == 1 }
        let external = Task { try await server.restart() }
        try await waitFor { replacement.starts == 1 }; replacement.emit(.ready); try await external.value
        probe.finish(0, reachable: false)
        try await waitFor { probe.calls == 2 }
        XCTAssertEqual(factory.calls, 2); XCTAssertEqual(replacement.cancels, 0)
        probe.finish(1, reachable: true); try await check.value
        XCTAssertEqual(factory.calls, 2)
    }

    func testHealthProbeDeadlineCanRecoverWithoutWaitingForAnUncooperativeOldProbe() async throws {
        let old = FakeLocalScannerListener(), replacement = FakeLocalScannerListener(), factory = FakeLocalScannerFactory()
        let probe = ControlledLocalHealthProbe(); factory.listeners = [old, replacement]
        let server = server(factory, probeTimeout: .milliseconds(100), probe: probe.check); defer { server.stop() }
        let check = Task { try await server.ensureReachable() }
        try await waitFor { old.starts == 1 }; old.emit(.ready)
        try await waitFor { probe.calls == 1 }
        try await waitFor { replacement.starts == 1 }; replacement.emit(.ready)
        try await waitFor { probe.calls == 2 }; probe.finish(1, reachable: true)
        try await check.value
        probe.finish(0, reachable: false)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(factory.calls, 2); XCTAssertEqual(replacement.cancels, 0)
    }

    func testStoppingServerCancelsHealthWaitersAndRetiresLateProbeFailure() async throws {
        let listener = FakeLocalScannerListener(), factory = FakeLocalScannerFactory(), probe = ControlledLocalHealthProbe()
        factory.listeners = [listener]
        let server = server(factory, probe: probe.check)
        let check = Task { try await server.ensureReachable() }
        try await waitFor { listener.starts == 1 }; listener.emit(.ready)
        try await waitFor { probe.calls == 1 }
        server.stop()
        do { try await check.value; XCTFail("Stopping must release health waiters") }
        catch { XCTAssertTrue(error is CancellationError) }
        probe.finish(0, reachable: false)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(factory.calls, 1)
    }

    private func server(_ factory: FakeLocalScannerFactory, timeout: Duration = .seconds(2),
                        probeTimeout: Duration = .seconds(1), probe: LocalScannerServer.ReachabilityProbe? = nil) -> LocalScannerServer {
        LocalScannerServer(listenerFactory: { try factory.make() }, startupTimeout: timeout, resourcesAvailable: { true },
                           probeTimeout: probeTimeout, reachabilityProbe: probe)
    }
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Listener operation did not begin"); throw URLError(.timedOut)
    }
}

@MainActor private final class ControlledLocalHealthProbe {
    private var pending: [CheckedContinuation<Bool, Error>?] = []
    private(set) var tokens: [String] = []
    private(set) var generations: [UUID] = []
    var calls: Int { pending.count }
    func check(token: String, generation: UUID) async throws -> Bool {
        tokens.append(token); generations.append(generation)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ index: Int, reachable: Bool) {
        let continuation = pending[index]; pending[index] = nil
        continuation?.resume(returning: reachable)
    }
}

@MainActor private final class FakeLocalScannerFactory {
    var listeners: [FakeLocalScannerListener] = []
    private(set) var calls = 0
    func make() throws -> any LocalScannerListening {
        guard calls < listeners.count else { throw URLError(.cannotConnectToHost) }
        defer { calls += 1 }
        return listeners[calls]
    }
}

@MainActor private final class FakeLocalScannerListener: LocalScannerListening {
    private(set) var starts = 0
    private(set) var cancels = 0
    var holdCancellation = false
    private var state: (@MainActor (LocalScannerListenerState) -> Void)?
    private var cancellation: CheckedContinuation<Void, Never>?
    func start(onState: @escaping @MainActor (LocalScannerListenerState) -> Void,
               onConnection: @escaping @MainActor (NWConnection) -> Void) {
        starts += 1; state = onState
    }
    func emit(_ value: LocalScannerListenerState) { state?(value) }
    func cancel() async {
        cancels += 1
        if holdCancellation { await withCheckedContinuation { cancellation = $0 } }
        state?(.cancelled)
    }
    func releaseCancellation() { holdCancellation = false; cancellation?.resume(); cancellation = nil }
}
