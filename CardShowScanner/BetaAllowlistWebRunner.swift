import Foundation
import Network
import UIKit
import WebKit

extension BetaIPAllowlistSync {
    static let shared = BetaIPAllowlistSync(runner: BetaAllowlistWebRunner(), defaults: .standard, configuration: {
        let store = ResearchConnectionStore()
        do {
            guard try ResearchAccessMethod.selected(store: store) == .direct else { return .server }
            return try store.loadDirect() == nil ? .missing : .direct
        } catch { return .unavailable }
    })
}

/// Network observation exists only while the foreground app is active. Polling
/// also detects public-address changes that do not produce an NWPath update.
@MainActor final class BetaAllowlistForegroundObserver {
    static let shared = BetaAllowlistForegroundObserver()
    private var monitor: NWPathMonitor?
    private var lastPath: String?
    private var generation = UUID()

    func setForeground(_ active: Bool) {
        BetaIPAllowlistSync.shared.setForeground(active)
        if active {
            guard monitor == nil else { return }
            let id = UUID(); generation = id; lastPath = nil
            let monitor = NWPathMonitor(); self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let key = "\(path.status)|\(path.isExpensive)|\(path.isConstrained)|" +
                    path.availableInterfaces.map { "\($0.type):\($0.name)" }.sorted().joined(separator: ",")
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id, self.monitor != nil else { return }
                    defer { self.lastPath = key }
                    if let previous = self.lastPath, previous != key { BetaIPAllowlistSync.shared.networkChanged() }
                }
            }
            monitor.start(queue: DispatchQueue(label: "CardShowScanner.BetaAllowlist.Network"))
        } else {
            generation = UUID(); monitor?.cancel(); monitor = nil; lastPath = nil
        }
    }
}

/// The normal, persistent website session authorizes this operation. No account
/// password, CSRF token or API key is copied into a URL or native response.
@MainActor final class BetaAllowlistWebRunner: NSObject, BetaAllowlistSyncRunning, WKNavigationDelegate, WKUIDelegate {
    static let pageURL = URL(string: "https://tcgtracking.com/apiforbeta")!
    private var webView: WKWebView?
    private var navigation: WKNavigation?
    private var continuation: CheckedContinuation<BetaAllowlistSyncResult, Error>?
    private var generation: UUID?
    private var evaluation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var expectedShipperID = ""

