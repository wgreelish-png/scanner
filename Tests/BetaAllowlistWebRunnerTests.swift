import XCTest
@testable import CardShowScanner

@MainActor final class BetaAllowlistWebRunnerTests: XCTestCase {
    func testOnlyExactWebsiteIPSettingsMayRun() {
        XCTAssertTrue(BetaAllowlistWebRunner.allowsPage(URL(string: "https://tcgtracking.com/apiforbeta")))
        for value in ["http://tcgtracking.com/apiforbeta", "https://tcgtracking.com.evil/apiforbeta",
                      "https://www.tcgtracking.com/apiforbeta", "https://tcgtracking.com:443/apiforbeta",
                      "https://user:secret@tcgtracking.com/apiforbeta", "https://tcgtracking.com/apiforbeta?token=fixture",
                      "https://tcgtracking.com/apiforbeta#other", "https://tcgtracking.com/apiforbeta/",
                      "https://tcgtracking.com/login.php", "about:blank"] {
            XCTAssertFalse(BetaAllowlistWebRunner.allowsPage(URL(string: value)), value)
        }
        XCTAssertFalse(BetaAllowlistWebRunner.allowsPage(nil))
    }

    func testSuccessfulSaveNeedsExactlyTheConfirmedPublicIP() {
        let ip = "8.8.8.8"
        let saved: [String: Any] = ["status": "saved", "allowedIPs": [ip]]
        XCTAssertEqual(BetaAllowlistWebRunner.result(from: saved, confirmedIP: ip), .init(status: .saved, ip: ip))
        XCTAssertEqual(BetaAllowlistWebRunner.result(from: saved).status, .saveFailed)
        for list in [[], ["1.1.1.1"], [ip, "1.1.1.1"], ["10.0.0.1"], ["8.8.8.8/32"]] {
            XCTAssertEqual(BetaAllowlistWebRunner.result(from: ["status": "saved", "allowedIPs": list], confirmedIP: ip).status, .saveFailed)
        }
        XCTAssertEqual(BetaAllowlistWebRunner.result(from: ["status": "saved", "allowedIPs": ["127.0.0.1"]], confirmedIP: "127.0.0.1").status, .saveFailed)
    }

    func testConfirmedIPv6MayUseEquivalentProviderNotation() {
        let result = BetaAllowlistWebRunner.result(from: ["status": "already_current",
            "allowedIPs": ["2606:4700:4700:0000:0000:0000:0000:1111"]], confirmedIP: "2606:4700:4700::1111")
        XCTAssertEqual(result, .init(status: .alreadyCurrent, ip: "2606:4700:4700::1111"))
    }

    func testUntrustedErrorsCannotBecomeAccountOrNetworkDetails() {
        let invalid: [Any] = ["secret raw text", ["status": "unrecognized", "token": "fixture-secret"], [:]]
        for value in invalid {
            XCTAssertEqual(BetaAllowlistWebRunner.result(from: value), .init(status: .pageChanged))
        }
        for (wire, status) in [("sign_in_required", BetaAllowlistSyncResult.Status.signInRequired),
                               ("account_mismatch", .accountMismatch), ("access_denied", .accessDenied),
                               ("network_failed", .networkFailed)] {
            XCTAssertEqual(BetaAllowlistWebRunner.result(from: ["status": wire, "error": "fixture-secret"]), .init(status: status))
        }
    }

    func testRetryDelayIsBoundedAndDoesNotChangeFailureClassification() {
        XCTAssertEqual(BetaAllowlistWebRunner.result(from: ["status": "rate_limited", "retryAfterSeconds": 120]), .init(status: .rateLimited, retryAfterSeconds: 120))
        XCTAssertEqual(BetaAllowlistWebRunner.result(from: ["status": "save_failed", "retryAfterSeconds": 999_999]).retryAfterSeconds, 86_400)
        for delay in [-1.0, Double.nan, Double.infinity] {
            XCTAssertNil(BetaAllowlistWebRunner.result(from: ["status": "rate_limited", "retryAfterSeconds": delay]).retryAfterSeconds)
        }
    }

    func testAutomaticIPResourceShipsAndNoBackgroundExecutionIsDeclared() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "BetaAllowlist", withExtension: "js"))
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).isEmpty)
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes"))
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"))
    }
}
