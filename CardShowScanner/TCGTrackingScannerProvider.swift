import Foundation
import WebKit
import SwiftUI
import AVFoundation

/// Versioned app-owned wire format. Raw website payloads never enter persistence.
struct TCGBridgeEnvelope: Decodable {
    var nonce: String
    var kind: String
    var same: Bool?
    var accepted: Bool?
    var confidence: Double?
    var candidates: [TCGBridgeCandidate]?
    var message: String?
    var capturedImageBase64: String?
    var event: String?
    var stage: String?
    var errorKind: String?
    var backend: String?
    var elapsedMS: Double?
    var scanMS: Double?
    var captureMS: Double?
    var frames: Int?
    var downloadedBytes: Double?
    var cachedShards: Int?
    var cacheBackend: String?
    var cacheState: String?
    var cacheSource: String?
    var storagePersisted: Bool?
    var solid: Bool?
    var tracked: Bool?
    var borderRetry: Bool?
    var borderRetained: Bool?
    var scanStage: String?
    var rawQuads: Double?
    var rejectedQuads: Double?
    var candidateQuads: Double?
    var selectedBase: Double?
    var quadSource: String?
    var quadAspect: Double?
    var quadArea: Double?
    var quadSupport: Double?
    var meanLuma: Double?
    var lumaStd: Double?
    var matchDistance: Double?
    var matchGap: Double?
    var issueReason: String?
    var sampleAgeMS: Double?
    var resourceMode: String?
    var captureState: String?
    var targetFPS: Double?
    var cameraFPS: Double?
    var processingActive: Bool?
    var constraintState: String?
    var photoState: String?
    var deliveryState: String?
    var windowMS: Double?
    var cameraOnMS: Double?
    var deliveredFrames: Double?
    var frameWindowMS: Double?
    var deliveredFPS: Double?
    var captureMode: String?
}

enum ScannerCaptureMode: String, CaseIterable, Sendable {
    case live, photo
    var title: String { self == .live ? "Live Scan" : "Photo Scan" }
}

enum PhotoScanState: String, CaseIterable, Sendable {
    case off, framing, processing, ready, noMatch, failed, cooling

    static func validated(_ envelope: TCGBridgeEnvelope) -> Self? {
        guard envelope.kind == "photoState", let value = envelope.photoState else { return nil }
        return Self(rawValue: value)
    }

    var isResting: Bool { self == .ready || self == .noMatch || self == .failed }
}

/// Shutter readiness requires a bridge acknowledgement, not just a UI selection.
enum ScannerPhotoCommandPolicy {
    static func allows(mode: ScannerCaptureMode, state: PhotoScanState, retake: Bool,
                       active: Bool, foreground: Bool, manual: Bool,
                       cooling: Bool, documentReady: Bool) -> Bool {
        mode == .photo && active && foreground && !manual && !cooling && documentReady
            && (retake ? state.isResting : state == .framing)
    }
}

enum ScannerTextRecognitionPolicy {
    static func allows(enabled: Bool, busy: Bool, mode: ScannerCaptureMode, photoState: PhotoScanState,
                       active: Bool, foreground: Bool, manual: Bool, cooling: Bool,
                       documentReady: Bool, reviewing: Bool) -> Bool {
        enabled && !busy && active && foreground && !manual && !cooling && documentReady && !reviewing
            && (mode == .live || photoState == .noMatch)
    }
}

/// Diagnostics have their own strict scalar schema. Neither recognition payloads
/// nor arbitrary webpage strings become diagnostic fields.
struct ScannerDiagnosticRecord {
    var event: String
    var fields: [String: String]
    var sampleEvery: TimeInterval

    static func validated(_ message: TCGBridgeEnvelope) -> Self? {
        let allowed: Set<String> = ["bridge_ready", "bridge_stopped", "startup_started", "modules_ready", "index_ready", "pack_ready", "pack_cache_warning",
            "backend_ready", "camera_requested", "camera_acquired", "video_playing", "scanner_ready", "startup_failed",
            "scan_stats", "border_retry", "recognition_snapshot", "scan_issue", "recognition_settled", "camera_interrupted", "camera_backgrounded", "camera_workload", "camera_delivery", "javascript_error", "javascript_rejection"]
        guard message.kind == "diagnostic", let event = message.event, allowed.contains(event) else { return nil }
        if event == "camera_delivery" {
            return Self(event: "web.camera_delivery", fields: cameraDeliveryFields(message), sampleEvery: 0)
        }
        var fields: [String: String] = [:]
        if event == "camera_workload" {
            for (key, value, allowed) in [
                ("resource_mode", message.resourceMode, ["normal", "reduced", "cooling"]),
                ("capture_state", message.captureState, ["live", "review", "manual", "prompt", "stopped"]),
                ("constraint_state", message.constraintState, ["pending", "applied", "unsupported", "failed", "inactive"])
            ] {
                if let value, allowed.contains(value) { fields[key] = value }
            }
            if let fps = message.targetFPS, [0.0, 1, 10, 30].contains(fps) { fields["target_fps"] = String(Int(fps)) }
            if let fps = message.cameraFPS, fps.isFinite, (0...240).contains(fps) {
                fields["camera_fps"] = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), fps)
            }
            if let active = message.processingActive { fields["processing_active"] = String(active) }
        }
        if let stage = message.stage, ["modules", "index", "pack", "backend", "camera", "video", "scan"].contains(stage) { fields["stage"] = stage }
        if let backend = message.backend, ["worker", "main"].contains(backend) { fields["backend"] = backend }
        if let kind = message.errorKind, ["NotAllowedError", "NotFoundError", "NotReadableError", "AbortError", "SecurityError", "TypeError", "RangeError", "Error"].contains(kind) { fields["reason"] = kind }
        for (key, value) in [("elapsed_ms", message.elapsedMS), ("scan_ms", message.scanMS), ("capture_ms", message.captureMS)] {
            if let value, value.isFinite, (0...86400000).contains(value) { fields[key] = String(Int(value)) }
        }
        if let bytes = message.downloadedBytes, bytes.isFinite, (0...10_000_000_000).contains(bytes) { fields["downloaded_bytes"] = String(Int64(bytes)) }
        if let shards = message.cachedShards, (0...1_000_000).contains(shards) { fields["cached_shards"] = String(shards) }
        if let backend = message.cacheBackend, ["native", "indexeddb", "unknown"].contains(backend) { fields["cache_backend"] = backend }
        if let state = message.cacheState, ["ok", "failed", "unavailable", "unknown"].contains(state) { fields["cache"] = state }
        if let source = message.cacheSource, ["cache", "download", "mixed", "unknown"].contains(source) { fields["source"] = source }
        if let persisted = message.storagePersisted { fields["persisted"] = String(persisted) }
        if let frames = message.frames, (0...1000000).contains(frames) { fields["frames"] = String(frames) }
        if event == "scan_issue" {
            if let reason = message.issueReason, ["top_loader", "dark_card", "wrong_border"].contains(reason) { fields["reason"] = reason }
        }
        if event == "scan_issue" || event == "recognition_snapshot" {
            if let age = message.sampleAgeMS, age.isFinite, (0...600_000).contains(age), age.rounded(.towardZero) == age { fields["sample_age_ms"] = String(Int(age)) }
        }
        let freshIssueSnapshot = message.sampleAgeMS.map { $0.isFinite && (0...15_000).contains($0) && $0.rounded(.towardZero) == $0 } ?? false
        if event == "scan_stats" || event == "border_retry" || event == "recognition_snapshot" || (event == "scan_issue" && freshIssueSnapshot) {
            if let solid = message.solid { fields["solid"] = String(solid) }
            if let tracked = message.tracked { fields["tracked"] = String(tracked) }
            if let retry = message.borderRetry { fields["border_retry"] = String(retry) }
            if let retained = message.borderRetained { fields["border_retained"] = String(retained) }
            if let stage = message.scanStage, ["none", "one", "quick", "full"].contains(stage) { fields["scan_stage"] = stage }
            if let source = message.quadSource, ["none", "detected", "selected"].contains(source) { fields["quad_source"] = source }
            for (key, value) in [("raw_quads", message.rawQuads), ("rejected_quads", message.rejectedQuads),
                                 ("candidate_quads", message.candidateQuads), ("selected_base", message.selectedBase)] {
                if let value, value.isFinite, (0...1_000_000).contains(value), value.rounded(.towardZero) == value { fields[key] = String(Int(value)) }
            }
            for (key, value, maximum) in [("quad_aspect", message.quadAspect, 1.0), ("quad_area", message.quadArea, 1.0),
                ("quad_support", message.quadSupport, 1.0), ("mean_luma", message.meanLuma, 255.0), ("luma_std", message.lumaStd, 128.0),
                ("match_distance", message.matchDistance, 100.0), ("match_gap", message.matchGap, 100.0)] {
                if let value, value.isFinite, (0...maximum).contains(value) {
                    fields[key] = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
                }
            }
        }
        return Self(event: "web." + event, fields: fields, sampleEvery: event == "scan_stats" ? 5 : event == "border_retry" ? 1 : 0)
    }

    /// RVFC counters describe video frames delivered for presentation. They do
    /// not measure display refresh, recognition throughput or whole-device CPU.
    /// The bridge aggregates while a camera stream is visible and flushes once
    /// on retirement; terminal windows must not be sampled away at storage.
    private static func cameraDeliveryFields(_ message: TCGBridgeEnvelope) -> [String: String] {
        guard let state = message.deliveryState, ["measured", "pending", "unavailable"].contains(state) else { return [:] }
        var fields = ["delivery_state": state]
        if let mode = message.captureMode, ScannerCaptureMode(rawValue: mode) != nil { fields["capture_mode"] = mode }
        // Without a monotonic browser clock, report unavailability rather than
        // inventing zero duration or using a wall-clock fallback.
        if state == "unavailable", message.windowMS == nil, message.cameraOnMS == nil { return fields }
        guard let window = message.windowMS, window.isFinite, (0...86_400_000).contains(window),
              let cameraOn = message.cameraOnMS, cameraOn.isFinite, (0...window).contains(cameraOn) else { return [:] }
        fields["delivery_window_ms"] = String(Int(window)); fields["camera_on_ms"] = String(Int(cameraOn))
        guard state == "measured" else { return fields }
        guard let frames = message.deliveredFrames, frames.isFinite, (0...1_000_000).contains(frames),
              frames.rounded(.towardZero) == frames,
              let frameWindow = message.frameWindowMS, frameWindow.isFinite, (1...86_400_000).contains(frameWindow),
              let fps = message.deliveredFPS, fps.isFinite, (0...240).contains(fps) else { return [:] }
        fields["delivered_frames"] = String(Int(frames))
        fields["frame_window_ms"] = String(Int(frameWindow))
        fields["delivered_fps"] = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), fps)
        return fields
    }
}

