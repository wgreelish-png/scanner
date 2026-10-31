import SwiftUI
import WebKit

/// Account features share the normal website's persistent session. Market quotes
/// use the public Open API independently of website authentication.
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
    @StateObject private var browser = TCGTrackingConnectionBrowser()
    @State private var showingSignIn = true
    @State private var returning = false
    @FocusState private var focusedField: SignInField?
    private enum SignInField { case username, password }
    var continueTitle = "Done"
    var onContinue: () -> Void = {}

    init(continueTitle: String = "Done", onContinue: @escaping () -> Void = {}) {
        self.continueTitle = continueTitle
        self.onContinue = onContinue
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 8) {
                    if browser.loading || browser.signingIn { ProgressView(browser.signingIn ? "Signing in…" : "Loading TCGTracking…") }
                    if let message = browser.message { Text(message).font(.footnote).padding(.horizontal) }
                    TCGTrackingWebsite(browser: browser)
                    HStack {
                        Button { browser.goBack() } label: { Label("Back", systemImage: "chevron.backward") }.disabled(!browser.canGoBack)
                        Spacer()
                        Button("Sign In") { showingSignIn = true }
                        Spacer()
                        Button { browser.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    }.padding(.horizontal).padding(.bottom, 8)
                }.opacity(showingSignIn ? 0 : 1).allowsHitTesting(!showingSignIn).accessibilityHidden(showingSignIn)
                if showingSignIn {
                    Form {
                        Section {
                            TextField("Username or email", text: $browser.username)
                                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focusedField, equals: .username).submitLabel(.next)
                                .onSubmit { focusedField = .password }
                            SecureField("Password", text: $browser.password)
                                .textContentType(.password).focused($focusedField, equals: .password).submitLabel(.go)
                                .onSubmit { signIn() }
                            Toggle("Remember sign-in on this iPhone", isOn: Binding(get: { browser.rememberSignIn }, set: { browser.setRememberSignIn($0) }))
                            Button("Sign In") { signIn() }.disabled(!browser.canSignIn)
                        } header: { Text("TCGTracking account") } footer: {
                            Text("Remembered details stay in this iPhone's Keychain. They fill TCGTracking's normal sign-in form; verification may still be required.")
                        }
                        if let message = browser.message { Section { Text(message).font(.footnote) } }
                        Section {
                            Button("Use the Website Instead") { focusedField = nil; showingSignIn = false }
                            if browser.hasSavedCredentials {
                                Button("Forget Saved Sign-In", role: .destructive) { browser.forgetSavedSignIn() }
                            }
                        } footer: { Text("Website sign-in connects account features. Market prices use Open API independently.") }
                    }
                }
            }
            .navigationTitle("TCGTracking")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    guard !returning else { return }
                    returning = true; focusedField = nil
                    browser.webView.endEditing(true); browser.stop()
                    onContinue()
                } label: { Text(continueTitle).frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(returning)
                    .padding().background(.regularMaterial)
            }
        }
        .interactiveDismissDisabled()
        .onAppear { browser.startIfNeeded(); if browser.hasSavedCredentials { showingSignIn = false } }
        .onDisappear { browser.stop(); BetaIPAllowlistSync.shared.connectionChanged() }
    }
    private func signIn() {
        guard browser.canSignIn else { return }
        focusedField = nil; showingSignIn = false
        browser.signIn()
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
    @Published private(set) var message: String?
    @Published var username = ""
    @Published var password = ""
    @Published private(set) var rememberSignIn = false
    @Published private(set) var hasSavedCredentials = false
    @Published private(set) var signingIn = false
    private var started = false
    private let credentialsStore = TCGTrackingCredentialStore()
    private var pendingCredentials: TCGTrackingCredentials?
    private var followedLoginLink = false
    private var signInTask: Task<Void, Never>?
    private var pageID = UUID()
    var canSignIn: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && username.count <= 320 &&
            !password.isEmpty && password.count <= 4096 && !signingIn
    }

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
        do {
            if let saved = try credentialsStore.load() {
                username = saved.username; password = saved.password
                rememberSignIn = true; hasSavedCredentials = true
                pendingCredentials = saved; signingIn = true
            }
        } catch { message = TCGTrackingCredentialStoreFailure.read.localizedDescription }
        openStartPage()
    }
    func setRememberSignIn(_ remember: Bool) {
        if !remember && hasSavedCredentials {
            do { try credentialsStore.delete(); hasSavedCredentials = false }
            catch { message = TCGTrackingCredentialStoreFailure.delete.localizedDescription; return }
        }
        rememberSignIn = remember
    }
    func forgetSavedSignIn() {
        do {
            try credentialsStore.delete()
            hasSavedCredentials = false; rememberSignIn = false
            pendingCredentials = nil; username = ""; password = ""
            signInTask?.cancel(); signInTask = nil; signingIn = false; pageID = UUID()
            message = "Saved sign-in removed. The website session remains until you sign out there."
        } catch { message = TCGTrackingCredentialStoreFailure.delete.localizedDescription }
    }
    func signIn() {
        guard canSignIn else { return }
        pendingCredentials = TCGTrackingCredentials(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        followedLoginLink = false; signingIn = true; message = nil
        if !loading { attemptSignIn() }
    }
    private func attemptSignIn() {
        guard let credentials = pendingCredentials, !loading, TCGTrackingConnectionPolicy.allows(webView.url),
              let resource = Bundle.main.url(forResource: "WebsiteSignIn", withExtension: "js"),
              let script = try? String(contentsOf: resource, encoding: .utf8) else {
            if pendingCredentials != nil && !loading {
                pendingCredentials = nil; signingIn = false
                message = "Open the website's Sign In page, then try Sign In again."
            }
            return
        }
        let id = pageID, navigate = !followedLoginLink
        followedLoginLink = true
        signInTask?.cancel()
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                let probe = try await webView.callAsyncJavaScript(script, arguments: ["username": "", "password": "", "submit": false, "navigate": navigate], in: nil, contentWorld: .page)
                guard !Task.isCancelled, pageID == id else { return }
                let status = (probe as? [String: Any])?["status"] as? String
                if status == "navigating" { return }
                guard status == "ready" || status == "verification_required" else {
                    pendingCredentials = nil; signingIn = false
                    message = "Use the website to check your session or open its Sign In page."
                    return
                }
                // Only one submission per explicit/remembered attempt. Navigation
                // or a failed password must never trigger an automatic retry loop.
                pendingCredentials = nil
                var rememberFailed = false
                if rememberSignIn {
                    do { try credentialsStore.save(credentials); hasSavedCredentials = true }
                    catch { rememberFailed = true; message = TCGTrackingCredentialStoreFailure.save.localizedDescription }
                }
                let reply = try await webView.callAsyncJavaScript(script, arguments: ["username": credentials.username, "password": credentials.password, "submit": true, "navigate": false], in: nil, contentWorld: .page)
                guard !Task.isCancelled, pageID == id else { return }
                signingIn = false
                let submitted = (reply as? [String: Any])?["status"] as? String
                if submitted == "verification_required" { message = "Your details are filled. Complete verification and sign in on the website." }
                else if submitted == "submitted" { message = "Sign-in submitted. Check the website for the result, then return to the scanner." }
                else { message = "This page needs its normal website sign-in. Your details were not submitted automatically." }
                if rememberFailed { message = (message ?? "") + " Your details could not be saved on this iPhone." }
            } catch {
                guard !Task.isCancelled, pageID == id else { return }
                pendingCredentials = nil; signingIn = false
                message = "Check the website to finish signing in, or return to the app."
            }
        }
    }
    private func openStartPage() {
        loading = true
        var request = URLRequest(url: TCGTrackingConnectionPolicy.startURL)
        request.timeoutInterval = 25
        webView.load(request)
    }
    func goBack() {
        guard webView.canGoBack else { return }
        message = nil
        webView.goBack()
    }
    func reload() {
        message = nil
        if TCGTrackingConnectionPolicy.allows(webView.url) {
            loading = true
            webView.reload()
        } else { openStartPage() }
    }
    func stop() {
        pageID = UUID(); pendingCredentials = nil
        signInTask?.cancel(); signInTask = nil; signingIn = false
        password = ""; webView.stopLoading()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let mainWindow = action.targetFrame == nil || action.targetFrame?.isMainFrame == true
        let allowed = mainWindow ? TCGTrackingConnectionPolicy.allows(action.request.url)
            : TCGTrackingConnectionPolicy.allowsSubframe(action.request.url)
        guard allowed, !action.shouldPerformDownload else {
            if mainWindow {
                loading = false
                pendingCredentials = nil; signingIn = false
                message = "This window can open only the TCGTracking website. You can return to the scanner at any time."
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
        pageID = UUID(); signInTask?.cancel(); signInTask = nil
        if pendingCredentials == nil { signingIn = false }
        canGoBack = webView.canGoBack
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        canGoBack = webView.canGoBack
        if pendingCredentials != nil { attemptSignIn() }
    }
    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false
        pendingCredentials = nil; signingIn = false
        canGoBack = webView.canGoBack
        // WebKit errors can contain request URLs. Keep tokens and form values
        // out of app messages and diagnostics, including on failed sign-in.
        message = "TCGTracking could not load. Check your connection and reload, or return to the app."
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false
        pendingCredentials = nil; signingIn = false
        message = "The website stopped responding. Reload to try again, or return to the app."
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
