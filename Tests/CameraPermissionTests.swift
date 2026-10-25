import XCTest
import AVFoundation
@testable import CardShowScanner

@MainActor final class CameraPermissionTests: XCTestCase {
    private func scannerRequest() -> ScannerCameraRequestContext {
        let page = URL(string: "http://127.0.0.1:18764/index.html")!
        return ScannerCameraRequestContext(active: true, scheme: "http", host: "127.0.0.1", port: 18764,
            mainFrame: true, cameraOnly: true, documentURL: page, expectedPageURL: page)
    }

    func testOnlyTheActiveBundledScannerMainFrameCanCaptureVideo() async {
        let valid = scannerRequest()
        XCTAssertTrue(valid.isTrusted)
        var context = valid; context.active = false; XCTAssertFalse(context.isTrusted)
        context = valid; context.mainFrame = false; XCTAssertFalse(context.isTrusted)
        context = valid; context.cameraOnly = false; XCTAssertFalse(context.isTrusted, "Microphone and combined requests are denied")
        context = valid; context.scheme = "https"; XCTAssertFalse(context.isTrusted)
        context = valid; context.host = "tcgtracking.com"; XCTAssertFalse(context.isTrusted)
        context = valid; context.host = "localhost"; XCTAssertFalse(context.isTrusted)
        context = valid; context.port = 18765; XCTAssertFalse(context.isTrusted)
        for page in [nil, "http://127.0.0.1:18765/index.html", "http://127.0.0.1:18764/other.html",
                     "http://127.0.0.1:18764/index.html?source=other", "http://user:secret@127.0.0.1:18764/index.html",
                     "https://tcgtracking.com/newscanplus/quick"] {
            context = valid; context.documentURL = page.flatMap(URL.init(string:))
            XCTAssertFalse(context.isTrusted)
        }
    }

    func testNativeAuthorizationStatusesNeverRequestASecondSitePrompt() async {
        XCTAssertEqual(ScannerCameraPermissionAction.action(for: .authorized), .grant)
        XCTAssertEqual(ScannerCameraPermissionAction.action(for: .notDetermined), .requestNativeAccess)
        XCTAssertEqual(ScannerCameraPermissionAction.action(for: .denied), .deny)
        XCTAssertEqual(ScannerCameraPermissionAction.action(for: .restricted), .deny)
    }

    func testPreviouslyAuthorizedAccessIsReusedAndRevocationIsRechecked() async {
        var nativeStatus = AVAuthorizationStatus.authorized
        var requests = 0
        let coordinator = ScannerCameraAuthorizationCoordinator(readStatus: { nativeStatus }, requestAccess: {
            requests += 1; return false
        })
        let first = await coordinator.authorize(), reopened = await coordinator.authorize()
        XCTAssertTrue(first); XCTAssertTrue(reopened); XCTAssertEqual(requests, 0)
        nativeStatus = .denied
        let revoked = await coordinator.authorize()
        XCTAssertFalse(revoked); XCTAssertEqual(requests, 0)
    }

    func testDeniedAndRestrictedAccessNeverInvokeTheNativeRequest() async {
        for status in [AVAuthorizationStatus.denied, .restricted] {
            var requests = 0
            let coordinator = ScannerCameraAuthorizationCoordinator(readStatus: { status }, requestAccess: {
                requests += 1; return true
            })
            let granted = await coordinator.authorize()
            XCTAssertFalse(granted); XCTAssertEqual(requests, 0)
        }
    }

    func testConcurrentFirstRequestsShareOneNativeAuthorizationPrompt() async {
        var status = AVAuthorizationStatus.notDetermined
        var reads = 0, requests = 0
        var completion: CheckedContinuation<Bool, Never>?
        let coordinator = ScannerCameraAuthorizationCoordinator(readStatus: { reads += 1; return status }, requestAccess: {
            requests += 1
            return await withCheckedContinuation { completion = $0 }
        })
        let first = Task { @MainActor in await coordinator.authorize() }
        await waitUntil { completion != nil }
        let second = Task { @MainActor in await coordinator.authorize() }
        await waitUntil { reads >= 2 }
        XCTAssertEqual(requests, 1, "A second scanner must join the pending native prompt")
        guard let response = completion else { first.cancel(); second.cancel(); return }
        status = .authorized; completion = nil; response.resume(returning: true)
        let firstGranted = await first.value, secondGranted = await second.value
        XCTAssertTrue(firstGranted); XCTAssertTrue(secondGranted)
        let reopened = await coordinator.authorize()
        XCTAssertTrue(reopened); XCTAssertEqual(requests, 1)
    }

    func testNativeDenialIsRetainedByTheSystemWithoutRepeatedRequests() async {
        var status = AVAuthorizationStatus.notDetermined
        var requests = 0
        let coordinator = ScannerCameraAuthorizationCoordinator(readStatus: { status }, requestAccess: {
            requests += 1; status = .denied; return false
        })
        let denied = await coordinator.authorize(), reopened = await coordinator.authorize()
        XCTAssertFalse(denied); XCTAssertFalse(reopened); XCTAssertEqual(requests, 1)
    }

    func testAnOldGrantedCallbackCannotOverrideCurrentSystemDenial() async {
        var status = AVAuthorizationStatus.notDetermined
        let coordinator = ScannerCameraAuthorizationCoordinator(readStatus: { status }, requestAccess: {
            status = .denied
            return true
        })
        let granted = await coordinator.authorize()
        XCTAssertFalse(granted)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The controlled native permission request did not start")
    }
}
