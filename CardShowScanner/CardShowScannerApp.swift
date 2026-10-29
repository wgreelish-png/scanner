import SwiftUI
import SwiftData

@main struct CardShowScannerApp: App {
    private let container: ModelContainer?
    private let startupError: String?
    init() {
        DiagnosticLog.shared.record("app.launch", [
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "revision": Bundle.main.object(forInfoDictionaryKey: "ScannerWorkflowRevision") as? String ?? "unknown"
        ])
        SessionService.prepareDefaults()
        do { container = try AppPersistence.open(); startupError = nil; DiagnosticLog.shared.record("storage.opened") }
        catch { container = nil; startupError = error.localizedDescription; DiagnosticLog.shared.failure("storage.open_failed", error) }
    }
    var body: some Scene {
        WindowGroup {
            if let container { HomeView().modelContainer(container) }
            else { StorageFailureView(message: startupError ?? "Unknown storage error") }
        }
    }
}

struct StorageFailureView: View {
    let message: String
    @State private var logURL: URL?
    @State private var error: String?
    var body: some View {
        VStack(spacing: 20) {
            Text("Could not open saved data").font(.title2.bold())
            Text(message)
            Text("Your database has not been deleted. Export diagnostics and report this error before reinstalling the app.")
            Button("Export Diagnostics") {
                do { logURL = try DiagnosticLog.shared.export() } catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent)
        }.padding().failureAlert($error)
            .sheet(isPresented: Binding(get: { logURL != nil }, set: { if !$0 {
                if let logURL { try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent()) }; logURL = nil
            } })) { if let logURL { ShareSheet(url: logURL) } }
    }
}

enum CatalogOptions {
    static let games = ["Pokémon", "Magic: The Gathering", "Yu-Gi-Oh!"]
    static let conditions = ["Near Mint", "Lightly Played", "Moderately Played", "Heavily Played", "Damaged"]
}

