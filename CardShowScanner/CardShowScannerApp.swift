import SwiftUI
import SwiftData

@main struct CardShowScannerApp: App {
    private let container: ModelContainer?
    private let startupError: String?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("diagnosticsEnabled") private var diagnosticsEnabled = true
    @State private var sceneDiagnostics = AppSceneDiagnostics()
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
            rootView
                .onAppear { sceneDiagnostics.record(scenePhase); updateHealthMonitoring() }
                .onChange(of: scenePhase) { _, phase in sceneDiagnostics.record(phase); updateHealthMonitoring() }
                .onChange(of: diagnosticsEnabled) { _, _ in sceneDiagnostics.record(scenePhase); updateHealthMonitoring() }
        }
    }

    @MainActor private func updateHealthMonitoring() {
        DeviceHealthMonitor.shared.setForeground(scenePhase == .active)
        DeviceHealthMonitor.shared.refreshDiagnosticsPreference()
        DeviceMetricReports.shared.setEnabled(scenePhase == .active && diagnosticsEnabled)
    }

    @ViewBuilder private var rootView: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--show-transactions-ui-fixture") {
            ShowTransactionFixtureScreen()
        } else if ProcessInfo.processInfo.arguments.contains("--uitest-market-evidence") {
            MarketEvidenceFixtureScreen(research: false)
        } else if ProcessInfo.processInfo.arguments.contains("--uitest-research-evidence") {
            MarketEvidenceFixtureScreen(research: true)
        } else if ProcessInfo.processInfo.arguments.contains("--uitest-card-research") {
            CombinedResearchFixtureScreen()
        } else if ProcessInfo.processInfo.arguments.contains("--uitest-card-show-inventory") {
            CardShowInventoryFixtureScreen()
        } else if ProcessInfo.processInfo.arguments.contains("--uitest-streamlined-review") {
            ReviewPresentationFixtureScreen()
        } else if ProcessInfo.processInfo.arguments.contains("--uitest-manual-add") {
            ManualCardAddFixtureScreen()
        } else if ProcessInfo.processInfo.arguments.contains("--uitest-scanner-recents") {
            ScannerRecentCardsFixtureScreen()
        } else if ProcessInfo.processInfo.arguments.contains("--uitest-persistent-navigation") {
            PersistentNavigationFixtureScreen()
        } else if ProcessInfo.processInfo.arguments.contains("--uitest-bulk-list-delete") {
            ListBulkDeletionFixtureScreen()
        } else if let budgetTestID = Self.budgetUITestID {
            ShowBudgetFixtureScreen(id: budgetTestID)
        } else {
            standardView
        }
#else
        standardView
#endif
    }

#if DEBUG
    private static var budgetUITestID: UUID? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitest-show-budget"),
              let index = arguments.firstIndex(of: "--budget-test-id"), index + 1 < arguments.count else { return nil }
        return UUID(uuidString: arguments[index + 1])
    }
#endif

    @ViewBuilder private var standardView: some View {
        if let container { HomeView().modelContainer(container) }
        else { StorageFailureView(message: startupError ?? "Unknown storage error") }
    }
}

/// The app root sees settings, printing and other screens too. Repeated view
/// appearances cannot masquerade as new application lifecycle transitions.
@MainActor final class AppSceneDiagnostics {
    private let log: DiagnosticLog
    private var lastPhase: ScenePhase?

    init(log: DiagnosticLog = .shared) { self.log = log }

    func record(_ phase: ScenePhase) {
        guard log.enabled, phase != lastPhase else { return }
        let value: String
        switch phase {
        case .active: value = "active"
        case .inactive: value = "inactive"
        case .background: value = "background"
        @unknown default: value = "unknown"
        }
        lastPhase = phase
        log.record("app.scene", ["phase": value])
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
    @MainActor static var games: [String] {
        games(including: UserDefaults.standard.string(forKey: "defaultGame") ?? "Pokémon")
    }
    @MainActor static func games(including selected: String) -> [String] {
        let games = ScannerGameCatalog.shared.games
        guard TCGGameRegistry.scannerKey(for: selected) != nil, !games.contains(selected) else { return games }
        return games + [selected]
    }
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

struct DraftScannerDestination: View {
    let draft: ScanBatchDraft
    var body: some View {
        ScannerView(session: draft.session, list: draft.list, draft: draft)
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
