import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage("defaultGame") private var game = "Pokémon"
    @AppStorage("defaultCondition") private var condition = "Near Mint"
    @AppStorage("automaticAdd") private var automatic = false
    @AppStorage("sound") private var sound = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage("pricingPercentage") private var percentage = 70.0
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
                Slider(value: $percentage, in: 0...100, step: 1) { Text("Pricing percentage") }
                Text("Offer reference: \(Int(percentage))% of known market subtotal")
            }
            Section("Scanner") {
                Text("Choose Mock or experimental TCGTracking on the scanner screen. Live mode requires connectivity for initial module and game database loading.")
                Text("Reset the current session from its scanner screen. Existing lists are preserved.")
                Button(clearingCache ? "Clearing…" : "Clear Scanner Cache") {
                    clearingCache = true
                    Task { await TCGTrackingScannerProvider.clearStoredCache(); clearingCache = false; cacheMessage = true }
                }.disabled(clearingCache)
                Text("Removes TCGTracking web database and resource caches. Lists, sessions, and sign-in cookies are preserved. Close the scanner first.").font(.caption)
            }
            Section("Privacy") { Text("Lists and sessions are stored locally on this iPhone. Live mode loads TCGTracking and its resources, and uses its browser scanner and catalog requests. CSV sharing sends the selected list through the iOS share sheet.") }
        }.navigationTitle("Settings")
            .alert("Scanner cache cleared", isPresented: $cacheMessage) { Button("OK", role: .cancel) {} } message: { Text("TCGTracking web database and resource caches were cleared. The next live scan may need another download. Mock scanning has no cache.") }
    }
}
