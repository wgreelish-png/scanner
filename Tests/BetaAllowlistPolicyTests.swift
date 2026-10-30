import XCTest
@testable import CardShowScanner

final class BetaAllowlistPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPublicIPv4AndAnycastAssignmentsAreAccepted() {
        for address in ["8.8.8.8", "1.1.1.1", "192.0.0.9", "192.0.0.10"] {
            XCTAssertEqual(BetaAllowlistAddress.canonical(address), address)
        }
    }

    func testIPv6CompressedAndExpandedSpellingsHaveOneIdentity() {
        XCTAssertEqual(BetaAllowlistAddress.canonical("2606:4700:4700:0000:0000:0000:0000:1111"), "2606:4700:4700::1111")
        XCTAssertTrue(BetaAllowlistAddress.matches("2606:4700:4700::ABCD", "2606:4700:4700:0:0:0:0:abcd"))
        XCTAssertNotEqual(BetaAllowlistAddress.canonical("2606:4700:4700::1111"), BetaAllowlistAddress.canonical("2606:4700:4700::1001"))
    }

    func testOuterWhitespaceIsNormalizedButInternalWhitespaceIsRejected() {
        XCTAssertEqual(BetaAllowlistAddress.canonical(" \n8.8.8.8\t"), "8.8.8.8")
        XCTAssertNil(BetaAllowlistAddress.canonical("8.8. 8.8"))
        XCTAssertNil(BetaAllowlistAddress.canonical("2606:4700: 4700::1111"))
    }

    func testPrivateLoopbackSharedAndUnspecifiedIPv4AreRejected() {
        for address in ["0.0.0.0", "0.1.2.3", "10.1.2.3", "100.64.0.1", "100.127.255.254", "127.0.0.1", "169.254.1.1", "172.16.0.1", "172.31.255.254", "192.168.1.1"] {
            XCTAssertNil(BetaAllowlistAddress.canonical(address), address)
        }
        XCTAssertNotNil(BetaAllowlistAddress.canonical("172.32.0.1"))
        XCTAssertNotNil(BetaAllowlistAddress.canonical("100.128.0.1"))
    }

    func testIPv4DocumentationBenchmarkMulticastAndReservedAddressesAreRejected() {
        for address in ["192.0.0.1", "192.0.2.10", "198.51.100.1", "203.0.113.9", "198.18.0.1", "198.19.255.1", "224.0.0.1", "239.1.2.3", "240.0.0.1", "255.255.255.255"] {
            XCTAssertNil(BetaAllowlistAddress.canonical(address), address)
        }
    }

    func testNonPublicAndDocumentationIPv6AreRejected() {
        for address in ["::", "::1", "fe80::1", "fc00::1", "fdff::1", "ff02::1", "2001:db8::1", "2001:2::1", "2001:10::1", "2001:20::1", "3fff::1"] {
            XCTAssertNil(BetaAllowlistAddress.canonical(address), address)
        }
    }

    func testMappedIPv4CannotHideAPrivateAddressAndSharesPublicIdentity() {
        XCTAssertEqual(BetaAllowlistAddress.canonical("::ffff:8.8.8.8"), "8.8.8.8")
        XCTAssertTrue(BetaAllowlistAddress.matches("::ffff:0808:0808", "8.8.8.8"))
        for address in ["::ffff:127.0.0.1", "::ffff:192.168.1.1", "::ffff:203.0.113.1"] {
            XCTAssertNil(BetaAllowlistAddress.canonical(address))
        }
    }

    func testRangesPortsInterfaceScopesHostnamesAndMalformedAddressesAreRejected() {
        for address in ["", "8.8.8.8/32", "8.8.8.8:443", "[2606:4700:4700::1111]", "fe80::1%en0", "2606:4700:4700::1111%en0", "dns.google", "https://8.8.8.8", "999.1.1.1", "08.8.8.8", "8.8.8", "::ffff:999.1.1.1", "8.8.8.8\u{0}attacker", "８.８.８.８"] {
            XCTAssertNil(BetaAllowlistAddress.canonical(address), address)
        }
    }

    func testCurrentAllowlistMustBeExactlyOneValidAddress() {
        XCTAssertTrue(BetaAllowlistAddress.isCurrentSingleton(["2606:4700:4700:0:0:0:0:1111"], detectedIP: "2606:4700:4700::1111"))
        XCTAssertFalse(BetaAllowlistAddress.isCurrentSingleton([], detectedIP: "8.8.8.8"))
        XCTAssertFalse(BetaAllowlistAddress.isCurrentSingleton(["8.8.8.8", "1.1.1.1"], detectedIP: "8.8.8.8"))
        XCTAssertFalse(BetaAllowlistAddress.isCurrentSingleton(["8.8.8.8/32"], detectedIP: "8.8.8.8"))
        XCTAssertFalse(BetaAllowlistAddress.isCurrentSingleton(["1.1.1.1"], detectedIP: "8.8.8.8"))
        XCTAssertFalse(BetaAllowlistAddress.isCurrentSingleton([""], detectedIP: ""))
    }

    func testNoCheckIsAllowedWhenInactiveOrDisabled() {
        let policy = BetaAllowlistSyncPolicy()
        XCTAssertTrue(policy.isDue(at: now, isActive: true, enabled: true))
        XCTAssertFalse(policy.isDue(at: now, isActive: false, enabled: true))
        XCTAssertFalse(policy.isDue(at: now, isActive: true, enabled: false))
    }

    func testSuccessfulChecksWaitAMinuteAndForegroundReentryCanCheckImmediately() {
        var policy = BetaAllowlistSyncPolicy()
        policy.recordSuccess(at: now)
        XCTAssertFalse(policy.isDue(at: now.addingTimeInterval(59.9), isActive: true, enabled: true))
        XCTAssertTrue(policy.isDue(at: now.addingTimeInterval(60), isActive: true, enabled: true))
        policy.resetForForeground()
        XCTAssertTrue(policy.isDue(at: now.addingTimeInterval(1), isActive: true, enabled: true))
    }

    func testForegroundReentryNeverBypassesFailureCooldown() {
        var policy = BetaAllowlistSyncPolicy()
        policy.recordFailure(at: now, retryAfterSeconds: 180)
        policy.resetForForeground()
        XCTAssertFalse(policy.isDue(at: now.addingTimeInterval(179.9), isActive: true, enabled: true))
        XCTAssertTrue(policy.isDue(at: now.addingTimeInterval(180), isActive: true, enabled: true))
    }

    func testMissingInvalidAndSmallRetryAfterUseAMinuteFailureCooldown() {
        let retries: [TimeInterval?] = [nil, -1, .nan, .infinity, 0, 7]
        for retry in retries {
            var policy = BetaAllowlistSyncPolicy()
            policy.recordFailure(at: now, retryAfterSeconds: retry)
            XCTAssertEqual(policy.cooldownUntil, now.addingTimeInterval(60))
            XCTAssertFalse(policy.isDue(at: now.addingTimeInterval(1), isActive: true, enabled: true))
        }
    }

    func testProviderCooldownIsBoundedAndSuccessClearsIt() {
        var policy = BetaAllowlistSyncPolicy()
        policy.recordFailure(at: now, retryAfterSeconds: 1_000_000)
        XCTAssertEqual(policy.cooldownUntil, now.addingTimeInterval(86_400))
        policy.recordSuccess(at: now.addingTimeInterval(86_400))
        XCTAssertNil(policy.cooldownUntil)
        XCTAssertEqual(policy.nextCheckAt, now.addingTimeInterval(86_460))
    }

    func testInvalidClockCannotAuthorizeOrCorruptScheduling() {
        var policy = BetaAllowlistSyncPolicy()
        policy.recordSuccess(at: now)
        let saved = policy.nextCheckAt
        policy.recordFailure(at: Date(timeIntervalSince1970: .nan), retryAfterSeconds: 180)
        XCTAssertEqual(policy.nextCheckAt, saved)
        XCTAssertNil(policy.cooldownUntil)
        XCTAssertFalse(policy.isDue(at: Date(timeIntervalSince1970: .infinity), isActive: true, enabled: true))
    }
}
