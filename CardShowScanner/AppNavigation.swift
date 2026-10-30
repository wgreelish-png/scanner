import SwiftUI
import SwiftData
import UIKit

/// Tabs navigate; only an explicit scan action creates a list or opens capture.
struct HomeView: View {
    private enum Section: Hashable { case lists, scan, research, settings }
    @State private var section: Section = .scan
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $section) {
            NavigationStack {
                SavedListsView(onOpenScan: { section = .scan })
            }
            .tabItem { Label("Lists", systemImage: "rectangle.stack") }
            .tag(Section.lists)

            NavigationStack {
                ScanHomeView(onOpenLists: { section = .lists })
            }
            .tabItem { Label("Scan", systemImage: "viewfinder") }
            .tag(Section.scan)

            NavigationStack {
                ResearchHubView(onOpenScan: { section = .scan }, openSettings: { section = .settings })
            }
            .tabItem { Label("Research", systemImage: "chart.xyaxis.line") }
            .tag(Section.research)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Section.settings)
        }
        .tint(.indigo)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear { BetaAllowlistForegroundObserver.shared.setForeground(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in BetaAllowlistForegroundObserver.shared.setForeground(phase == .active) }
        .onDisappear { BetaAllowlistForegroundObserver.shared.setForeground(false) }
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

                ShowBudgetSummaryCard()
                newScanCard
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
        .failureAlert($error)
        .onAppear {
            isVisible = true
            ScannerDatabaseUpdater.shared.setEnabled(autoDatabaseUpdates)
            ScannerDatabaseUpdater.shared.setForeground(scenePhase == .active)
            ScannerDatabaseUpdater.shared.setHomeVisible(true, game: game)
        }
        .onDisappear {
            isVisible = false
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
                    Text("Every confirmed card is saved in order.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Game", selection: $game) {
                ForEach(CatalogOptions.games, id: \.self) { Text($0) }
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
                ScannerDatabaseUpdater.shared.setHomeVisible(false, game: game)
                destination = session.id
            } label: {
                Label("Continue Scanning", systemImage: "viewfinder").frame(maxWidth: .infinity).padding(.vertical, 4)
            }.buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("home.continueScan")
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 22))
    }

    private func start() {
        guard destination == nil else { return }
        ScannerDatabaseUpdater.shared.setHomeVisible(false, game: game)
        do {
            let batch: ScanSession
            if let active { batch = try SessionService.replace(active, game: game, context: context) }
            else { batch = try SessionService.start(game: game, context: context) }
            hasChosenGame = true
            destination = batch.id
        } catch {
            self.error = error.localizedDescription
            ScannerDatabaseUpdater.shared.setHomeVisible(isVisible, game: game)
        }
    }
}
