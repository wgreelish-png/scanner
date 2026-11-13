import XCTest
@testable import CardShowScanner

@MainActor final class ScannerDownloadGateTests: XCTestCase {
    func testInitialDownloadWaitsForApprovalAndCannotBeApprovedTwice() async {
        let loader = DownloadGateLoader()
        var proceeded = 0
        let gate = ScannerDownloadGate(loader: loader.load)
        gate.begin(game: "Pokémon", action: .initialLoad) { proceeded += 1 }
        gate.approve(); gate.continueWithoutEstimate()
        XCTAssertEqual(proceeded, 0, "Neither action can bypass an unfinished estimate")
        await wait { loader.requests.count == 1 }
        XCTAssertEqual(loader.requests.first?.preferSaved, true)
        loader.succeed(0, preview: plan())
        await wait { self.isReady(gate.state) }
        XCTAssertEqual(proceeded, 0, "Receiving metadata must not start payload download")
        gate.approve(); gate.approve(); gate.continueWithoutEstimate()
        XCTAssertEqual(proceeded, 1)
        XCTAssertNil(gate.state.action)
    }

    func testCompleteSavedPackOpensImmediatelyButExplicitRefreshStillShowsPlan() async {
        let loader = DownloadGateLoader()
        var proceeded = 0
        let gate = ScannerDownloadGate(loader: loader.load)
        gate.begin(game: "Pokémon", action: .initialLoad) { proceeded += 1 }
        await wait { loader.requests.count == 1 }
        loader.succeed(0, preview: plan(missingFiles: 0))
        await wait { proceeded == 1 }
        XCTAssertNil(gate.state.action)

        gate.begin(game: "Pokémon", action: .refresh) { proceeded += 1 }
        await wait { loader.requests.count == 2 }
        XCTAssertEqual(loader.requests.last?.preferSaved, false)
        loader.succeed(1, preview: plan(missingFiles: 0))
        await wait { self.isReady(gate.state) }
        XCTAssertEqual(gate.state.action, .refresh)
        XCTAssertEqual(proceeded, 1, "A manually requested refresh remains reviewable even when no files are missing")
        gate.approve()
        XCTAssertEqual(proceeded, 2)
    }

    func testCancelPreventsLateResultAndStaleApprovalFromStartingDownload() async {
        let loader = DownloadGateLoader()
        var proceeded = 0
        let gate = ScannerDownloadGate(loader: loader.load)
        gate.begin(game: "Pokémon", action: .initialLoad) { proceeded += 1 }
        await wait { loader.requests.count == 1 }
        gate.cancel()
        loader.succeed(0, preview: plan(missingFiles: 0))
        await settle()
        gate.approve(); gate.continueWithoutEstimate(); gate.retry()
        XCTAssertNil(gate.state.action)
        XCTAssertEqual(loader.requests.count, 1)
        XCTAssertEqual(proceeded, 0)
    }

    func testReplacedRequestCannotOverwriteNewGameOrInvokeOldContinuation() async {
        let loader = DownloadGateLoader()
        var oldProceeded = 0
        var newProceeded = 0
        let gate = ScannerDownloadGate(loader: loader.load)
        gate.begin(game: "Pokémon", action: .initialLoad) { oldProceeded += 1 }
        await wait { loader.requests.count == 1 }
        gate.begin(game: "Magic: The Gathering", action: .initialLoad) { newProceeded += 1 }
        await wait { loader.requests.count == 2 }
        loader.succeed(1, preview: plan(gameKey: "tcgp:1"))
        await wait { self.isReady(gate.state) }
        loader.succeed(0, preview: plan(missingFiles: 0))
        await settle()
        guard case .ready(let preview, _) = gate.state else { return XCTFail("New game's preview must remain visible") }
        XCTAssertEqual(preview.gameKey, "tcgp:1")
        gate.approve()
        XCTAssertEqual(oldProceeded, 0)
        XCTAssertEqual(newProceeded, 1)
    }

    func testUnavailableEstimateRequiresExplicitContinueOrRetry() async {
        let loader = DownloadGateLoader()
        var proceeded = 0
        let gate = ScannerDownloadGate(loader: loader.load)
        gate.begin(game: "Pokémon", action: .refresh) { proceeded += 1 }
        await wait { loader.requests.count == 1 }
        loader.fail(0)
        await wait { self.isUnavailable(gate.state) }
        gate.approve()
        XCTAssertEqual(proceeded, 0)
        gate.retry()
        await wait { loader.requests.count == 2 }
        XCTAssertEqual(loader.requests.last?.preferSaved, false)
        loader.fail(1)
        await wait { self.isUnavailable(gate.state) }
        XCTAssertEqual(proceeded, 0)
        gate.continueWithoutEstimate(); gate.continueWithoutEstimate()
        XCTAssertEqual(proceeded, 1)
    }

    func testWrongGameMetadataNeverAutoStartsEvenIfItClaimsCompleteCache() async {
        let loader = DownloadGateLoader()
        var proceeded = 0
        let gate = ScannerDownloadGate(loader: loader.load)
        gate.begin(game: "Pokémon", action: .initialLoad) { proceeded += 1 }
        await wait { loader.requests.count == 1 }
        loader.succeed(0, preview: plan(gameKey: "tcgp:1", missingFiles: 0))
        await wait { self.isUnavailable(gate.state) }
        gate.approve()
        XCTAssertEqual(proceeded, 0)
        gate.cancel()
    }

    private func plan(gameKey: String = "tcgp:3", missingFiles: Int = 2) -> ScannerDownloadPreview {
        ScannerDownloadPreview(gameKey: gameKey,
            downloadBytes: missingFiles == 0 ? 0 : 1024,
            cachedBytes: missingFiles == 0 ? 2048 : 0,
            minimumAdditionalStorageBytes: missingFiles == 0 ? 0 : 1000,
            additionalStorageIsExact: missingFiles == 0,
            missingFiles: missingFiles, totalFiles: 2,
            isUsingCachedMetadata: missingFiles == 0, availableStorageBytes: 1_000_000)
    }

    private func isReady(_ state: ScannerDownloadGateState) -> Bool {
        if case .ready = state { return true }; return false
    }
    private func isUnavailable(_ state: ScannerDownloadGateState) -> Bool {
        if case .unavailable = state { return true }; return false
    }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Expected download gate transition did not occur", file: file, line: line)
    }
    private func settle() async { for _ in 0..<20 { await Task.yield() } }
}

@MainActor private final class DownloadGateLoader {
    struct Request { let game: String; let preferSaved: Bool }
    private(set) var requests: [Request] = []
    private var pending: [Int: CheckedContinuation<ScannerDownloadPreview, Error>] = [:]
    func load(game: String, preferSaved: Bool) async throws -> ScannerDownloadPreview {
        try await withCheckedThrowingContinuation { continuation in
            let index = requests.count
            requests.append(Request(game: game, preferSaved: preferSaved))
            pending[index] = continuation
        }
    }
    func succeed(_ index: Int, preview: ScannerDownloadPreview) { pending.removeValue(forKey: index)?.resume(returning: preview) }
    func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: Failure.offline) }
    private enum Failure: Error { case offline }
}
