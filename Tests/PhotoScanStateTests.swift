import XCTest
@testable import CardShowScanner

final class PhotoScanStateTests: XCTestCase {
    private func wire(_ state: Any, kind: String = "photoState") throws -> TCGBridgeEnvelope {
        try JSONDecoder().decode(TCGBridgeEnvelope.self, from: JSONSerialization.data(withJSONObject: [
            "nonce": "photo-test", "kind": kind, "photoState": state,
            "message": "PRIVATE_CARD_NAME", "capturedImageBase64": "PRIVATE_IMAGE"
        ]))
    }

    func testPhotoStateDecodesOnlyTypedScalarStatesFromItsOwnChannel() throws {
        for state in PhotoScanState.allCases {
            let envelope = try wire(state.rawValue)
            XCTAssertEqual(PhotoScanState.validated(envelope), state)
            XCTAssertNil(ScannerDiagnosticRecord.validated(envelope), "Photo UI messages cannot become arbitrary log fields")
            XCTAssertNil(PhotoScanState.validated(try wire(state.rawValue, kind: "status")))
            XCTAssertNil(PhotoScanState.validated(try wire(state.rawValue, kind: "scan")))
        }
        for invalid in ["PRIVATE_CARD", "capturing", "READY", "", " ready "] {
            XCTAssertNil(PhotoScanState.validated(try wire(invalid)))
        }
        XCTAssertThrowsError(try wire(7))
        XCTAssertThrowsError(try wire(["state": "ready"]))
    }

    func testCaptureRequiresAcknowledgedFramingAndRetakeRequiresACompletedOrFailedPhoto() {
        for state in PhotoScanState.allCases {
            XCTAssertEqual(allowed(state), state == .framing)
            XCTAssertEqual(allowed(state, retake: true), [.ready, .noMatch, .failed].contains(state))
        }
        XCTAssertFalse(allowed(.framing, mode: .live))
        XCTAssertFalse(allowed(.ready, retake: true, mode: .live))
    }

    func testInactiveManualBackgroundCriticalAndUnreadyDocumentEachBlockPhotoCommands() {
        for retake in [false, true] {
            let state: PhotoScanState = retake ? .ready : .framing
            XCTAssertTrue(allowed(state, retake: retake))
            XCTAssertFalse(allowed(state, retake: retake, active: false))
            XCTAssertFalse(allowed(state, retake: retake, foreground: false))
            XCTAssertFalse(allowed(state, retake: retake, manual: true))
            XCTAssertFalse(allowed(state, retake: retake, cooling: true))
            XCTAssertFalse(allowed(state, retake: retake, documentReady: false))
        }
    }

    private func allowed(_ state: PhotoScanState, retake: Bool = false, mode: ScannerCaptureMode = .photo,
                         active: Bool = true, foreground: Bool = true, manual: Bool = false,
                         cooling: Bool = false, documentReady: Bool = true) -> Bool {
        ScannerPhotoCommandPolicy.allows(mode: mode, state: state, retake: retake,
            active: active, foreground: foreground, manual: manual, cooling: cooling, documentReady: documentReady)
    }
}

@MainActor final class PhotoScanProviderPreferenceTests: XCTestCase {
    func testModeSelectionSurvivesProviderStopWithoutMakingAnUnreadyShutterAvailable() {
        let provider = TCGTrackingScannerProvider()
        XCTAssertEqual(provider.captureMode, .live); XCTAssertEqual(provider.photoState, .off)
        XCTAssertTrue(provider.setCaptureMode(.photo))
        XCTAssertEqual(provider.captureMode, .photo); XCTAssertEqual(provider.photoState, .off)
        XCTAssertFalse(provider.canCapturePhoto); XCTAssertFalse(provider.canRetakePhoto)
        provider.capturePhoto(); provider.retakePhoto()
        XCTAssertEqual(provider.photoState, .off, "Commands cannot run before a trusted ready document and framing acknowledgement")
        provider.stop()
        XCTAssertEqual(provider.captureMode, .photo)
        XCTAssertFalse(provider.canCapturePhoto); XCTAssertFalse(provider.canRetakePhoto)
        XCTAssertTrue(provider.setCaptureMode(.live))
        XCTAssertEqual(provider.captureMode, .live); XCTAssertEqual(provider.photoState, .off)
    }
}