struct TCGBridgeCandidate: Decodable {
    var ref: String
    var name: String
    var number: String
    var set: String
    var imageURL: String?
    var confidence: Double
    var printing: String
    var skuID: String?
    var marketPrice: Decimal?
    var printings: [CardPrinting]
    var requiresPrintingSelection: Bool

    func normalized(game: String) throws -> CardCandidate {
        guard ref.range(of: #"^(p|t|ts|u):[0-9]{1,12}$"#, options: .regularExpression) != nil,
              !name.isEmpty, name.count <= 1000, number.count <= 1000, set.count <= 1000,
              !printing.isEmpty, printing.count <= 1000, printings.count <= 30,
              confidence.isFinite, (0...100).contains(confidence),
              marketPrice.map({ $0 >= 0 && !$0.isNaN }) ?? true,
              printings.allSatisfy({ !$0.label.isEmpty && $0.label.count <= 1000 && ($0.marketPrice.map { $0 >= 0 && !$0.isNaN } ?? true) }) else {
            throw BridgeFailure.invalidPayload
        }
        func validSKU(_ value: String?) -> Bool {
            value.map { $0.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil } ?? true
        }
        guard validSKU(skuID), printings.allSatisfy({ validSKU($0.skuID) }) else { throw BridgeFailure.invalidPayload }
        let image = imageURL.flatMap(URL.init(string:))
        guard imageURL == nil || (image?.scheme == "https" && image?.host != nil && image?.user == nil && image?.password == nil) else {
            throw BridgeFailure.invalidPayload
        }
        return CardCandidate(identity: CardIdentity(game: game, productID: ref, skuID: skuID, printing: printing,
            language: TCGGameRegistry.defaultLanguage(for: game)),
            name: name, set: set, number: number, marketPrice: marketPrice, imageURL: image,
            confidence: confidence, printings: Array(Set(printings.map(\.label))).sorted(),
            printingQuotes: printings, requiresPrintingSelection: requiresPrintingSelection)
    }
}

enum BridgeFailure: LocalizedError {
    case invalidPayload
    var errorDescription: String? { "The scanner returned an invalid or unsupported result. Retry scanning." }
}

struct TCGBridgeNormalizer {
    private var current: ScanResult?
    mutating func receive(_ envelope: TCGBridgeEnvelope, game: String) throws -> ScanResult? {
        if envelope.kind == "hide" {
            current = nil
            return ScanResult(id: UUID(), candidates: [], accepted: false, same: true, visible: false)
        }
        guard envelope.kind == "scan" else { return nil }
        guard let same = envelope.same, let accepted = envelope.accepted,
              let confidence = envelope.confidence, confidence.isFinite, (0...100).contains(confidence) else {
            throw BridgeFailure.invalidPayload
        }
        if same {
            guard var result = current else { return nil }
            result.same = true; result.accepted = accepted
            result.candidates[0].confidence = confidence
            current = result; return result
        }
        guard let candidates = envelope.candidates, !candidates.isEmpty, candidates.count <= 5 else { throw BridgeFailure.invalidPayload }
        let normalized = try candidates.map { try $0.normalized(game: game) }
        guard Set(normalized.map { $0.identity.productID }).count == normalized.count else { throw BridgeFailure.invalidPayload }
        // An ambiguous result becoming accepted is not a second physical card.
        let episode: UUID
        if let current, current.candidates.first?.identity.productID == normalized.first?.identity.productID || (!current.accepted && accepted) {
            episode = current.id
        } else { episode = UUID() }
        var result = ScanResult(id: episode, candidates: normalized, accepted: accepted, same: false)
        if let encoded = envelope.capturedImageBase64, encoded.count <= 1_000_000 {
            result.capturedImageData = Data(base64Encoded: encoded)
        }
        result.candidates[0].confidence = confidence
        current = result; return result
    }
}

/// WebKit permission applies only to this active scanner document, never the
/// account/pricing website, subframes, or requests for audio.
struct ScannerCameraRequestContext {
    var active: Bool
    var scheme: String
    var host: String
    var port: Int
    var mainFrame: Bool
    var cameraOnly: Bool
    var documentURL: URL?
    var expectedPageURL: URL

    var isTrusted: Bool {
        guard active, mainFrame, cameraOnly,
              expectedPageURL.scheme == "http", expectedPageURL.host == "127.0.0.1",
              let expectedPort = expectedPageURL.port,
              expectedPageURL.path == "/index.html", expectedPageURL.query == nil,
              expectedPageURL.user == nil, expectedPageURL.password == nil,
              scheme == "http", host == "127.0.0.1", port == expectedPort,
              let documentURL else { return false }
        return documentURL.scheme == "http" && documentURL.host == "127.0.0.1" &&
            documentURL.port == expectedPort && documentURL.path == "/index.html" &&
            documentURL.query == nil && documentURL.user == nil && documentURL.password == nil
    }
}

enum ScannerCameraPermissionAction: Equatable {
    case grant, requestNativeAccess, deny

