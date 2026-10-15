import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage("defaultGame") private var game = "Pokémon"
    @AppStorage("defaultCondition") private var condition = "Near Mint"
    @AppStorage("automaticAdd") private var automatic = false
    @AppStorage("sound") private var sound = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage("cashPercentage") private var cashPercentage = 70.0
    @AppStorage("tradePercentage") private var tradePercentage = 80.0
    @AppStorage("maximumBuyPercentage") private var maximumBuyPercentage = 75.0
    @AppStorage("diagnosticsEnabled") private var diagnosticsEnabled = true
    @State private var diagnosticURL: URL?
    @State private var diagnosticError: String?
    @State private var confirmClear = false
    @State private var cacheMessage = false
    @State private var clearingCache = false
    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Game", selection: $game) { ForEach(CatalogOptions.games, id: \.self) { Text($0) } }
                Picker("Condition", selection: $condition) { ForEach(CatalogOptions.conditions, id: \.self) { Text($0) } }
                Toggle("Automatically add confident scans", isOn: $automatic)
                Text("Only accepted results at 90% confidence or above may auto-add. Repeated frames and ambiguous guesses never auto-add.").font(.caption)
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
            Section("Scanner") {
                Text("Choose Mock or experimental TCGTracking on the scanner screen. Live mode requires connectivity for initial module and game database loading.")
                Text("Finish a batch from its scanner or review screen. Cards and saved estimates are preserved.")
                Button(clearingCache ? "Clearing…" : "Clear Scanner Cache") {
                    clearingCache = true
                    Task { await TCGTrackingScannerProvider.clearStoredCache(); clearingCache = false; cacheMessage = true }
                }.disabled(clearingCache)
                Text("Removes TCGTracking web database and resource caches. Lists, sessions, and sign-in cookies are preserved. Close the scanner first.").font(.caption)
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
            Section("Privacy") { Text("Lists and sessions are stored locally on this iPhone. Live mode loads TCGTracking and its resources, and uses its browser scanner and catalog requests. CSV sharing sends the selected list through the iOS share sheet.") }
        }.navigationTitle("Settings")
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
