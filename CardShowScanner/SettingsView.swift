import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum DiagnosticFileClipboard {
    static func provider(for file: URL) throws -> NSItemProvider {
        guard file.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: file.path) else {
            throw CocoaError(.fileReadUnknown)
        }
        let item = NSItemProvider()
        item.suggestedName = file.lastPathComponent
        // Register only a file, independent of how this iOS version classifies
        // the .jsonl extension. Do not offer a text representation of its bytes.
        item.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all) { completion in
            completion(file, false, nil)
            return nil
        }
        return item
    }
}

/// Everyday preferences stay on the tab; occasional maintenance is one step away.
struct SettingsView: View {
    @AppStorage("defaultGame") private var game = "Pokémon"
    @AppStorage("sound") private var sound = false
    @AppStorage("haptics") private var haptics = true
    @State private var showingConnection = false
    @State private var returningFromConnection = false

    var body: some View {
        Form {
            Section("Scan preferences") {
                Picker("Default game", selection: $game) {
                    ForEach(CatalogOptions.games(including: game), id: \.self) { Text($0) }
                }.accessibilityIdentifier("settings.defaultGame")
                Toggle("Sound effects", isOn: $sound).accessibilityIdentifier("settings.sound")
                Toggle("Haptic feedback", isOn: $haptics).accessibilityIdentifier("settings.haptics")
            }
            Section {
                MarketPricingInfo()
                Button {
                    guard !showingConnection, !returningFromConnection else { return }
                    showingConnection = true
                    DiagnosticLog.shared.record("connection.opened", ["phase": "settings"])
                } label: {
                    SettingsDestinationLabel("TCGTracking sign-in", subtitle: "Website account and IP access", symbol: "person.crop.circle", tint: .blue)
                }.disabled(returningFromConnection).accessibilityIdentifier("settings.websiteConnection")
                NavigationLink { ResearchConnectionView() } label: {
                    SettingsDestinationLabel("API connection", subtitle: "Market activity and graded research", symbol: "network", tint: .purple)
                }.accessibilityIdentifier("settings.researchConnection")
            } header: {
                Text("Prices & connections")
            } footer: {
                Text("Market prices use Open API without website sign-in. Your website connection is used for account features.")
            }
            Section("Manage") {
                NavigationLink { LabelPrinterSettingsView() } label: {
                    SettingsDestinationLabel("Label printer", subtitle: "Connect a D110 or D110-M and review your queue", symbol: "printer", tint: .indigo)
                }.accessibilityIdentifier("settings.labelPrinter")
                NavigationLink { OfferDefaultsSettingsView() } label: {
                    SettingsDestinationLabel("Offer defaults", subtitle: "Cash, trade and maximum buy rates", symbol: "percent", tint: .green)
                }.accessibilityIdentifier("settings.offerDefaults")
                NavigationLink { ScannerDatabaseSettingsView() } label: {
                    SettingsDestinationLabel("Scanner database", subtitle: "Saved recognition data and updates", symbol: "externaldrive", tint: .orange)
                }.accessibilityIdentifier("settings.scannerDatabase")
                NavigationLink { DiagnosticsSettingsView() } label: {
                    SettingsDestinationLabel("Diagnostics", subtitle: "Export logs or manage recording", symbol: "waveform.path.ecg", tint: .pink)
                }.accessibilityIdentifier("settings.diagnostics")
                NavigationLink { AboutPrivacySettingsView() } label: {
                    SettingsDestinationLabel("About & Privacy", subtitle: "Version, storage and data sources", symbol: "info.circle", tint: .secondary)
                }.accessibilityIdentifier("settings.about")
            }
        }
        .navigationTitle("Settings")
        .fullScreenCover(isPresented: $showingConnection, onDismiss: {
            returningFromConnection = false
            DiagnosticLog.shared.record("connection.closed", ["phase": "settings"])
        }) {
            TCGTrackingConnectionView {
                guard showingConnection, !returningFromConnection else { return }
                returningFromConnection = true
                showingConnection = false
                DiagnosticLog.shared.record("connection.continued", ["phase": "settings"])
            }
        }
    }
}

private struct SettingsDestinationLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    init(_ title: String, subtitle: String, symbol: String, tint: Color) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.tint = tint
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.semibold))
                .foregroundStyle(tint).frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }
}

private struct OfferDefaultsSettingsView: View {
    @AppStorage("cashPercentage") private var cashPercentage = 70.0
    @AppStorage("tradePercentage") private var tradePercentage = 80.0
    @AppStorage("maximumBuyPercentage") private var maximumBuyPercentage = 75.0

    var body: some View {
        Form {
            Section {
                rateSlider("Cash offer", value: $cashPercentage, accessibilityLabel: "Cash percentage")
                rateSlider("Trade credit", value: $tradePercentage, accessibilityLabel: "Trade percentage")
                rateSlider("Maximum buy", value: $maximumBuyPercentage, accessibilityLabel: "Maximum buy percentage")
            } footer: {
                Text("These rates are copied into new sessions. Adjust an existing session from its list review; saved estimates keep their rates. Individual card overrides are available in Edit Card.")
            }
        }.navigationTitle("Offer Defaults").navigationBarTitleDisplayMode(.inline)
    }

