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
}