struct FailureAlert: ViewModifier {
    @Binding var message: String?
    func body(content: Content) -> some View {
        content.alert("Unable to complete action", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }
}
extension View {
    func failureAlert(_ message: Binding<String?>) -> some View { modifier(FailureAlert(message: message)) }
}

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \ScanSession.startedAt, order: .reverse) private var sessions: [ScanSession]
    @AppStorage("defaultGame") private var game = "Pokémon"
    @AppStorage("hasChosenBatchGame") private var hasChosenGame = false
    @AppStorage("autoDatabaseUpdates") private var autoDatabaseUpdates = true
    @State private var homeVisible = false
    @State private var destination: UUID?
    @State private var error: String?
    private var active: ScanSession? { sessions.first { $0.isActive } }
    var body: some View {
        NavigationStack {
            List {
                Section("Start New Scan") {
                    Picker("Game", selection: $game) {
                        ForEach(CatalogOptions.games, id: \.self) { Text($0) }
                    }
                    Button("Start New Scan", systemImage: "viewfinder") {
                        start()
                    }.font(.headline).padding(.vertical, 8).accessibilityIdentifier("home.startNewScan")
                    Text("Starts a new session and list. Previous lists and saved offers stay available.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink { SavedListsView() } label: {
                        Label("Open Existing List", systemImage: "list.bullet.rectangle")
                    }.font(.headline).padding(.vertical, 8).accessibilityIdentifier("home.openExistingLists")
                }
                Section("Research") {
                    NavigationLink { PSAResearchFlow() } label: {
                        Label("Research a PSA Slab", systemImage: "barcode.viewfinder")
                    }.accessibilityIdentifier("home.psaResearch")
                    Text("Read a PSA certification code, confirm the catalog card, and view research for its grade.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Card Show Scanner")
                .toolbar {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                        .accessibilityIdentifier("home.settings")
                }
                .navigationDestination(item: $destination) { id in
                    if let session = sessions.first(where: { $0.id == id }) { BatchScannerDestination(session: session) }
                }
                .failureAlert($error)
                .onAppear {
                    homeVisible = true
                    ScannerDatabaseUpdater.shared.setEnabled(autoDatabaseUpdates)
                    ScannerDatabaseUpdater.shared.setForeground(scenePhase == .active)
                    ScannerDatabaseUpdater.shared.setHomeVisible(true, game: game)
                }
                .onDisappear {
                    homeVisible = false
                    ScannerDatabaseUpdater.shared.setHomeVisible(false, game: game)
                }
                .onChange(of: game) { _, game in
                    ScannerDatabaseUpdater.shared.setHomeVisible(homeVisible, game: game)
                }
                .onChange(of: autoDatabaseUpdates) { _, enabled in
                    ScannerDatabaseUpdater.shared.setEnabled(enabled)
                }
                .onChange(of: scenePhase) { _, phase in
                    ScannerDatabaseUpdater.shared.setForeground(phase == .active)
                }
        }
    }
    private func start() {
        // Stop optional maintenance before routing into live scanning. The
        // provider also takes a lease for list-resumption and recovery routes.
        ScannerDatabaseUpdater.shared.setHomeVisible(false, game: game)
        do {
            let batch: ScanSession
            if let active { batch = try SessionService.replace(active, game: game, context: context) }
            else { batch = try SessionService.start(game: game, context: context) }
            hasChosenGame = true; destination = batch.id
        } catch {
            self.error = error.localizedDescription
            ScannerDatabaseUpdater.shared.setHomeVisible(homeVisible, game: game)
        }
    }
}

struct ActiveSessionCard: View {
    let session: ScanSession
    @Environment(\.modelContext) private var context
    @Query private var lists: [CardList]
    var body: some View {
        if let list = lists.first(where: { $0.id == session.listID }) {
            Text(session.game ?? "Unknown game").font(.title2.bold())
            Text(session.startedAt, format: .dateTime).foregroundStyle(.secondary)
            Text(list.name).font(.caption)
            LabeledContent("Cards in batch", value: String(list.quantity))
            LabeledContent("Known market subtotal", value: list.knownValue.money)
            if list.unpricedQuantity > 0 { Text("\(list.unpricedQuantity) unpriced copies need review").foregroundStyle(.orange) }
            NavigationLink { ScannerView(session: session, list: list) } label: { Label("Continue Scanning", systemImage: "viewfinder") }
            NavigationLink { SessionReviewView(session: session, list: list) } label: { Label("View List & Offers", systemImage: "dollarsign.circle") }
        } else {
            Text("The active session's list is unavailable.")
            FinishSessionButton(session: session)
        }
    }
}

struct BatchScannerDestination: View {
    let session: ScanSession
    @Query private var lists: [CardList]
    var body: some View {
        if let list = lists.first(where: { $0.id == session.listID }), session.isActive {
            ScannerView(session: session, list: list)
        } else { ContentUnavailableView("Session unavailable", systemImage: "tray") }
    }
}

struct SessionHistoryView: View {
    @Query(sort: \ScanSession.startedAt, order: .reverse) private var sessions: [ScanSession]
    @Query private var lists: [CardList]
    var body: some View {
        List {
            if sessions.isEmpty { ContentUnavailableView("No sessions yet", systemImage: "clock") }
            ForEach(sessions) { session in
                if let list = lists.first(where: { $0.id == session.listID }) {
                    NavigationLink { SessionReviewView(session: session, list: list) } label: {
                        VStack(alignment: .leading) {
                            Text(list.name).font(.headline)
                            Text("\(session.isActive ? "Active" : "Completed") • \(session.game ?? "")")
                            Text("\(list.quantity) cards • \(list.knownValue.money) known subtotal").font(.caption)
                        }
                    }
                } else {
                    VStack(alignment: .leading) {
                        Text(session.listName).font(.headline)
                        Text(session.startedAt, format: .dateTime)
                        Text("Historical record • \(session.addedQuantity) scanned • \(session.knownValue.money) known subtotal").font(.caption)
                        Text("Preserved original totals; no list association inferred.").font(.caption).foregroundStyle(.secondary)
                        if session.savedOffersData != nil { NavigationLink("Saved Offer Estimates") { SavedOffersView(session: session) } }
                    }
                }
            }
        }.navigationTitle("All Sessions")
    }
}
