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

    private func server(_ factory: FakeLocalScannerFactory, timeout: Duration = .seconds(2)) -> LocalScannerServer {
        LocalScannerServer(listenerFactory: { try factory.make() }, startupTimeout: timeout, resourcesAvailable: { true })
    }
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Listener operation did not begin"); throw URLError(.timedOut)
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
