import XCTest
@testable import CardShowScanner

final class ScannerPageRecoveryTests: XCTestCase {
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