    static func action(for status: AVAuthorizationStatus) -> Self {
        switch status {
        case .authorized: return .grant
        case .notDetermined: return .requestNativeAccess
        case .denied, .restricted: return .deny
        @unknown default: return .deny
        }
    }
}

/// Native iOS authorization is the source of truth. Sharing only an in-flight
/// request prevents two scanner instances from creating separate prompt flows.
@MainActor final class ScannerCameraAuthorizationCoordinator {
    static let shared = ScannerCameraAuthorizationCoordinator(
        readStatus: { AVCaptureDevice.authorizationStatus(for: .video) },
        requestAccess: {
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in continuation.resume(returning: granted) }
            }
        })
    private let readStatus: @MainActor () -> AVAuthorizationStatus
    private let requestAccess: @MainActor () async -> Bool
    private var inFlight: Task<Bool, Never>?
    private var requestID = UUID()

    init(readStatus: @escaping @MainActor () -> AVAuthorizationStatus,
         requestAccess: @escaping @MainActor () async -> Bool) {
        self.readStatus = readStatus; self.requestAccess = requestAccess
    }
    var authorizationStatus: AVAuthorizationStatus { readStatus() }

    func authorize() async -> Bool {
        switch ScannerCameraPermissionAction.action(for: readStatus()) {
        case .grant: return true
        case .deny: return false
        case .requestNativeAccess:
            if let inFlight {
                let granted = await inFlight.value
                return granted && readStatus() == .authorized
            }
            let id = UUID(); requestID = id
            let request = requestAccess
            let task = Task { @MainActor in await request() }
            inFlight = task
            let granted = await task.value
            if requestID == id { inFlight = nil }
            // Recheck in case access was revoked while the request completed.
            return granted && readStatus() == .authorized
        }
    }
}

/// Experimental module adapter, based on the user's supplied sources and permission.
/// Does not claim an official TCGTracking API contract.
enum ScannerIssueKind: String, CaseIterable {
    case topLoader = "top_loader"
    case darkCard = "dark_card"
    case wrongBorder = "wrong_border"
    var label: String {
        switch self {
        case .topLoader: return "Top Loader Not Recognized"
        case .darkCard: return "Dark Card Not Recognized"
        case .wrongBorder: return "Wrong Border or Match"
        }
    }
}

struct ScannerPageRecoveryPolicy {
    static func allowsRetry(error: Error, attempts: Int) -> Bool {
        let failure = error as NSError
        return attempts == 0 && failure.domain == NSURLErrorDomain &&
            [URLError.cannotConnectToHost.rawValue, URLError.networkConnectionLost.rawValue, URLError.timedOut.rawValue].contains(failure.code)
    }
}

/// A saved frozen review can finish pricing before its restarted page is ready.
/// Deliver its removal-wait transition once, when that page can handle it.
struct ScannerReviewReleaseQueue {
    private var ready = false
    private var pending: String?
    mutating func request(_ ref: String) -> String? {
        if ready { return ref }
        pending = ref; return nil
    }
    mutating func becameReady() -> String? {
        ready = true
        defer { pending = nil }
        return pending
    }
    mutating func restart() { ready = false; pending = nil }
    mutating func loading() { ready = false }
    mutating func discardPending() { pending = nil }
}

enum ScannerResourceMode: String, Equatable {
    case normal, reduced, cooling

    static func policy(for state: DeviceResourceState) -> Self {
        // Apple recommends reducing demand at serious heat and, if possible,
        // stopping camera use at critical heat. These are OS-reported bands,
        // not an app-defined temperature or an OS-wide app-block threshold.
        switch state.thermal {
        case .critical: return .cooling
        case .fair, .serious: return .reduced
        case .nominal, .unknown: return state.lowPowerMode ? .reduced : .normal
        }
    }
}

@MainActor final class TCGTrackingScannerProvider: NSObject, ObservableObject, ScannerProvider, WKNavigationDelegate, WKUIDelegate {
    let label = "LIVE CAMERA • On-device recognition"
    private(set) var results: AsyncStream<ScanResult>
    private var continuation: AsyncStream<ScanResult>.Continuation
    let webView: WKWebView
    @Published private(set) var status = "Preparing TCGTracking…"
    @Published private(set) var downloadPreviewState: ScannerDownloadGateState = .idle
    @Published private(set) var manualSearchSuggested = false
    @Published private(set) var captureMode = ScannerCaptureMode.live
    @Published private(set) var photoState = PhotoScanState.off
    @Published private(set) var textRecognitionEnabled = false
    @Published private(set) var textRecognitionBusy = false
    @Published private(set) var textRecognitionMessage: String?
    private let textRecognizer: any ScannerTextRecognizing
    private let textCatalog: ScannerTextCatalogMatcher
    private var textTask: Task<Void, Never>?
    private var textDeadline: Task<Void, Never>?
    private var textRequestID = UUID()
    private var photoTextAttempted = false
    private var recognitionReviewHeld = false
    private var active = false
    private var manualSearchSuspended = false
    private var documentFailed = false
    private var bridgeInstalled = false
    private var resourceMode = ScannerResourceMode.normal
    private var resourceForeground = true
    private var deliveryDiagnosticsEnabled = true
    private var resourceObservers: [NSObjectProtocol] = []
    private var resourceRequestID = UUID()
    private var resourcePauseDeadline: Task<Void, Never>?
    private var photoCommandID = UUID()
    private var photoCommandDeadline: Task<Void, Never>?
    private var photoAwaitingRetake = false
    private var photoRestingState = PhotoScanState.failed
    private var game = "Pokémon"
    private var nonce = UUID().uuidString
    private var normalizer = TCGBridgeNormalizer()
    private var pageTask: Task<Void, Never>?
    private lazy var downloadGate = ScannerDownloadGate(stateChanged: { [weak self] state in
        self?.downloadPreviewState = state
    })
    private var downloadRefreshSuspended = false
    private var downloadRefreshStatus: String?
    private var preparedDownloadAction: ScannerDownloadGateAction?
    private var pageNavigation: WKNavigation?
    private var recoveryAttempts = 0
    private var reviewRelease = ScannerReviewReleaseQueue()
    private var databaseLease: UUID?
    static let pageURL = LocalScannerServer.pageURL
    private var messageProxy: WeakScanMessageHandler?
    private static let deniedCameraStatus = "Camera access is off. Enable Camera in iPhone Settings → Card Show Scanner, then tap Retry Live Scanner."
    private static let coolingStatus = "Cooling down… Scanning resumes when your iPhone is ready."