    static func allowsPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == "tcgtracking.com" &&
            url.user == nil && url.password == nil && url.port == nil &&
            url.path == "/apiforbeta" && url.query == nil && url.fragment == nil
    }

    func run() async throws -> BetaAllowlistSyncResult {
        cancel(); try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
        let store = ResearchConnectionStore()
        guard try ResearchAccessMethod.selected(store: store) == .direct,
              let credentials = try store.loadDirect() else {
            return .init(status: .accessDenied)
        }
        expectedShipperID = credentials.shipperID
        let id = UUID(); generation = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .default()
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                configuration.mediaTypesRequiringUserActionForPlayback = .all
                let view = WKWebView(frame: .zero, configuration: configuration)
                view.isInspectable = false
                self.webView = view; view.navigationDelegate = self; view.uiDelegate = self
                var request = URLRequest(url: Self.pageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
                self.navigation = view.load(request)
                if self.navigation == nil { finish(.success(.init(status: .networkFailed))); return }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.generation == id else { return }
                    self.finish(.success(.init(status: .networkFailed)))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == id else { return }
                self?.cancel()
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<BetaAllowlistSyncResult, Error>) {
        generation = nil; evaluation?.cancel(); evaluation = nil; timeout?.cancel(); timeout = nil
        navigation = nil; expectedShipperID = ""
        if let view = webView {
            view.navigationDelegate = nil; view.uiDelegate = nil
            view.evaluateJavaScript("globalThis.__CardShowBetaAllowlistAbort?.abort();")
            view.stopLoading()
            view.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
            view.removeFromSuperview()
        }
        webView = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }

    private func isCurrent(_ id: UUID, view: WKWebView) -> Bool {
        generation == id && webView === view && Self.allowsPage(view.url) &&
            UIApplication.shared.applicationState == .active
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = generation, let navigation, navigation === self.navigation,
              isCurrent(id, view: webView) else { return }
        self.navigation = nil
        guard let url = Bundle.main.url(forResource: "BetaAllowlist", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            finish(.success(.init(status: .pageChanged))); return
        }
        let shipper = expectedShipperID
        let store = ResearchConnectionStore()
        evaluation = Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            do {
                let value = try await webView.callAsyncJavaScript(source,
                    arguments: ["operation": "probe", "expectedIP": "", "expectedShipperID": shipper],
                    in: nil, contentWorld: .page)
                try Task.checkCancellation()
                guard self.isCurrent(id, view: webView) else { return }
                guard let probe = value as? [String: Any], let status = probe["status"] as? String else {
                    self.finish(.success(.init(status: .pageChanged))); return
                }
                guard status == "ready" else {
                    self.finish(.success(Self.result(from: probe))); return
                }
                guard let ip = probe["ip"] as? String, let canonicalIP = BetaAllowlistAddress.canonical(ip),
                      let allowed = probe["allowedIPs"] as? [String], allowed.count <= 10,
                      probe["shipperID"] as? String == shipper else {
                    self.finish(.success(.init(status: .pageChanged))); return
                }
                if BetaAllowlistAddress.isCurrentSingleton(allowed, detectedIP: ip) {
                    self.finish(.success(.init(status: .alreadyCurrent, ip: canonicalIP))); return
                }
                // Revalidate immediately before the single replacement POST.
                // A separate empty-list save must never be sent.
                guard self.isCurrent(id, view: webView),
                      try ResearchAccessMethod.selected(store: store) == .direct,
                      try store.loadDirect()?.shipperID == shipper else {
                    self.finish(.failure(CancellationError())); return
                }
                let saved = try await webView.callAsyncJavaScript(source,
                    arguments: ["operation": "save", "expectedIP": ip, "expectedShipperID": shipper],
                    in: nil, contentWorld: .page)
                try Task.checkCancellation()
                guard self.isCurrent(id, view: webView) else { return }
                self.finish(.success(Self.result(from: saved, confirmedIP: canonicalIP)))
            } catch {
                guard self.generation == id else { return }
                self.finish(Task.isCancelled ? .failure(CancellationError()) : .success(.init(status: .networkFailed)))
            }
        }
    }

    static func result(from value: Any?, confirmedIP: String? = nil) -> BetaAllowlistSyncResult {
        guard let object = value as? [String: Any], let raw = object["status"] as? String else {
            return .init(status: .pageChanged)
        }
        let status: BetaAllowlistSyncResult.Status
        switch raw {
        case "saved": status = .saved
        case "already_current": status = .alreadyCurrent
        case "sign_in_required": status = .signInRequired
        case "account_mismatch": status = .accountMismatch
        case "access_denied": status = .accessDenied
        case "rate_limited": status = .rateLimited
        case "save_failed": status = .saveFailed
        case "network_failed": status = .networkFailed
        default: status = .pageChanged
        }
        if status == .saved || status == .alreadyCurrent {
            guard let confirmedIP, let returned = object["allowedIPs"] as? [String],
                  BetaAllowlistAddress.isCurrentSingleton(returned, detectedIP: confirmedIP) else {
                return .init(status: .saveFailed)
            }
            return .init(status: status, ip: confirmedIP)
        }
        let retry = (object["retryAfterSeconds"] as? NSNumber)?.doubleValue
        return .init(status: status, retryAfterSeconds: retry.flatMap { $0.isFinite && $0 >= 0 ? min(86_400, $0) : nil })
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        if generation != nil, UIApplication.shared.applicationState == .active,
           action.targetFrame?.isMainFrame == true, Self.allowsPage(action.request.url),
           !action.shouldPerformDownload {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if action.targetFrame == nil || action.targetFrame?.isMainFrame == true {
                finish(.success(.init(status: .signInRequired)))
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView, navigation === self.navigation { finish(.success(.init(status: .networkFailed))) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView, navigation === self.navigation { finish(.success(.init(status: .networkFailed))) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { finish(.success(.init(status: .networkFailed))) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
}