    private func rateSlider(_ title: String, value: Binding<Double>, accessibilityLabel: String) -> some View {
        VStack(spacing: 8) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue))%").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: 0...100, step: 1).accessibilityLabel(accessibilityLabel)
        }.padding(.vertical, 5)
    }
}

private struct ScannerDatabaseSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var databaseUpdater = ScannerDatabaseUpdater.shared
    @State private var gameCatalog = ScannerGameCatalog.shared
    @AppStorage("defaultGame") private var game = "Pokémon"
    @AppStorage("autoDatabaseUpdates") private var autoDatabaseUpdates = true
    @State private var isVisible = false
    @State private var clearingCache = false
    @State private var cacheMessage = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Picker("Game", selection: $game) {
                    ForEach(CatalogOptions.games(including: game), id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("settings.databaseGame")
                Button(gameCatalog.isLoading ? "Checking Available Games…" : "Refresh Available Games") {
                    Task {
                        guard isVisible, scenePhase == .active else { return }
                        await gameCatalog.refresh()
                    }
                }.disabled(gameCatalog.isLoading).accessibilityIdentifier("settings.refreshDatabaseGames")
                if let status = gameCatalog.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.databaseGamesStatus")
                }
                Toggle("Automatic Database Updates", isOn: $autoDatabaseUpdates)
                    .accessibilityIdentifier("settings.autoDatabaseUpdates")
                    .onChange(of: autoDatabaseUpdates) { _, enabled in databaseUpdater.setEnabled(enabled) }
            } footer: {
                Text("Choose a game for future scans. Existing sessions keep their game. Recognition databases are checked at most once every seven days; the first download happens when you begin scanning.")
            }
            Section("Database status") {
                Text(databaseUpdater.status).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.databaseRefreshStatus")
                if let date = databaseUpdater.lastSuccessfulCheck(for: game) {
                    LabeledContent("Last successful refresh", value: date.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("settings.lastDatabaseCheck")
                } else {
                    Text("No refresh has completed for this game yet.").foregroundStyle(.secondary)
                }
                if let date = databaseUpdater.lastAttempt(for: game) {
                    LabeledContent("Last refresh attempt", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Button(databaseUpdater.isRefreshing ? "Refreshing Database…" : "Refresh Database Now", systemImage: "arrow.clockwise") {
                    databaseUpdater.refreshNow(game: game)
                }.buttonStyle(.borderless).frame(minHeight: 44)
                    .disabled(databaseUpdater.isRefreshing || clearingCache)
                    .accessibilityIdentifier("settings.refreshDatabase")
            }
            Section {
                DisclosureGroup("Storage maintenance") {
                    Text("Clearing the cache removes downloaded recognition data and web resource caches. The next live scan may need another download. Lists, sessions and sign-in cookies are kept. Close the scanner first.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(clearingCache ? "Clearing…" : "Clear Scanner Cache") {
                        clearingCache = true
                        Task {
                            defer { clearingCache = false }
                            do { try await TCGTrackingScannerProvider.clearStoredCache(); cacheMessage = true }
                            catch { self.error = "Could not clear the scanner database: " + error.localizedDescription }
                        }
                    }.disabled(clearingCache || databaseUpdater.isRefreshing)
                        .accessibilityIdentifier("settings.clearScannerCache")
                }
            } footer: {
                Text("Recognition-engine changes arrive through app updates. Market prices use a separate online lookup.")
            }
        }
        .navigationTitle("Scanner Database").navigationBarTitleDisplayMode(.inline)
        .task {
            guard scenePhase == .active else { return }
            await gameCatalog.refreshIfNeeded()
        }
        .onAppear {
            isVisible = true
            databaseUpdater.setForeground(scenePhase == .active)
            databaseUpdater.setSettingsVisible(true, game: game)
        }
        .onDisappear {
            isVisible = false
            gameCatalog.cancel()
            databaseUpdater.setSettingsVisible(false, game: game)
        }
        .onChange(of: game) { _, game in
            if isVisible { databaseUpdater.setSettingsVisible(true, game: game) }
        }
        .onChange(of: scenePhase) { _, phase in
            databaseUpdater.setForeground(phase == .active)
            if phase != .active { gameCatalog.cancel() }
            else if isVisible {
                Task {
                    guard isVisible, scenePhase == .active else { return }
                    await gameCatalog.refreshIfNeeded()
                }
            }
        }
        .failureAlert($error)
        .alert("Scanner cache cleared", isPresented: $cacheMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The next live scan may need another database download. Your saved lists, sessions and sign-in cookies are kept.")
        }
    }
}

