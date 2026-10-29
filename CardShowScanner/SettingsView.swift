import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var databaseUpdater = ScannerDatabaseUpdater.shared
    @AppStorage("defaultGame") private var game = "Pokémon"
    @AppStorage("sound") private var sound = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage("cashPercentage") private var cashPercentage = 70.0
    @AppStorage("tradePercentage") private var tradePercentage = 80.0
    @AppStorage("maximumBuyPercentage") private var maximumBuyPercentage = 75.0
    @AppStorage("diagnosticsEnabled") private var diagnosticsEnabled = true
    @AppStorage("autoDatabaseUpdates") private var autoDatabaseUpdates = true
    @State private var diagnosticURL: URL?
    @State private var diagnosticError: String?
    @State private var confirmClear = false
    @State private var cacheMessage = false
    @State private var clearingCache = false
    @State private var showingConnection = false
    @State private var returningFromConnection = false
    @AppStorage("tcgTrackingConnectionIntroduced") private var connectionIntroduced = false
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown" }
    private var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown" }
    private var appRevision: String { Bundle.main.object(forInfoDictionaryKey: "ScannerWorkflowRevision") as? String ?? "Unknown" }
    var body: some View {
        Form {
            Section("About this app") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: appBuild).accessibilityIdentifier("settings.appBuild")
                LabeledContent("Release", value: appRevision).accessibilityIdentifier("settings.appRevision")
            }
            Section("Market pricing") {
                PricingSourcePicker(accessibilityID: "settings.pricingSource")
                Text("Existing TCGTracking uses the current website connection. Open API requests condition, printing and language prices directly, without website sign-in. You can switch back at any time.").font(.caption)
                Text("Open API prices are published daily. The displayed update time describes the provider's data, not a new sale. This setting does not change the weekly recognition-database schedule or saved offers.").font(.caption).foregroundStyle(.secondary)
                Text("Open API keeps downloaded quotes for up to four recent sets across app launches and checks them once every 24 hours. Refresh Market Price checks sooner. Cached prices show their original update time; during a connectivity failure, previously downloaded quotes can be used offline. Missing conditions, printings and languages stay unpriced.").font(.caption).foregroundStyle(.secondary)
            }
            Section("TCGTracking API Connection") {
                NavigationLink { ResearchConnectionView() } label: {
                    Label("TCGTracking API Connection", systemImage: "chart.bar.xaxis")
                }.accessibilityIdentifier("settings.researchConnection")
                Text("Use Direct TCGTracking with your Beta API credentials in this iPhone’s Keychain, or connect your own server. Raw market activity and graded research test access independently.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Raw market activity (OppsV2)") {
                Text("Market Details shows public prices and optional exact-condition reported sales and comparable listings. OppsV2 covers active opportunities, so some cards have no activity coverage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Graded Research (experimental)") {
                Text("Research shows catalog-linked sales, grading population and valuation estimates. Coverage varies by product, printing, language and grade. Research remains experimental and preserves saved prices and offers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Defaults") {
                Picker("Game", selection: $game) { ForEach(CatalogOptions.games, id: \.self) { Text($0) } }
                Text("Every scan starts at Near Mint and requires confirmation before saving.").font(.caption)
                Toggle("Sound effects", isOn: $sound)
                Toggle("Haptic feedback", isOn: $haptics)
            }
            Section("Offer defaults • new sessions only") {
                Text("Cash offer: \(Int(cashPercentage))%")
                Slider(value: $cashPercentage, in: 0...100, step: 1).accessibilityLabel("Cash percentage")
                Text("Trade credit: \(Int(tradePercentage))%")
                Slider(value: $tradePercentage, in: 0...100, step: 1).accessibilityLabel("Trade percentage")
                Text("Maximum buy: \(Int(maximumBuyPercentage))%")
                Slider(value: $maximumBuyPercentage, in: 0...100, step: 1).accessibilityLabel("Maximum buy percentage")
                Text("Copied into each new batch. Existing sessions and saved estimates keep their rates. Per-card overrides are entered in the card editor. No automatic bulk classification.").font(.caption)

            }
            Section("TCGTracking prices") {
                Button("Connect TCGTracking", systemImage: "person.crop.circle") {
                    guard !showingConnection, !returningFromConnection else { return }
                    showingConnection = true
                    DiagnosticLog.shared.record("connection.opened", ["phase": "settings"])
                }.disabled(returningFromConnection)
                Text("This connection is used by Existing TCGTracking pricing. Open API pricing does not use website sign-in. Remember sign-in stores your details in this iPhone's Keychain; remove them with Forget Saved Sign-In. You can scan and save cards without prices.").font(.caption)
            }
            Section("Scanner") {
                Toggle("Automatic Database Updates", isOn: $autoDatabaseUpdates)
                    .accessibilityIdentifier("settings.autoDatabaseUpdates")
                    .onChange(of: autoDatabaseUpdates) { _, enabled in ScannerDatabaseUpdater.shared.setEnabled(enabled) }
                Text("Automatically checks the selected game's saved database at most once every seven days. Reopening the app during that week keeps using the cache. Refresh manually below whenever you need an update. The first download still happens when you start scanning. Recognition-engine changes come through app updates.").font(.caption)
                Button(databaseUpdater.isRefreshing ? "Refreshing Database…" : "Refresh Database Now", systemImage: "arrow.clockwise") {
                    databaseUpdater.refreshNow(game: game)
                }.buttonStyle(.borderless).frame(minHeight: 44)
                    .disabled(databaseUpdater.isRefreshing || clearingCache)
                    .accessibilityIdentifier("settings.refreshDatabase")
                Text(databaseUpdater.status).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.databaseRefreshStatus")
                if let date = databaseUpdater.lastSuccessfulCheck(for: game) {
                    LabeledContent("Last successful refresh", value: date.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("settings.lastDatabaseCheck")
                } else {
                    Text("No refresh has completed for this game yet.").font(.caption).foregroundStyle(.secondary)
                }
                if let date = databaseUpdater.lastAttempt(for: game) {
                    LabeledContent("Last refresh attempt", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Text("Live camera scanning opens by default. Download the selected game database once before scanning. Later camera openings load the saved database. Scanner options → Check Database Updates remains available for a manual check. Market values use an online lookup. Mock scanning is under Developer Testing.")
                Text("Finish a batch from its scanner or review screen. Cards and saved estimates are preserved.")
                Button(clearingCache ? "Clearing…" : "Clear Scanner Cache") {
                    clearingCache = true
                    Task {
                        defer { clearingCache = false }
                        do { try await TCGTrackingScannerProvider.clearStoredCache(); cacheMessage = true }
                        catch { diagnosticError = "Could not clear the scanner database: " + error.localizedDescription }
                    }
                }.disabled(clearingCache || databaseUpdater.isRefreshing)
                Text("Removes the downloaded scanner database from this app and clears its web resource caches. Lists, sessions, and sign-in cookies are preserved. Close the scanner first.").font(.caption)
            }
            Section("Diagnostics") {
                Toggle("Record diagnostics", isOn: $diagnosticsEnabled)
                Button("Export Diagnostic Log") {
                    do { diagnosticURL = try DiagnosticLog.shared.export() }
                    catch { diagnosticError = "Could not export the diagnostic file: " + error.localizedDescription }
                }
                Button("Clear Diagnostic Log", role: .destructive) { confirmClear = true }
                if DiagnosticLog.shared.storageFailed { Text("Diagnostics could not be written to local storage.").foregroundStyle(.orange) }
                Text("Keeps up to about 512 KB of recent local events across app launches. Includes scanner stages, timings, confidence, add decisions and save errors. Excludes card/list contents, credentials and camera images. Logs leave this device only when you share them.").font(.caption)
            }
            Section("Privacy") { Text("Lists, sessions and diagnostic logs stay on this iPhone unless you export them. Camera frames are processed on this phone. Game databases download from TCGTracking; card images and market quotes use internet requests. Raw market activity and graded research send selected catalog identifiers directly to TCGTracking or through your configured server. Direct Beta API credentials are stored in device-only Keychain and sent only to TCGTracking’s Beta service. PSA lookup sends the certification number to your configured server and its certification service; barcode images stay on this phone. CSV sharing sends the selected list through the iOS share sheet.") }
        }.navigationTitle("Settings")
            .onAppear {
                databaseUpdater.setForeground(scenePhase == .active)
                databaseUpdater.setSettingsVisible(true, game: game)
            }
            .onDisappear { databaseUpdater.setSettingsVisible(false, game: game) }
            .onChange(of: game) { _, game in databaseUpdater.setSettingsVisible(true, game: game) }
            .onChange(of: scenePhase) { _, phase in databaseUpdater.setForeground(phase == .active) }
            .fullScreenCover(isPresented: $showingConnection, onDismiss: {
                returningFromConnection = false
                DiagnosticLog.shared.record("connection.closed", ["phase": "settings"])
            }) {
                TCGTrackingConnectionView {
                    guard showingConnection, !returningFromConnection else { return }
                    returningFromConnection = true
                    connectionIntroduced = true
                    OnlineMarketPricing.connectionDidChange()
                    showingConnection = false
                    DiagnosticLog.shared.record("connection.continued", ["phase": "settings"])
                }
            }
            .sheet(isPresented: Binding(get: { diagnosticURL != nil }, set: { if !$0 { cleanupDiagnostics() } })) {
                if let diagnosticURL { ShareSheet(url: diagnosticURL) }
            }
            .confirmationDialog("Clear saved diagnostic events?", isPresented: $confirmClear) {
                Button("Clear Log", role: .destructive) {
                    do { try DiagnosticLog.shared.clear() } catch { diagnosticError = error.localizedDescription }
                }
            }
            .failureAlert($diagnosticError)
            .alert("Scanner cache cleared", isPresented: $cacheMessage) { Button("OK", role: .cancel) {} } message: { Text("TCGTracking web database and resource caches were cleared. The next live scan may need another download. Mock scanning has no cache.") }
    }
    private func cleanupDiagnostics() {
        if let diagnosticURL { try? FileManager.default.removeItem(at: diagnosticURL.deletingLastPathComponent()) }
        diagnosticURL = nil
    }
}