    init(textRecognizer: any ScannerTextRecognizing = ScannerTextRecognizer(),
         textCatalog: any CardCatalogSearching = CachedCardCatalog.shared) {
        self.textRecognizer = textRecognizer
        self.textCatalog = ScannerTextCatalogMatcher(catalog: textCatalog)
        let stream = AsyncStream<ScanResult>.makeStream(bufferingPolicy: .bufferingNewest(1))
        results = stream.stream; continuation = stream.continuation
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        let proxy = WeakScanMessageHandler(owner: self); messageProxy = proxy
        config.userContentController.add(proxy, name: "scanResult")
        webView.navigationDelegate = self; webView.uiDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
        // SwiftUI extends the preview beneath the safe areas. WebKit must use
        // that same rectangle instead of adding its own top/bottom white inset.
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.underPageBackgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.isScrollEnabled = false
    }
    deinit {
        textTask?.cancel(); textDeadline?.cancel()
        resourcePauseDeadline?.cancel()
        photoCommandDeadline?.cancel()
        for observer in resourceObservers { NotificationCenter.default.removeObserver(observer) }
    }
    func start(game: String) {
        stop()
        guard TCGGameRegistry.scannerKey(for: game) != nil else {
            status = "This game has no supported scanner configuration. Choose another game."
            return
        }
        databaseLease = ScannerDatabaseUpdater.shared.beginScannerUse()
        let stream = AsyncStream<ScanResult>.makeStream(bufferingPolicy: .bufferingNewest(1))
        results = stream.stream; continuation = stream.continuation
        let diagnosticGame: String
        switch TCGGameRegistry.scannerKey(for: game) {
        case "tcgp:3": diagnosticGame = "pokemon"
        case "tcgp:1": diagnosticGame = "magic"
        case "tcgp:2": diagnosticGame = "yugioh"
        default: diagnosticGame = TCGGameRegistry.categoryID(for: game).map { "tcgp_\($0)" } ?? "unsupported"
        }
        DiagnosticLog.shared.record("web.load_started", ["game": diagnosticGame])
        self.game = game; active = true; manualSearchSuspended = false; documentFailed = false; nonce = UUID().uuidString; normalizer = TCGBridgeNormalizer()
        observeResources()
        updatePhotoState(captureMode == .photo && resourceMode == .cooling ? .cooling : .off)
        recoveryAttempts = 0
        status = resourceMode == .cooling ? Self.coolingStatus : "Checking database download size…"
        beginDownloadPreview(action: .initialLoad)
    }
    private func loadBundledPage(restartingServer: Bool) {
        bridgeInstalled = false
        reviewRelease.loading()
        pageTask?.cancel()
        let startupNonce = nonce
        pageTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                if restartingServer { try await LocalScannerServer.shared.restart() }
                try await LocalScannerServer.shared.ensureReachable()
                guard let self, self.active, self.nonce == startupNonce, !Task.isCancelled else { return }
                self.pageNavigation = self.webView.load(URLRequest(url: Self.pageURL))
                if self.pageNavigation == nil { self.documentFailed = true; self.photoDocumentFailed(); self.status = "Scanner could not open. Tap Retry Live Scanner." }
            } catch {
                guard let self, self.active, self.nonce == startupNonce, !Task.isCancelled else { return }
                DiagnosticLog.shared.failure("scanner.local_start_failed", error)
                self.documentFailed = true
                self.photoDocumentFailed()
                self.status = "Local scanner could not start. Tap Retry Live Scanner."
            }
        }
    }
    func stop() {
        if active { DiagnosticLog.shared.record("web.stopped") }
        downloadGate.cancel()
        downloadRefreshSuspended = false; downloadRefreshStatus = nil
        preparedDownloadAction = nil
        invalidateTextRecognition()
        photoTextAttempted = false; recognitionReviewHeld = false; textRecognitionMessage = nil
        active = false; manualSearchSuspended = false; bridgeInstalled = false; nonce = UUID().uuidString; manualSearchSuggested = false
        for observer in resourceObservers { NotificationCenter.default.removeObserver(observer) }
        resourceObservers.removeAll()
        resourceRequestID = UUID(); resourcePauseDeadline?.cancel(); resourcePauseDeadline = nil
        invalidatePhotoCommand()
        updatePhotoState(.off)
        reviewRelease.restart()
        pageTask?.cancel(); pageTask = nil; pageNavigation = nil
        continuation.finish()
        webView.evaluateJavaScript("window.CardShowBridge?.stop()", completionHandler: nil)
        webView.stopLoading()
        normalizer = TCGBridgeNormalizer()
        if let databaseLease {
            ScannerDatabaseUpdater.shared.endScannerUse(databaseLease)
            self.databaseLease = nil
        }
    }
    private func observeResources() {
        resourceMode = ScannerResourceMode.policy(for: .current())
        resourceForeground = UIApplication.shared.applicationState == .active
        deliveryDiagnosticsEnabled = DiagnosticLog.shared.enabled
        let requestNonce = nonce
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange,
                     UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            resourceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.active, self.nonce == requestNonce else { return }
                    let mode = ScannerResourceMode.policy(for: .current())
                    let foreground = name == UIApplication.willResignActiveNotification ? false
                        : name == UIApplication.didBecomeActiveNotification ? true : self.resourceForeground
                    guard mode != self.resourceMode || foreground != self.resourceForeground else { return }
                    self.resourceMode = mode; self.resourceForeground = foreground
                    if mode == .cooling || !foreground {
                        self.invalidateTextRecognition()
                        self.invalidatePhotoCommand()
                        self.updatePhotoState(self.captureMode == .photo && mode == .cooling ? .cooling : .off)
                    }
                    if mode == .cooling {
                        self.reviewRelease.loading()
                        self.status = Self.coolingStatus
                    }
                    self.dispatchResourceMode()
                    if foreground { self.continuePreparedDownload() }
                }
            })
        }
        resourceObservers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.active, self.nonce == requestNonce else { return }
                    let enabled = DiagnosticLog.shared.enabled
                    guard enabled != self.deliveryDiagnosticsEnabled else { return }
                    self.deliveryDiagnosticsEnabled = enabled
                    self.dispatchDeliveryDiagnostics()
                }
            })
    }
    private func dispatchDeliveryDiagnostics() {
        guard active, bridgeInstalled, !documentFailed, Self.allowed(webView.url) else { return }
        // Optional measurement must not restart, pause or retire the scanner.
        // The bridge rejects an old nonce and starts a fresh window on enable.
        webView.callAsyncJavaScript("return window.CardShowBridge?.setDeliveryDiagnostics(enabled, expectedNonce);",
            arguments: ["enabled": deliveryDiagnosticsEnabled, "expectedNonce": nonce], in: nil, in: .page) { _ in }
    }
    private func dispatchResourceMode() {
        guard active, !documentFailed else { return }
        // Metadata-only checks have no camera document to acknowledge a pause.
        // A warm cached result may also be waiting for foreground before load.
        guard downloadPreviewState.action != .initialLoad, preparedDownloadAction != .initialLoad else { return }
        let requestNonce = nonce
        let requestID = UUID(); resourceRequestID = requestID
        if (resourceMode == .cooling || !resourceForeground), resourcePauseDeadline == nil {
            resourcePauseDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.active, self.nonce == requestNonce, !Task.isCancelled else { return }
                self.retireFailedResourceUpdate()
            }
        }
        guard bridgeInstalled else { return }
        webView.callAsyncJavaScript("return window.CardShowBridge?.setResourceMode(mode, expectedNonce, foreground);",
            arguments: ["mode": resourceMode.rawValue, "expectedNonce": requestNonce, "foreground": resourceForeground], in: nil, in: .page) { [weak self] result in
                guard let self, self.active, self.nonce == requestNonce, self.resourceRequestID == requestID else { return }
                guard case .success(let accepted) = result, accepted as? Bool == true else {
                    self.retireFailedResourceUpdate()
                    return
                }
                self.resourcePauseDeadline?.cancel(); self.resourcePauseDeadline = nil
            }
    }
    private func retireFailedResourceUpdate() {
        // A failed or hung JS update must not leave capture working at its old
        // rate. This public WebKit control stops capture independently of JS.
        webView.setCameraCaptureState(.none, completionHandler: nil)
        stop(); documentFailed = true
        photoDocumentFailed()
        status = "Scanner paused. Tap Retry Live Scanner."
    }
    func clearCache() async throws {
        stop()
        try await Self.clearStoredCache()
    }
    static func clearStoredCache() async throws {
        do { try await ScannerDatabaseCache.shared.clear() }
        catch { DiagnosticLog.shared.failure("cache.native_clear_failed", error); throw error }
        let store = WKWebsiteDataStore.default()
        let types: Set<String> = [WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
        let records = await store.dataRecords(ofTypes: types)
        let matching = records.filter { $0.displayName == "127.0.0.1" || $0.displayName == "tcgtracking.com" || $0.displayName.hasSuffix(".tcgtracking.com") }
        await store.removeData(ofTypes: types, for: matching)
        DiagnosticLog.shared.record("cache.cleared", ["records": String(matching.count)])
    }
    private static func allowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "http" && url.host == "127.0.0.1" && url.port == Int(LocalScannerServer.port) &&
            url.path == "/index.html" && url.query == nil && url.user == nil && url.password == nil
    }
    func releaseReview(recognitionRef: String? = nil) {
        recognitionReviewHeld = false
        manualSearchSuggested = false
        // The frozen recognition can outlive a WebKit restart. Pass its identity
        // explicitly so removal waiting never attaches to a later camera guess.
        let validRef = recognitionRef.flatMap { value in
            value.range(of: #"^(p|t|ts|u):[0-9]{1,12}$"#, options: .regularExpression) != nil ? value : nil
        }
        guard let validRef else {
            webView.evaluateJavaScript("window.CardShowBridge?.releaseReview()", completionHandler: nil); return
        }
        guard active, let readyRef = reviewRelease.request(validRef) else { return }
        dispatchReviewRelease(readyRef)
    }
    private func dispatchReviewRelease(_ ref: String) {
        let data = try? JSONEncoder().encode(ref)
        let argument = data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        webView.evaluateJavaScript("window.CardShowBridge?.releaseReview(\(argument))", completionHandler: nil)
    }
    func setSteadyCardBorder(_ enabled: Bool) {
        guard active, Self.allowed(webView.url) else { return }
        DiagnosticLog.shared.record("scanner.steady_border_changed", ["reason": enabled ? "enabled" : "disabled"])
        webView.evaluateJavaScript("window.CardShowBridge?.setSteadyCardBorder(\(enabled ? "true" : "false")); null;", completionHandler: nil)
    }
    var canCapturePhoto: Bool { !textRecognitionBusy && allowsPhotoCommand(retake: false) }
    var canRetakePhoto: Bool { !textRecognitionBusy && allowsPhotoCommand(retake: true) }

    var canReadCardText: Bool {
        ScannerTextRecognitionPolicy.allows(enabled: textRecognitionEnabled, busy: textRecognitionBusy,
            mode: captureMode, photoState: photoState, active: active, foreground: resourceForeground,
            manual: manualSearchSuspended || manualSearchSuggested, cooling: resourceMode == .cooling,
            documentReady: bridgeInstalled && !documentFailed && Self.allowed(webView.url), reviewing: recognitionReviewHeld)
            && (captureMode == .live || !photoTextAttempted)
    }

    func setTextRecognitionEnabled(_ enabled: Bool) {
        guard textRecognitionEnabled != enabled else { return }
        textRecognitionEnabled = enabled
        DiagnosticLog.shared.record("scanner.text_option", ["phase": enabled ? "enabled" : "disabled"])
        if !enabled { invalidateTextRecognition(resume: true); textRecognitionMessage = nil }
        else if captureMode == .photo && photoState == .noMatch { readCardText() }
    }

    /// One user-requested live frame, or one failed still. Never called from a
    /// video-frame callback. Only bounded temporary JPEG data crosses WebKit.
    func readCardText() {
        guard canReadCardText else { return }
        if captureMode == .photo { photoTextAttempted = true }
        invalidateTextRecognition()
        let id = textRequestID, requestNonce = nonce, requestedMode = captureMode, requestedGame = game
        let started = ProcessInfo.processInfo.systemUptime
        textRecognitionBusy = true; textRecognitionMessage = nil; manualSearchSuggested = false
        status = "Reading card text on this iPhone…"
        DiagnosticLog.shared.record("scanner.text_started", ["source": requestedMode.rawValue])
        textDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.isCurrentTextRequest(id, nonce: requestNonce) else { return }
            // An unresponsive page may still own a snapshot operation. Retire
            // it rather than letting a late result enter another capture.
            DiagnosticLog.shared.record("scanner.text_finished", ["phase": "timeout", "elapsed_ms": "20000"])
            self.webView.setCameraCaptureState(.none, completionHandler: nil)
            self.stop(); self.documentFailed = true; self.photoDocumentFailed()
            self.status = "Reading card text could not finish. Retry the scanner."
        }
        textTask = Task { [weak self] in
            guard let self else { return }
            var observations = 0
            do {
                let value = try await self.webView.callAsyncJavaScript(
                    "return await window.CardShowBridge?.captureTextImage(expectedNonce, operationID);",
                    arguments: ["expectedNonce": requestNonce, "operationID": id.uuidString], in: nil, contentWorld: .page)
                guard self.isCurrentTextRequest(id, nonce: requestNonce) else { return }
                guard let snapshot = value as? [String: Any], snapshot["source"] as? String == requestedMode.rawValue,
                      let base64 = snapshot["imageBase64"] as? String, base64.utf8.count <= 2_800_000,
                      let image = Data(base64Encoded: base64), image.count <= 2_000_000 else {
                    await self.finishTextRecognition(id, nonce: requestNonce, cards: [], observations: 0,
                        started: started, phase: "no_frame", message: requestedMode == .photo
                            ? "This photo could not provide readable text. Retake it or search manually."
                            : "Frame one card clearly, then try Read Card Text again.")
                    return
                }
                let text = try await self.textRecognizer.recognize(image)
                guard self.isCurrentTextRequest(id, nonce: requestNonce) else { return }
                observations = text.count
                let cards = try await self.textCatalog.candidates(from: text, game: requestedGame)
                guard self.isCurrentTextRequest(id, nonce: requestNonce) else { return }
                await self.finishTextRecognition(id, nonce: requestNonce, cards: cards, observations: observations,
                    started: started, phase: cards.isEmpty ? "no_match" : "suggestions",
                    message: cards.isEmpty ? "No catalog match from this text. Try another photo or search manually." : "Text suggestions ready. Check the card, printing and condition.")
            } catch {
                guard self.isCurrentTextRequest(id, nonce: requestNonce) else { return }
                // Vision errors and recognized text can contain private input.
                // Log only the bounded outcome and timings, never raw errors.
                await self.finishTextRecognition(id, nonce: requestNonce, cards: [], observations: observations,
                    started: started, phase: "unavailable", message: "Card text could not be matched. Try another photo or search manually.")
            }
        }
    }

    private func isCurrentTextRequest(_ id: UUID, nonce requestNonce: String) -> Bool {
        active && nonce == requestNonce && textRequestID == id && textRecognitionEnabled && textRecognitionBusy
            && resourceForeground && resourceMode != .cooling && !manualSearchSuspended && !documentFailed
            && !Task.isCancelled
    }

    private func finishTextRecognition(_ id: UUID, nonce requestNonce: String, cards: [CardCandidate], observations: Int,
                                       started: TimeInterval, phase: String, message: String) async {
        guard isCurrentTextRequest(id, nonce: requestNonce) else { return }
        let finished = try? await webView.callAsyncJavaScript(
            "return window.CardShowBridge?.finishTextRecognition(expectedNonce, operationID, matched);",
            arguments: ["expectedNonce": requestNonce, "operationID": id.uuidString, "matched": !cards.isEmpty],
            in: nil, contentWorld: .page)
        guard isCurrentTextRequest(id, nonce: requestNonce) else { return }
        let delivered = finished as? Bool == true
        if !delivered && phase != "no_frame" {
            DiagnosticLog.shared.record("scanner.text_finished", ["phase": "interrupted"])
            webView.setCameraCaptureState(.none, completionHandler: nil)
            stop(); documentFailed = true; photoDocumentFailed()
            status = "Card text could not finish. Retry the scanner."
            return
        }
        textDeadline?.cancel(); textDeadline = nil; textTask = nil; textRequestID = UUID(); textRecognitionBusy = false
        let suggestions = delivered ? Array(cards.prefix(5)) : []
        textRecognitionMessage = message
        status = textRecognitionMessage ?? message
        DiagnosticLog.shared.record("scanner.text_finished", ["phase": phase,
            "elapsed_ms": String(Int(max(0, min(20_000, (ProcessInfo.processInfo.systemUptime - started) * 1000)))),
            "observed_count": String(min(128, observations)), "candidates": String(suggestions.count)])
        guard !suggestions.isEmpty else { return }
        normalizer = TCGBridgeNormalizer(); recognitionReviewHeld = true
        if captureMode == .photo { photoAwaitingRetake = true; photoRestingState = .ready; updatePhotoState(.ready) }
        continuation.yield(ScanResult(id: UUID(), candidates: suggestions, accepted: false, same: false, source: .text))
    }

    private func invalidateTextRecognition(resume: Bool = false) {
        let previousID = textRequestID, wasBusy = textRecognitionBusy
        textRequestID = UUID(); textTask?.cancel(); textTask = nil; textDeadline?.cancel(); textDeadline = nil
        textRecognitionBusy = false
        if resume && wasBusy && active && bridgeInstalled && !documentFailed {
            let cancellationID = textRequestID, requestNonce = nonce
            textDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.active, self.nonce == requestNonce, self.textRequestID == cancellationID else { return }
                self.retireUnreleasedTextCapture()
            }
            webView.callAsyncJavaScript("return window.CardShowBridge?.finishTextRecognition(expectedNonce, operationID, false);",
                arguments: ["expectedNonce": requestNonce, "operationID": previousID.uuidString], in: nil, in: .page) { [weak self] result in
                    guard let self, self.active, self.nonce == requestNonce, self.textRequestID == cancellationID else { return }
                    self.textDeadline?.cancel(); self.textDeadline = nil
                    // False also means the bridge already retired this owner.
                    guard case .success(let value) = result, value is Bool else {
                        self.retireUnreleasedTextCapture(); return
                    }
                }
        }
    }

    private func retireUnreleasedTextCapture() {
        webView.setCameraCaptureState(.none, completionHandler: nil)
        stop(); documentFailed = true; photoDocumentFailed()
        status = "Scanner paused. Tap Retry Live Scanner."
    }

    @discardableResult func setCaptureMode(_ mode: ScannerCaptureMode) -> Bool {
        guard mode != captureMode else { return true }
        guard photoState != .processing, !textRecognitionBusy else { return false }
        invalidateTextRecognition()
        photoTextAttempted = false; recognitionReviewHeld = false; textRecognitionMessage = nil
        invalidatePhotoCommand()
        captureMode = mode; photoAwaitingRetake = false; photoRestingState = .failed
        normalizer = TCGBridgeNormalizer(); manualSearchSuggested = false
        reviewRelease.discardPending(); updatePhotoState(mode == .photo && resourceMode == .cooling ? .cooling : .off)
        DiagnosticLog.shared.record("scanner.capture_mode", ["phase": mode.rawValue])
        guard active, bridgeInstalled, !documentFailed else { return true }
        dispatchPhotoCommand("setCaptureMode", mode: mode)
        return true
    }

    func capturePhoto() {
        guard canCapturePhoto, !textRecognitionBusy else { return }
        photoTextAttempted = false; recognitionReviewHeld = false; textRecognitionMessage = nil
        photoAwaitingRetake = true; photoRestingState = .failed
        normalizer = TCGBridgeNormalizer(); reviewRelease.discardPending()
        updatePhotoState(.processing)
        status = "Capturing photo…"
        dispatchPhotoCommand("capturePhoto")
    }

    func retakePhoto() {
        guard canRetakePhoto, !textRecognitionBusy else { return }
        invalidateTextRecognition()
        photoTextAttempted = false; recognitionReviewHeld = false; textRecognitionMessage = nil
        photoAwaitingRetake = false
        normalizer = TCGBridgeNormalizer(); reviewRelease.discardPending()
        updatePhotoState(.off)
        status = "Starting camera for another photo…"
        dispatchPhotoCommand("retakePhoto")
    }

    /// An explicit retry discards an interrupted photo before the next page is
    /// installed, so retry opens framing directly instead of a failed still.
    func preparePhotoRetry() {
        guard !active, captureMode == .photo else { return }
        invalidatePhotoCommand()
        photoAwaitingRetake = false; photoRestingState = .failed
        normalizer = TCGBridgeNormalizer(); updatePhotoState(.off)
    }

    private func allowsPhotoCommand(retake: Bool) -> Bool {
        ScannerPhotoCommandPolicy.allows(mode: captureMode, state: photoState, retake: retake,
            active: active, foreground: resourceForeground, manual: manualSearchSuspended,
            cooling: resourceMode == .cooling, documentReady: bridgeInstalled && !documentFailed && Self.allowed(webView.url))
    }

    private var photoReviewConfiguration: Any {
        if captureMode == .photo && photoAwaitingRetake { return photoRestingState.rawValue }
        return NSNull()
    }

    private func invalidatePhotoCommand() {
        photoCommandID = UUID(); photoCommandDeadline?.cancel(); photoCommandDeadline = nil
    }

    private func updatePhotoState(_ state: PhotoScanState) {
        guard photoState != state else { return }
        photoState = state
        DiagnosticLog.shared.record("scanner.photo_state", ["phase": state.rawValue])
    }

    private func dispatchPhotoCommand(_ operation: String, mode: ScannerCaptureMode? = nil) {
        guard active, bridgeInstalled, !documentFailed, Self.allowed(webView.url),
              ["setCaptureMode", "capturePhoto", "retakePhoto"].contains(operation) else { return }
        invalidatePhotoCommand()
        let id = photoCommandID, requestNonce = nonce
        photoCommandDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.active, self.nonce == requestNonce, self.photoCommandID == id else { return }
            self.failPhotoCommand()
        }
        var arguments: [String: Any] = ["expectedNonce": requestNonce]
        if let mode { arguments["mode"] = mode.rawValue }
        let code = operation == "setCaptureMode"
            ? "return await window.CardShowBridge?.setCaptureMode(mode, expectedNonce);"
            : "return await window.CardShowBridge?.\(operation)(expectedNonce);"
        webView.callAsyncJavaScript(code, arguments: arguments, in: nil, in: .page) { [weak self] result in
            guard let self, self.active, self.nonce == requestNonce, self.photoCommandID == id else { return }
            self.photoCommandDeadline?.cancel(); self.photoCommandDeadline = nil
            guard case .success(let accepted) = result, accepted as? Bool == true else {
                self.failPhotoCommand(); return
            }
        }
    }

    private func failPhotoCommand() {
        // Retire uncertain page work before allowing a later photograph. This
        // also prevents a delayed result from becoming a card in another job.
        webView.setCameraCaptureState(.none, completionHandler: nil)
        stop(); documentFailed = true
        if captureMode == .photo {
            photoAwaitingRetake = true; photoRestingState = .failed; updatePhotoState(.failed)
        }
        status = "Photo Scan could not finish. Retry the scanner, then take another photo."
    }
    private func photoDocumentFailed() {
        invalidateTextRecognition()
        invalidatePhotoCommand()
        if captureMode == .photo { updatePhotoState(.failed) }
    }
    func resumeAfterManualSearchPrompt() {
        guard active, manualSearchSuggested else { return }
        manualSearchSuggested = false
        DiagnosticLog.shared.record("scanner.manual_search_resumed")
        webView.evaluateJavaScript("window.CardShowBridge?.resumeAfterManualSearchPrompt()", completionHandler: nil)
    }
    func suspendForManualSearch() {
        guard active, !manualSearchSuspended else { return }
        invalidateTextRecognition()
        manualSearchSuspended = true; manualSearchSuggested = false
        recognitionReviewHeld = false; textRecognitionMessage = nil
        invalidatePhotoCommand()
        if captureMode == .photo { updatePhotoState(.off) }
        normalizer = TCGBridgeNormalizer(); reviewRelease.discardPending()
        dispatchManualSearch("suspendForManualSearch")
    }
    func resumeAfterManualSearch() {
        guard active, manualSearchSuspended else { return }
        manualSearchSuspended = false
        guard !documentFailed else { return }
        DiagnosticLog.shared.record("scanner.manual_search_resumed")
        dispatchManualSearch("resumeAfterManualSearch")
    }
    private func dispatchManualSearch(_ operation: String) {
        guard bridgeInstalled, !documentFailed else { return }
        let requestNonce = nonce
        guard let data = try? JSONEncoder().encode(requestNonce), let argument = String(data: data, encoding: .utf8) else { return }
        // WebKit can finish an old queued evaluation after navigation. The JS
        // document checks its own nonce before applying a warm transition.
        webView.evaluateJavaScript("window.CardShowBridge?.\(operation)(\(argument)); null;") { [weak self] _, error in
            guard let self, self.active, self.nonce == requestNonce, error != nil else { return }
            self.documentFailed = true
            self.photoDocumentFailed()
            self.status = "Scanner could not resume. Tap Retry Live Scanner."
        }
    }
    func refreshDatabase() {
        guard active, resourceForeground, !textRecognitionBusy, !manualSearchSuspended,
              downloadPreviewState.action == nil else { return }
        downloadRefreshStatus = status
        suspendForManualSearch()
        downloadRefreshSuspended = true
        manualSearchSuggested = false
        status = "Checking database download size…"
        beginDownloadPreview(action: .refresh)
    }
    private func beginDownloadPreview(action: ScannerDownloadGateAction) {
        let requestNonce = nonce
        downloadGate.begin(game: game, action: action) { [weak self] in
            guard let self, self.active, self.nonce == requestNonce else { return }
            self.preparedDownloadAction = action
            self.continuePreparedDownload()
        }
    }
    private func continuePreparedDownload() {
        guard active, resourceForeground, let action = preparedDownloadAction else { return }
        preparedDownloadAction = nil
        switch action {
        case .initialLoad:
            status = resourceMode == .cooling ? Self.coolingStatus : "Starting bundled scanner…"
            loadBundledPage(restartingServer: false)
        case .refresh:
            releaseDownloadRefreshHold()
            manualSearchSuggested = false
            status = "Checking for database updates…"
            webView.evaluateJavaScript("window.CardShowBridge?.refreshDatabase(); null;", completionHandler: nil)
        }
    }
    func approveDownloadPreview() {
        guard active, resourceForeground else { return }
        downloadGate.approve()
    }
    func continueWithoutDownloadEstimate() {
        guard active, resourceForeground else { return }
        downloadGate.continueWithoutEstimate()
    }
    func retryDownloadPreview() {
        guard active, resourceForeground else { return }
        downloadGate.retry()
    }
    func cancelDownloadPreview() {
        let action = downloadPreviewState.action
        downloadGate.cancel()
        if action == .initialLoad { stop() }
        else if action == .refresh { releaseDownloadRefreshHold() }
    }
    private func releaseDownloadRefreshHold() {
        guard downloadRefreshSuspended else { return }
        let previousStatus = downloadRefreshStatus
        downloadRefreshSuspended = false; downloadRefreshStatus = nil
        resumeAfterManualSearch()
        if resourceMode == .cooling { status = Self.coolingStatus }
        else if let previousStatus { status = previousStatus }
    }
    func resetRecognition() {
        invalidateTextRecognition()
        recognitionReviewHeld = false; textRecognitionMessage = nil
        manualSearchSuggested = false
        reviewRelease.discardPending()
        normalizer = TCGBridgeNormalizer()
        webView.evaluateJavaScript("window.CardShowBridge?.resetRecognition()", completionHandler: nil)
    }
    func markScanIssue(_ issue: ScannerIssueKind) {
        guard active, Self.allowed(webView.url) else { return }
        let requestNonce = nonce
        Task { [weak self] in
            guard let self, self.active, self.nonce == requestNonce else { return }
            do {
                let marked = try await self.webView.callAsyncJavaScript("return window.CardShowBridge?.markScanIssue(reason) === true;",
                    arguments: ["reason": issue.rawValue], in: nil, contentWorld: .page)
                guard self.active, self.nonce == requestNonce else { return }
                self.status = marked as? Bool == true
                    ? "Scan issue marked. Keep this card steady for a few seconds."
                    : "Scanner is not ready to mark an issue yet."
            } catch {
                guard self.active, self.nonce == requestNonce else { return }
                DiagnosticLog.shared.failure("scanner.issue_marker_failed", error)
                self.status = "Could not mark this issue. Scanning can continue."
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let permitted = active && action.targetFrame?.isMainFrame == true && Self.allowed(action.request.url)
        if !permitted { DiagnosticLog.shared.record("web.navigation_blocked") }
        decisionHandler(permitted ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard active, webView === self.webView, let navigation, navigation === pageNavigation, Self.allowed(webView.url) else { return }
        pageNavigation = nil
        let requestNonce = nonce
        let installedSuspended = manualSearchSuspended
        let installedCaptureMode = captureMode
        let installedDeliveryDiagnostics = DiagnosticLog.shared.enabled
        deliveryDiagnosticsEnabled = installedDeliveryDiagnostics
        if recoveryAttempts > 0 { DiagnosticLog.shared.record("scanner.local_recovered", ["quantity": String(recoveryAttempts)]) }
        DiagnosticLog.shared.record("web.page_loaded")
        guard let url = Bundle.main.url(forResource: "TCGTrackingBridge", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let gameKey = TCGGameRegistry.scannerKey(for: game),
              let data = try? JSONSerialization.data(withJSONObject: ["nonce": nonce, "game": gameKey, "autoStart": true, "cacheToken": LocalScannerServer.shared.cacheToken,
                  "steadyCardBorder": UserDefaults.standard.object(forKey: "steadyCardBorder") as? Bool ?? true,
                  "manualSearchSuspended": manualSearchSuspended, "resourceMode": resourceMode.rawValue, "foreground": resourceForeground,
                  "captureMode": captureMode.rawValue,
                  "diagnosticsEnabled": installedDeliveryDiagnostics,
                  "photoReviewState": photoReviewConfiguration]),
              let config = String(data: data, encoding: .utf8) else {
            documentFailed = true
            photoDocumentFailed()
            DiagnosticLog.shared.record("web.resource_missing")
            status = "Scanner adapter resource or game configuration is missing."; return
        }
        webView.evaluateJavaScript(source + "\nwindow.CardShowBridge.install(" + config + "); null;") { [weak self] _, error in
            guard let self, self.active, self.nonce == requestNonce else { return }
            if let error {
                self.documentFailed = true; self.photoDocumentFailed(); DiagnosticLog.shared.failure("web.injection_failed", error)
                self.status = "Could not initialize bundled scanner modules. Retry Live Scanner."
            } else {
                self.bridgeInstalled = true
                self.dispatchResourceMode()
                if self.deliveryDiagnosticsEnabled != installedDeliveryDiagnostics { self.dispatchDeliveryDiagnostics() }
                if self.captureMode != installedCaptureMode { self.dispatchPhotoCommand("setCaptureMode", mode: self.captureMode) }
                // Pause/dismissal may have arrived after config was captured
                // but before this document installed its bridge callbacks.
                if self.manualSearchSuspended || installedSuspended {
                    self.dispatchManualSearch(self.manualSearchSuspended ? "suspendForManualSearch" : "resumeAfterManualSearch")
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageFailed(webView, navigation: navigation, error: error, event: "web.load_failed")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageFailed(webView, navigation: navigation, error: error, event: "web.navigation_failed")
    }
    private func pageFailed(_ webView: WKWebView, navigation: WKNavigation?, error: Error, event: String) {
        guard active, webView === self.webView, let navigation, navigation === pageNavigation else { return }
        pageNavigation = nil
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain && failure.code == URLError.cancelled.rawValue { return }
        DiagnosticLog.shared.failure(event, error)
        if ScannerPageRecoveryPolicy.allowsRetry(error: error, attempts: recoveryAttempts) {
            recoveryAttempts += 1
            DiagnosticLog.shared.record("scanner.local_retry", ["code": String(failure.code), "quantity": String(recoveryAttempts)])
            status = "Reconnecting scanner…"
            loadBundledPage(restartingServer: true)
        } else {
            documentFailed = true
            photoDocumentFailed()
            DiagnosticLog.shared.record("scanner.local_load_failed", ["quantity": String(recoveryAttempts),
                "reason": recoveryAttempts > 0 ? "retry_exhausted" : "not_retryable"])
            status = "Scanner could not reconnect. Tap Retry Live Scanner."
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard active, webView === self.webView else { return }
        pageTask?.cancel(); pageTask = nil; pageNavigation = nil; manualSearchSuggested = false
        documentFailed = true
        bridgeInstalled = false
        photoDocumentFailed()
        reviewRelease.restart()
        DiagnosticLog.shared.record("web.process_terminated")
        status = "Scanner process stopped. Tap Retry Live Scanner."
        continuation.yield(ScanResult(id: UUID(), candidates: [], accepted: false, same: true, visible: false))
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard resourceMode != .cooling, !documentFailed else { decisionHandler(.deny); return }
        let scheme = origin.protocol, host = origin.host, port = origin.port
        let mainFrame = frame.isMainFrame, cameraOnly = type == .camera
        let context = ScannerCameraRequestContext(active: active, scheme: scheme, host: host, port: port,
            mainFrame: mainFrame, cameraOnly: cameraOnly, documentURL: webView.url, expectedPageURL: Self.pageURL)
        guard webView === self.webView, context.isTrusted else {
            DiagnosticLog.shared.record("camera.permission_request", ["reason": "untrusted"])
            decisionHandler(.deny); return
        }
        let authorization = ScannerCameraAuthorizationCoordinator.shared
        switch ScannerCameraPermissionAction.action(for: authorization.authorizationStatus) {
        case .grant:
            DiagnosticLog.shared.record("camera.permission_request", ["reason": "native_authorized"])
            decisionHandler(.grant)
        case .deny:
            status = Self.deniedCameraStatus
            DiagnosticLog.shared.record("camera.permission_request", ["reason": "native_denied"])
            decisionHandler(.deny)
        case .requestNativeAccess:
            let requestNonce = nonce
            DiagnosticLog.shared.record("camera.permission_request", ["reason": "native_requested"])
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView, self.active, self.nonce == requestNonce,
                      webView === self.webView else { decisionHandler(.deny); return }
                let granted = await authorization.authorize()
                let current = ScannerCameraRequestContext(active: self.active, scheme: scheme, host: host, port: port,
                    mainFrame: mainFrame, cameraOnly: cameraOnly, documentURL: webView.url, expectedPageURL: Self.pageURL)
                guard self.nonce == requestNonce, webView === self.webView, current.isTrusted else {
                    decisionHandler(.deny); return
                }
                guard self.resourceMode != .cooling, !self.documentFailed else { decisionHandler(.deny); return }
                if !granted { self.status = Self.deniedCameraStatus }
                DiagnosticLog.shared.record("camera.permission_result", ["reason": granted ? "native_authorized" : "native_denied"])
                decisionHandler(granted ? .grant : .deny)
            }
        }
    }
    fileprivate func receive(_ message: WKScriptMessage) {
        guard active, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "http",
              message.frameInfo.securityOrigin.host == "127.0.0.1",
              message.frameInfo.securityOrigin.port == Int(LocalScannerServer.port),
              Self.allowed(webView.url) else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: message.body)
            guard data.count <= 1_200_000 else { throw BridgeFailure.invalidPayload }
            let envelope = try JSONDecoder().decode(TCGBridgeEnvelope.self, from: data)
            guard envelope.nonce == nonce else { return }
            if envelope.kind == "diagnostic" { logDiagnostic(envelope); return }
            if let state = PhotoScanState.validated(envelope) {
                guard captureMode == .photo || state == .off else { return }
                if resourceMode == .cooling { updatePhotoState(captureMode == .photo ? .cooling : .off); return }
                guard resourceForeground, !manualSearchSuspended else { return }
                if state == .processing {
                    photoTextAttempted = false; recognitionReviewHeld = false; textRecognitionMessage = nil
                    normalizer = TCGBridgeNormalizer(); photoAwaitingRetake = true; photoRestingState = .failed
                } else if state.isResting {
                    photoAwaitingRetake = true; photoRestingState = state
                }
                updatePhotoState(state)
                switch state {
                case .off: break
                case .framing:
                    photoTextAttempted = false; textRecognitionMessage = nil
                    status = "Frame one card, then tap Take Photo."
                case .processing: status = "Scanning photo… Camera is off."
                case .ready: status = "Photo scanned. Review the card or take another photo."
                case .noMatch: status = "No card found in this photo. Retake it or search manually."
                case .failed: status = "Photo could not be scanned. Retake it or search manually."
                case .cooling: status = Self.coolingStatus
                }
                if state == .noMatch && !photoTextAttempted { readCardText() }
                return
            }
            if envelope.kind == "photoState" { return }
            if captureMode == .photo && !resourceForeground && envelope.kind != "status" { return }
            if captureMode == .photo && envelope.kind == "scan" {
                guard photoAwaitingRetake, photoState == .processing || photoState == .ready else { return }
            }
            if resourceMode == .cooling && envelope.kind != "status" { return }
            if manualSearchSuspended && envelope.kind != "status" { return }
            // The one-shot text operation owns the snapshot/review boundary.
            if (textRecognitionBusy || recognitionReviewHeld) && ["scan", "hide", "manualSearchSuggested"].contains(envelope.kind) { return }
            if envelope.kind == "manualSearchSuggested" {
                guard !manualSearchSuggested else { return }
                manualSearchSuggested = true
                DiagnosticLog.shared.record("scanner.manual_search_suggested")
                return
            }
            if envelope.kind == "status" {
                if textRecognitionBusy { return }
                let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                status = cameraStatus == .denied || cameraStatus == .restricted
                    ? Self.deniedCameraStatus : resourceMode == .cooling ? Self.coolingStatus : String((envelope.message ?? "").prefix(1000))
                return
            }
            // The popup owns this unresolved attempt. A late recognition/hide
            // message must not present another screen while the user decides.
            if manualSearchSuggested && (envelope.kind == "scan" || envelope.kind == "hide") { return }
            if let result = try normalizer.receive(envelope, game: game) {
                recognitionReviewHeld = result.visible && !result.candidates.isEmpty
                continuation.yield(result)
            }
        } catch { DiagnosticLog.shared.failure("bridge.result_rejected", error); status = "Scanner result rejected: \(error.localizedDescription)" }
    }
    private func logDiagnostic(_ message: TCGBridgeEnvelope) {
        guard let record = ScannerDiagnosticRecord.validated(message) else { return }
        if let event = message.event, ["startup_failed", "camera_interrupted", "javascript_error", "javascript_rejection"].contains(event) {
            documentFailed = true
            photoDocumentFailed()
        }
        if message.event == "scanner_ready" { documentFailed = false }
        if let event = message.event, ["startup_started", "startup_failed", "camera_interrupted", "camera_backgrounded", "javascript_error", "javascript_rejection"].contains(event) {
            reviewRelease.loading()
        }
        if message.event == "scanner_ready", let ref = reviewRelease.becameReady() { dispatchReviewRelease(ref) }
        DiagnosticLog.shared.record(record.event, record.fields, sampleEvery: record.sampleEvery)
    }

}

@MainActor private final class WeakScanMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: TCGTrackingScannerProvider?
    init(owner: TCGTrackingScannerProvider) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}

struct TCGScannerWebView: UIViewRepresentable {
    let provider: TCGTrackingScannerProvider
    func makeUIView(context: Context) -> WKWebView { provider.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct CameraStatusView: View {
    @ObservedObject var provider: TCGTrackingScannerProvider
    var body: some View {
        Text(provider.status).font(.caption).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).accessibilityAddTraits(.updatesFrequently)
    }
}
