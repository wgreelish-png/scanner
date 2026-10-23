import SwiftUI
import WebKit

/// The normal website owns sign-in. No credentials or page contents cross into
/// the app; only WebKit's persistent first-party website session is shared.
struct TCGTrackingConnectionPolicy {
    static let startURL = URL(string: "https://tcgtracking.com/")!

    static func allows(_ url: URL?) -> Bool {
        guard allowsHTTPS(url), let host = url?.host?.lowercased() else { return false }
        return host == "tcgtracking.com" || host == "www.tcgtracking.com"
    }

    // Verification services may bootstrap an empty frame before loading HTTPS.
    // These frames cannot navigate the main window or open another app.
    static func allowsSubframe(_ url: URL?) -> Bool {
        if url?.absoluteString == "about:blank" || url?.absoluteString == "about:srcdoc" { return true }
        return allowsHTTPS(url)
    }

    private static func allowsHTTPS(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }
}

@MainActor struct TCGTrackingConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = TCGTrackingConnectionBrowser()
    var continueTitle = "Done"
    var onContinue: () -> Void = {}

    init(continueTitle: String = "Done", onContinue: @escaping () -> Void = {}) {
        self.continueTitle = continueTitle
        self.onContinue = onContinue
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Open TCGTracking. Sign in if the website asks, then return. Prices require internet. You can continue without prices.")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                if browser.loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.bottom, 8)
                        .accessibilityLabel("Loading TCGTracking")
                }
                if let message = browser.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                TCGTrackingWebsite(browser: browser)
            }
            .navigationTitle("Connect TCGTracking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(continueTitle) { onContinue(); dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { browser.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                        .disabled(!browser.canGoBack)
                    Spacer()
                    Button { browser.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear { browser.startIfNeeded() }
        .onDisappear { browser.stop() }
    }
}

@MainActor private struct TCGTrackingWebsite: UIViewRepresentable {
    let browser: TCGTrackingConnectionBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor private final class TCGTrackingConnectionBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var errorMessage: String?
    private var started = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        openStartPage()
    }
    private func openStartPage() {
        errorMessage = nil
        loading = true
        var request = URLRequest(url: TCGTrackingConnectionPolicy.startURL)
        request.timeoutInterval = 25
        webView.load(request)
    }
    func goBack() {
        guard webView.canGoBack else { return }
        errorMessage = nil
        webView.goBack()
    }
    func reload() {
        errorMessage = nil
        if TCGTrackingConnectionPolicy.allows(webView.url) {
            loading = true
            webView.reload()
        } else { openStartPage() }
    }
    func stop() { webView.stopLoading() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let mainWindow = action.targetFrame == nil || action.targetFrame?.isMainFrame == true
        let allowed = mainWindow ? TCGTrackingConnectionPolicy.allows(action.request.url)
            : TCGTrackingConnectionPolicy.allowsSubframe(action.request.url)
        guard allowed, !action.shouldPerformDownload else {
            if mainWindow {
                loading = false
                errorMessage = "This window can open only the TCGTracking website. You can return to the scanner at any time."
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Keep trusted website popups in this visible window and its shared store.
        if action.targetFrame == nil, TCGTrackingConnectionPolicy.allows(action.request.url) {
            webView.load(action.request)
        }
        return nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        errorMessage = nil
        canGoBack = webView.canGoBack
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        canGoBack = webView.canGoBack
    }
    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false
        canGoBack = webView.canGoBack
        // WebKit errors can contain request URLs. Keep tokens and form values
        // out of app messages and diagnostics, including on failed sign-in.
        errorMessage = "TCGTracking could not load. Check your connection and reload, or continue without prices."
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false
        errorMessage = "The website stopped responding. Reload to try again, or continue without prices."
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
