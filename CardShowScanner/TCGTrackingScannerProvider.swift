import Foundation
import WebKit
import SwiftUI

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
        return CardCandidate(identity: CardIdentity(game: game, productID: ref, skuID: skuID, printing: printing),
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

/// Experimental module adapter, based on the user's supplied sources and permission.
/// Does not claim an official TCGTracking API contract.
@MainActor final class TCGTrackingScannerProvider: NSObject, ObservableObject, ScannerProvider, WKNavigationDelegate, WKUIDelegate {
    let label = "LIVE CAMERA • On-device recognition"
    private(set) var results: AsyncStream<ScanResult>
    private var continuation: AsyncStream<ScanResult>.Continuation
    let webView: WKWebView
    @Published private(set) var status = "Preparing TCGTracking…"
    private var active = false
    private var game = "Pokémon"
    private var nonce = UUID().uuidString
    private var normalizer = TCGBridgeNormalizer()
    static let pageURL = LocalScannerServer.pageURL
    static let gameKeys = ["Pokémon": "tcgp:3", "Magic: The Gathering": "tcgp:1", "Yu-Gi-Oh!": "tcgp:2"]
    private var messageProxy: WeakScanMessageHandler?

    override init() {
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
        webView.scrollView.isScrollEnabled = false
    }
    func start(game: String) {
        stop()
        let stream = AsyncStream<ScanResult>.makeStream(bufferingPolicy: .bufferingNewest(1))
        results = stream.stream; continuation = stream.continuation
        DiagnosticLog.shared.record("web.load_started", ["game": Self.gameKeys[game] == "tcgp:3" ? "pokemon" : (Self.gameKeys[game] == "tcgp:1" ? "magic" : "yugioh")])
        self.game = game; active = true; nonce = UUID().uuidString; normalizer = TCGBridgeNormalizer()
        status = "Starting bundled scanner…"
        let startupNonce = nonce
        Task {
            do {
                try await LocalScannerServer.shared.start()
                guard active, nonce == startupNonce else { return }
                webView.load(URLRequest(url: Self.pageURL))
            } catch { status = "Local scanner could not start: " + error.localizedDescription }
        }
    }
    func stop() {
        if active { DiagnosticLog.shared.record("web.stopped") }
        active = false; nonce = UUID().uuidString
        continuation.finish()
        webView.evaluateJavaScript("window.CardShowBridge?.stop()", completionHandler: nil)
        webView.stopLoading()
        normalizer = TCGBridgeNormalizer()
    }
    func clearCache() async throws {
        stop()
        await Self.clearStoredCache()
    }
    static func clearStoredCache() async {
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
    func releaseReview() {
        webView.evaluateJavaScript("window.CardShowBridge?.releaseReview()", completionHandler: nil)
    }
    func resetRecognition() {
        normalizer = TCGBridgeNormalizer()
        webView.evaluateJavaScript("window.CardShowBridge?.resetRecognition()", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let permitted = active && action.targetFrame?.isMainFrame == true && Self.allowed(action.request.url)
        if !permitted { DiagnosticLog.shared.record("web.navigation_blocked") }
        decisionHandler(permitted ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard active, Self.allowed(webView.url) else { return }
        DiagnosticLog.shared.record("web.page_loaded")
        guard let url = Bundle.main.url(forResource: "TCGTrackingBridge", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let gameKey = Self.gameKeys[game],
              let data = try? JSONSerialization.data(withJSONObject: ["nonce": nonce, "game": gameKey, "autoStart": true]),
              let config = String(data: data, encoding: .utf8) else {
            DiagnosticLog.shared.record("web.resource_missing")
            status = "Scanner adapter resource or game configuration is missing."; return
        }
        webView.evaluateJavaScript(source + "\nwindow.CardShowBridge.install(" + config + "); null;") { [weak self] _, error in
            if let error { DiagnosticLog.shared.failure("web.injection_failed", error); self?.status = "Could not initialize bundled scanner modules. Retry Live Scanner." }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if active { DiagnosticLog.shared.failure("web.load_failed", error); status = "Bundled scanner could not load: \(error.localizedDescription)" }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if active { DiagnosticLog.shared.failure("web.navigation_failed", error); status = "Bundled scanner navigation failed: \(error.localizedDescription)" }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        DiagnosticLog.shared.record("web.process_terminated")
        status = "Scanner process stopped. Tap Retry Live Scanner."
        continuation.yield(ScanResult(id: UUID(), candidates: [], accepted: false, same: true, visible: false))
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard active, origin.protocol == "http", origin.host == "127.0.0.1", origin.port == Int(LocalScannerServer.port), frame.isMainFrame, type == .camera else {
            DiagnosticLog.shared.record("camera.permission_request", ["reason": "denied_origin_or_type"])
            decisionHandler(.deny); return
        }
        DiagnosticLog.shared.record("camera.permission_request", ["reason": "system_prompt"])
        decisionHandler(.prompt)
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
            if envelope.kind == "status" { status = String((envelope.message ?? "").prefix(1000)); return }
            if let result = try normalizer.receive(envelope, game: game) { continuation.yield(result) }
        } catch { DiagnosticLog.shared.failure("bridge.result_rejected", error); status = "Scanner result rejected: \(error.localizedDescription)" }
    }
    private func logDiagnostic(_ message: TCGBridgeEnvelope) {
        let allowed: Set<String> = ["bridge_ready", "bridge_stopped", "startup_started", "modules_ready", "index_ready", "pack_ready",
            "backend_ready", "camera_requested", "camera_acquired", "video_playing", "scanner_ready", "startup_failed",
            "scan_stats", "recognition_settled", "camera_interrupted", "camera_backgrounded", "javascript_error", "javascript_rejection"]
        guard let event = message.event, allowed.contains(event) else { return }
        var fields: [String: String] = [:]
        if let stage = message.stage, ["modules", "index", "pack", "backend", "camera", "video", "scan"].contains(stage) { fields["stage"] = stage }
        if let backend = message.backend, ["worker", "main"].contains(backend) { fields["backend"] = backend }
        if let kind = message.errorKind, ["NotAllowedError", "NotFoundError", "NotReadableError", "AbortError", "SecurityError", "TypeError", "RangeError", "Error"].contains(kind) { fields["reason"] = kind }
        for (key, value) in [("elapsed_ms", message.elapsedMS), ("scan_ms", message.scanMS), ("capture_ms", message.captureMS)] {
            if let value, value.isFinite, (0...86400000).contains(value) { fields[key] = String(Int(value)) }
        }
        if let frames = message.frames, (0...1000000).contains(frames) { fields["frames"] = String(frames) }
        DiagnosticLog.shared.record("web." + event, fields, sampleEvery: event == "scan_stats" ? 5 : 0)
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
