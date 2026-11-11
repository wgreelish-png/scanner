import XCTest
import SwiftData
@testable import CardShowScanner

final class ScannerPageRecoveryTests: XCTestCase {
    func testDecliningManualSearchSuppressesFurtherModalPromptsForTwoMinutes() {
        var policy = ScannerManualSearchPromptPolicy()
        XCTAssertTrue(policy.shouldPresent(at: 10))
        policy.declined(at: 10)
        XCTAssertFalse(policy.shouldPresent(at: 10))
        XCTAssertFalse(policy.shouldPresent(at: 70))
        XCTAssertFalse(policy.shouldPresent(at: 129.999))
        XCTAssertTrue(policy.shouldPresent(at: 130))
        policy.declined(at: 150)
        XCTAssertFalse(policy.shouldPresent(at: 260), "A later explicit decline starts its own pause")
        XCTAssertTrue(policy.shouldPresent(at: 270))
        XCTAssertTrue(ScannerManualSearchPromptPolicy().shouldPresent(at: 20), "A new scanner session has its own policy")
    }

    func testInvalidOrBackwardPromptClockCannotBypassTheDeclinedCooldown() {
        var policy = ScannerManualSearchPromptPolicy()
        for time in [Double.nan, Double.infinity, -1] {
            XCTAssertFalse(policy.shouldPresent(at: time))
            policy.declined(at: time)
        }
        XCTAssertTrue(policy.shouldPresent(at: 100), "An invalid decline does not poison a valid new session")
        policy.declined(at: 100)
        XCTAssertFalse(policy.shouldPresent(at: 99))
        policy.declined(at: .nan)
        XCTAssertFalse(policy.shouldPresent(at: 200))
        XCTAssertTrue(policy.shouldPresent(at: 220))
    }

    func testPublicThermalAndPowerSignalsChooseConservativeScannerWorkWithoutInventedThresholds() {
        for thermal in [DeviceThermalLevel.nominal, .fair, .serious, .critical, .unknown] {
            for lowPower in [false, true] {
                let mode = ScannerResourceMode.policy(for: DeviceResourceState(thermal: thermal, lowPowerMode: lowPower))
                switch thermal {
                case .serious, .critical: XCTAssertEqual(mode, .cooling)
                case .fair: XCTAssertEqual(mode, .reduced)
                case .nominal, .unknown: XCTAssertEqual(mode, lowPower ? .reduced : .normal)
                }
            }
        }
    }
    func testConnectionFailureGetsOneRetry() {
        for code: URLError.Code in [.cannotConnectToHost, .networkConnectionLost, .timedOut] {
            XCTAssertTrue(ScannerPageRecoveryPolicy.allowsRetry(error: URLError(code), attempts: 0))
            XCTAssertFalse(ScannerPageRecoveryPolicy.allowsRetry(error: URLError(code), attempts: 1))
            XCTAssertFalse(ScannerPageRecoveryPolicy.allowsRetry(error: URLError(code), attempts: 2))
        }
    }
    func testCancellationAndUnrelatedFailuresDoNotRestartTheServer() {
        for code: URLError.Code in [.cancelled, .notConnectedToInternet, .badURL, .userAuthenticationRequired, .secureConnectionFailed] {
            XCTAssertFalse(ScannerPageRecoveryPolicy.allowsRetry(error: URLError(code), attempts: 0))
        }
        XCTAssertFalse(ScannerPageRecoveryPolicy.allowsRetry(error: NSError(domain: "WKErrorDomain", code: 4), attempts: 0))
        XCTAssertFalse(ScannerPageRecoveryPolicy.allowsRetry(error: NSError(domain: "Other", code: -1004), attempts: 0))
    }
    func testSaveBeforeScannerReadyReleasesTheSavedRecognitionExactlyOnce() {
        var queue = ScannerReviewReleaseQueue()
        XCTAssertNil(queue.request("p:123"), "A saved review must wait for the restarted scanner's bridge")
        queue.loading()
        XCTAssertEqual(queue.becameReady(), "p:123", "Readiness delivers the frozen saved identity")
        XCTAssertNil(queue.becameReady(), "Repeated readiness cannot replay the save release")
        XCTAssertEqual(queue.request("p:124"), "p:124", "An initialized camera releases the next saved review directly")
        XCTAssertNil(queue.becameReady(), "A direct release must not also be queued")
    }
    func testRestartCannotReplayAQueuedReleaseFromAnEarlierDocument() {
        var queue = ScannerReviewReleaseQueue()
        XCTAssertNil(queue.request("p:123"))
        queue.restart()
        XCTAssertNil(queue.becameReady(), "A stopped document's pending save cannot release a new scan")
        queue.restart()
        XCTAssertNil(queue.request("p:124"), "The next document must wait for its own readiness")
        XCTAssertEqual(queue.becameReady(), "p:124")
        XCTAssertNil(queue.becameReady())
    }
    func testExplicitScanNextDiscardsAQueuedReleaseAndPreservesReadyCameraState() {
        var queue = ScannerReviewReleaseQueue()
        XCTAssertNil(queue.request("p:123"))
        queue.discardPending()
        XCTAssertNil(queue.becameReady(), "An abandoned review cannot release an explicitly rearmed scan")
        XCTAssertEqual(queue.request("p:124"), "p:124")
        queue.discardPending()
        XCTAssertEqual(queue.request("p:125"), "p:125", "Discarding a draft does not make the authorized camera unready")
        XCTAssertNil(queue.becameReady())
    }
}