@MainActor private struct DiagnosticsSettingsView: View {
    @AppStorage("diagnosticsEnabled") private var diagnosticsEnabled = true
    @State private var diagnosticURL: URL?
    @State private var error: String?
    @State private var confirmClear = false
    @State private var copyNotice: String?

    var body: some View {
        Form {
            Section {
                Toggle("Record diagnostics", isOn: $diagnosticsEnabled).accessibilityIdentifier("settings.recordDiagnostics")
                Button("Copy Diagnostic Log", systemImage: "doc.on.doc") {
                    copyNotice = nil
                    do {
                        let file = try DiagnosticLog.shared.exportForCopy()
                        let item = try DiagnosticFileClipboard.provider(for: file)
                        // Copy owns a separate temporary export. Share-sheet
                        // dismissal must not delete the clipboard's attachment.
                        UIPasteboard.general.setItemProviders([item], localOnly: true, expirationDate: nil)
                        copyNotice = "Diagnostic file copied. Paste it as an attachment."
                    } catch { self.error = "Could not copy the diagnostic file: " + error.localizedDescription }
                }.accessibilityIdentifier("settings.copyDiagnostics")
                if let copyNotice {
                    Label(copyNotice, systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(.green)
                        .accessibilityIdentifier("settings.diagnosticsCopied")
                }
                Button("Export Diagnostic Log", systemImage: "square.and.arrow.up") {
                    do { diagnosticURL = try DiagnosticLog.shared.export() }
                    catch { self.error = "Could not export the diagnostic file: " + error.localizedDescription }
                }.accessibilityIdentifier("settings.exportDiagnostics")
                if DiagnosticLog.shared.storageFailed {
                    Text("Diagnostics could not be written to local storage.").foregroundStyle(.orange)
                }
            } footer: {
                Text("Keeps about 512 KB of recent local events, including scanner timings, save errors, device heat and memory warnings. While the app is active, health summaries include app memory/CPU, battery state and responsiveness. Available iOS crash/hang report counts are included. Card contents, credentials, camera images and call stacks are excluded. Copy puts the diagnostic file on the clipboard; Export opens file sharing.")
            }
            Section {
                Button("Clear Diagnostic Log", role: .destructive) { confirmClear = true }
                    .accessibilityIdentifier("settings.clearDiagnostics")
            }
        }
        .navigationTitle("Diagnostics").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { diagnosticURL != nil }, set: { if !$0 { cleanupDiagnostics() } })) {
            if let diagnosticURL { ShareSheet(url: diagnosticURL) }
        }
        .confirmationDialog("Clear saved diagnostic events?", isPresented: $confirmClear) {
            Button("Clear Log", role: .destructive) {
                do { try DiagnosticLog.shared.clear(); copyNotice = nil }
                catch { self.error = error.localizedDescription }
            }
        }
        .failureAlert($error)
    }

    private func cleanupDiagnostics() {
        if let diagnosticURL { try? FileManager.default.removeItem(at: diagnosticURL.deletingLastPathComponent()) }
        diagnosticURL = nil
    }
}

private struct AboutPrivacySettingsView: View {
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown" }
    private var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown" }
    private var appRevision: String { Bundle.main.object(forInfoDictionaryKey: "ScannerWorkflowRevision") as? String ?? "Unknown" }

    var body: some View {
        Form {
            Section("Card Show Scanner") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: appBuild).accessibilityIdentifier("settings.appBuild")
                LabeledContent("Release", value: appRevision).accessibilityIdentifier("settings.appRevision")
            }
            Section("Market data") {
                Text("Market prices use the TCGTracking Open API for the exact condition, printing and language. Price lookups do not require website sign-in or a Beta API key.")
                Text("Open API prices are published daily. Up to four recently downloaded sets are cached across app launches and checked every 24 hours. Refresh Market Price checks sooner. Cached quotes retain their original dates; unavailable conditions stay unpriced.")
                Text("OppsV2 market activity covers active opportunities, so some cards have no activity data. Graded Research remains experimental and has separate product and grade coverage.")
            }
            Section("On this iPhone") {
                Text("Lists, sessions and diagnostic logs stay on this iPhone unless you export them. Camera frames and barcode images are processed on this phone.")
                Text("Label drafts and print progress are saved on this iPhone. Printing uses the Bluetooth printer you explicitly select while the app is open. Label prices are independent of inventory quantities, acquisition costs and show budgets.")
                Text("Website sign-in details and Direct Beta API credentials use device-only Keychain storage. Remove saved website credentials with Forget Saved Sign-In; manage API credentials in API Connection.")
            }
            Section("Internet requests & sharing") {
                Text("Game databases download from TCGTracking. Card artwork and market quotes use internet requests. Market activity and Research send selected catalog identifiers to TCGTracking or through your configured server.")
                Text("PSA lookup sends the certification number to your configured server and its certification service. CSV and diagnostic exports use the iOS share sheet.")
            }
        }.navigationTitle("About & Privacy").navigationBarTitleDisplayMode(.inline)
    }
}
