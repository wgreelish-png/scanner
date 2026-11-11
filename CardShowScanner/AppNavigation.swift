import SwiftUI
import SwiftData
import UIKit

/// Tabs navigate; only an explicit scan action creates a list or opens capture.
struct HomeView: View {
    private enum Section: Hashable { case lists, scan, show, research, settings }
    @State private var section: Section = .scan
    @State private var listsNavigationID = UUID()
    @State private var scanNavigationID = UUID()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context

    var body: some View {
        TabView(selection: $section) {
            NavigationStack {
                SavedListsView(onOpenScan: openScan)
            }
            .id(listsNavigationID)
            .tabItem { Label("Lists", systemImage: "rectangle.stack") }
            .tag(Section.lists)

            NavigationStack {
                ScanHomeView(onOpenLists: openLists)
            }
            .id(scanNavigationID)
            .tabItem { Label("Scan", systemImage: "viewfinder") }
            .tag(Section.scan)

            NavigationStack { ShowHomeView() }
                .tabItem { Label("Show", systemImage: "calendar") }
                .tag(Section.show)

            NavigationStack {
                ResearchHubView(onOpenScan: openScan, openSettings: { section = .settings })
            }
            .tabItem { Label("Research", systemImage: "chart.xyaxis.line") }
            .tag(Section.research)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Section.settings)
        }
        .tint(.indigo)
        .toolbarBackground(.visible, for: .tabBar)
        .onChange(of: section) { _, _ in
            DiagnosticLog.shared.activity(.action, screen: activityScreen, action: .changeSection)
        }
        .onAppear {
            BetaAllowlistForegroundObserver.shared.setForeground(scenePhase == .active)
            if scenePhase == .active { synchronizeBudgetOutcomes() }
        }
        .onChange(of: scenePhase) { _, phase in
            BetaAllowlistForegroundObserver.shared.setForeground(phase == .active)
            if phase == .active { synchronizeBudgetOutcomes() }
        }
        .onDisappear { BetaAllowlistForegroundObserver.shared.setForeground(false) }
    }

    private var activityScreen: DiagnosticActivityScreen {
        switch section {
        case .lists: .lists
        case .scan: .scanHome
        case .show: .showHome
        case .research: .research
        case .settings: .settings
        }
    }

    private func synchronizeBudgetOutcomes() {
        do { _ = try ListBudgetOutcomeService.synchronizePending(context: context) }
        catch { DiagnosticLog.shared.record("outcome_budget.recovery_deferred", ["reason": "pending_sync"]) }
    }

    /// Explicit destination actions start at that tab's root. Ordinary tab
    /// changes keep their existing stacks and do not start a camera or session.
    private func openLists() {
        listsNavigationID = UUID()
        section = .lists
    }
    private func openScan() {
        scanNavigationID = UUID()
        section = .scan
    }
}