@MainActor final class ScannerManualSearchLifecycleTests: XCTestCase {
    private func store() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func card() -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:123", printing: "Normal"),
                      name: "Manual return fixture", set: "Lifecycle", number: "1", marketPrice: nil,
                      confidence: 96, printings: ["Normal"])
    }
    func testManualEntryKeepsOneConsumerAndRejectsLateRecognitionUntilDismissal() throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        let provider = ManualSearchScannerProvider(), model = ScannerViewModel(provider: provider, pricing: ManualSearchPricing())
        model.start(game: "Pokémon", list: list, context: context, session: session)
        defer { model.stop() }
        XCTAssertTrue(model.suspendForManualSearch())
        model.receive(ScanResult(id: UUID(), candidates: [card()], accepted: true, same: false))
        model.start(game: "Pokémon", list: list, context: context, session: session)
        XCTAssertNil(model.selected); XCTAssertEqual(provider.starts, 1)
        XCTAssertEqual(provider.stops, 0); XCTAssertEqual(provider.suspensions, 1)
        model.resumeAfterManualSearch(); model.resumeAfterManualSearch()
        XCTAssertEqual(provider.resumptions, 1, "One dismissal resumes the existing stream exactly once")
        XCTAssertEqual(provider.starts, 1); XCTAssertEqual(provider.stops, 0)
        model.receive(ScanResult(id: UUID(), candidates: [card()], accepted: true, same: false))
        XCTAssertEqual(model.selected?.identity.productID, "p:123")
        XCTAssertEqual(list.quantity, 0, "Returning to capture cannot save a card")
    }
    func testBackgroundStopWhileManualEntryIsOpenNeedsFreshValidatedStartAfterDismissal() throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        let provider = ManualSearchScannerProvider(), model = ScannerViewModel(provider: provider, pricing: ManualSearchPricing())
        model.start(game: "Pokémon", list: list, context: context, session: session)
        XCTAssertTrue(model.suspendForManualSearch())
        model.stop()
        model.start(game: "Pokémon", list: list, context: context, session: session)
        XCTAssertEqual(provider.starts, 1, "Foreground cannot reopen capture behind catalog entry")
        model.resumeAfterManualSearch()
        XCTAssertEqual(provider.resumptions, 0, "A dismissed sheet cannot resurrect a stopped provider")
        model.start(game: "Pokémon", list: list, context: context, session: session)
        XCTAssertEqual(provider.starts, 2)
        model.stop()
    }
    func testManualFallbackRequiresExplicitDiscardAndCannotDiscardAnOngoingConfirmation() throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        let provider = ManualSearchScannerProvider(), model = ScannerViewModel(provider: provider, pricing: ManualSearchPricing())
        model.start(game: "Pokémon", list: list, context: context, session: session)
        defer { model.stop() }
        model.receive(ScanResult(id: UUID(), candidates: [card()], accepted: true, same: false))
        XCTAssertFalse(model.suspendForManualSearch(), "A frozen review is preserved without explicit discard")
        XCTAssertNotNil(model.selected)
        model.selectionInProgress = true
        XCTAssertFalse(model.suspendForManualSearch(discardSelection: true))
        XCTAssertNotNil(model.selected)
        model.selectionInProgress = false
        XCTAssertTrue(model.suspendForManualSearch(discardSelection: true))
        XCTAssertNil(model.selected); XCTAssertNil(model.result); XCTAssertFalse(model.priceLoading)
        XCTAssertEqual(list.quantity, 0); XCTAssertEqual(session.addedQuantity, 0)
        model.paused = true; model.resumeAfterManualSearch()
        XCTAssertEqual(provider.resumptions, 0, "Explicit camera pause survives manual dismissal")
    }
}

@MainActor private final class ManualSearchScannerProvider: ScannerProvider {
    let label = "Manual lifecycle fixture"
    private(set) var results: AsyncStream<ScanResult>
    private var continuation: AsyncStream<ScanResult>.Continuation
    var starts = 0, stops = 0, suspensions = 0, resumptions = 0
    init() {
        let pair = AsyncStream<ScanResult>.makeStream()
        results = pair.stream; continuation = pair.continuation
    }
    func start(game: String) {
        starts += 1
        let pair = AsyncStream<ScanResult>.makeStream()
        results = pair.stream; continuation = pair.continuation
    }
    func stop() { stops += 1; continuation.finish() }
    func suspendForManualSearch() { suspensions += 1 }
    func resumeAfterManualSearch() { resumptions += 1 }
    func clearCache() async throws {}
}

private struct ManualSearchPricing: MarketPricing {
    func quote(for card: CardCandidate) async throws -> MarketQuote? { nil }
}