private struct ScanHomeView: View {
    let onOpenLists: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \ScanSession.startedAt, order: .reverse) private var sessions: [ScanSession]
    @Query private var lists: [CardList]
    @AppStorage("defaultGame") private var game = "Pokémon"
    @AppStorage("hasChosenBatchGame") private var hasChosenGame = false
    @AppStorage("autoDatabaseUpdates") private var autoDatabaseUpdates = true
    @State private var isVisible = false
    @State private var destination: UUID?
    @State private var draft: ScanBatchDraft?
    @State private var showingLeftoverStock = false
    @State private var leftoverStore = LeftoverStockStore.shared
    @State private var error: String?

    private var active: ScanSession? { sessions.first { $0.isActive } }
    private var activeList: CardList? {
        guard let active else { return nil }
        return lists.first { $0.id == active.listID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your next great find.").font(.largeTitle.bold())
                    Text("Scan cards, check matches, and build your list.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.top, 8)

                newScanCard
                NavigationLink { LeftoverStockView() } label: {
                    Label("Count Leftover Stock", systemImage: "checklist")
                        .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        .background(.background, in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain).accessibilityIdentifier("home.leftoverStock")
                if let active, let activeList { continueCard(session: active, list: activeList) }

                Button(action: onOpenLists) {
                    HStack(spacing: 14) {
                        Image(systemName: "rectangle.stack.fill").font(.title2).foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Open Existing List").font(.headline).foregroundStyle(.primary)
                            Text("Review cards, offers, and exports.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 20))
                }.buttonStyle(.plain).accessibilityIdentifier("home.openExistingLists")

                NavigationLink { SessionHistoryView() } label: {
                    Label("Session History", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.accessibilityIdentifier("home.sessions")
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $destination) { id in
            if let session = sessions.first(where: { $0.id == id }) { BatchScannerDestination(session: session) }
        }
        .navigationDestination(item: $draft) { draft in
            DraftScannerDestination(draft: draft)
        }
        .navigationDestination(isPresented: $showingLeftoverStock) { LeftoverStockView() }
        .failureAlert($error)
        .onAppear {
            isVisible = true
            DiagnosticLog.shared.activity(.screen, screen: .scanHome)
            ScannerDatabaseUpdater.shared.setEnabled(autoDatabaseUpdates)
            ScannerDatabaseUpdater.shared.setForeground(scenePhase == .active)
            ScannerDatabaseUpdater.shared.setHomeVisible(true, game: game)
        }
        .onDisappear {
            isVisible = false
            DiagnosticLog.shared.activity(.exit, screen: .scanHome)
            ScannerDatabaseUpdater.shared.setHomeVisible(false, game: game)
        }
        .onChange(of: game) { _, game in
            guard isVisible else { return }
            ScannerDatabaseUpdater.shared.setHomeVisible(true, game: game)
        }
        .onChange(of: sessions.first(where: { $0.id == destination })?.listID) { previous, current in
            // A list can be deleted from Lists while this tab retains its stack.
            // Retire that route instead of reopening a deleted list's scanner.
            if previous != nil && current == nil { destination = nil }
        }
        .onChange(of: draft?.session.listID) { previous, current in
            if previous != nil && current == nil && draft?.isCommitted == true { draft = nil }
        }
        .onChange(of: autoDatabaseUpdates) { _, enabled in ScannerDatabaseUpdater.shared.setEnabled(enabled) }
        .onChange(of: scenePhase) { _, phase in ScannerDatabaseUpdater.shared.setForeground(phase == .active) }
    }

    private var newScanCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "viewfinder").font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.indigo).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start a new list").font(.title3.bold())
                    Text("Your list is saved when you confirm its first card.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Game", selection: $game) {
                ForEach(CatalogOptions.games(including: game), id: \.self) { Text($0) }
            }.tint(.primary)
            Button(action: start) {
                Label("Start New Scan", systemImage: "camera.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("home.startNewScan")
            Text("Previous lists and offers stay saved.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 22))
    }

    private func continueCard(session: ScanSession, list: CardList) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Pick up where you left off", systemImage: "arrow.uturn.forward")
                .font(.caption.weight(.semibold)).foregroundStyle(.indigo)
            Text(list.name).font(.headline)
            Text("\(list.quantity) cards • \(list.knownValue.money) known value")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(session.game ?? game).font(.caption).foregroundStyle(.secondary)
            Button {
                DiagnosticLog.shared.activity(.action, screen: .scanHome, action: .resumeScanner,
                    state: .init(cardCount: list.quantity))
                ScannerDatabaseUpdater.shared.setHomeVisible(false, game: game)
                if leftoverStore.active?.countListIDs.contains(list.id) == true { showingLeftoverStock = true }
                else { destination = session.id }
            } label: {
                Label("Continue Scanning", systemImage: "viewfinder").frame(maxWidth: .infinity).padding(.vertical, 4)
            }.buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("home.continueScan")
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 22))
    }

    private func start() {
        guard destination == nil, draft == nil else { return }
        DiagnosticLog.shared.activity(.action, screen: .scanHome, action: .open)
        ScannerDatabaseUpdater.shared.setHomeVisible(false, game: game)
        do {
            draft = try SessionService.prepareDraft(game: game)
            hasChosenGame = true
        } catch {
            self.error = error.localizedDescription
            ScannerDatabaseUpdater.shared.setHomeVisible(isVisible, game: game)
        }
    }
}
