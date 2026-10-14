import SwiftUI
import SwiftData

@main struct CardShowScannerApp: App {
    var body: some Scene {
        WindowGroup { HomeView() }
            .modelContainer(for: [CardList.self, InventoryCard.self, ScanSession.self])
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
    @Query(sort: \CardList.createdAt, order: .reverse) private var lists: [CardList]
    @Query(sort: \ScanSession.startedAt, order: .reverse) private var sessions: [ScanSession]
    var body: some View {
        NavigationStack {
            List {
                Section("Your collection") {
                    LabeledContent("Cards in lists", value: "\(lists.reduce(0) { $0 + $1.quantity })")
                    LabeledContent("Cards scanned", value: "\(sessions.reduce(0) { $0 + $1.addedQuantity })")
                    LabeledContent("Known market subtotal", value: lists.reduce(Decimal.zero) { $0 + $1.knownValue }.money)
                    let missing = lists.reduce(0) { $0 + $1.unpricedQuantity }
                    if missing > 0 { Text("\(missing) copies have no price; totals are partial.").foregroundStyle(.secondary) }
                }
                Section {
                    NavigationLink { ScanDestinationView() } label: { Label("Start Scanning", systemImage: "viewfinder") }.padding(.vertical, 10)
                    NavigationLink { SavedListsView() } label: { Label("My Lists", systemImage: "list.bullet.rectangle") }
                    NavigationLink { SessionHistoryView() } label: { Label("Recent Sessions", systemImage: "clock") }
                    NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
                }
                if let latest = sessions.first {
                    Section("Most recent session") {
                        Text(latest.listName)
                        Text(latest.startedAt, style: .date)
                        Text("\(latest.addedQuantity) cards • \(latest.knownValue.money) known value")
                    }
                }
            }.navigationTitle("Card Show Scanner")
        }
    }
}

struct SessionHistoryView: View {
    @Query(sort: \ScanSession.startedAt, order: .reverse) var sessions: [ScanSession]
    var body: some View {
        List {
            if sessions.isEmpty { ContentUnavailableView("No sessions yet", systemImage: "clock") }
            ForEach(sessions) { session in
                VStack(alignment: .leading) {
                    Text(session.listName).font(.headline)
                    Text(session.startedAt, format: .dateTime)
                    Text("\(session.addedQuantity) cards • \(session.knownValue.money) known subtotal")
                    if session.unpricedQuantity > 0 { Text("\(session.unpricedQuantity) unpriced").foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("Recent Sessions")
    }
}

struct ScanDestinationView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CardList.createdAt, order: .reverse) var lists: [CardList]
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        List {
            Section("Choose a scanning list") {
                ForEach(lists) { list in NavigationLink(list.name) { ScannerView(list: list) } }
            }
            Section("Create a list") {
                TextField("List name", text: $name)
                Button("Create List") {
                    let list = CardList(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                    context.insert(list)
                    do { try context.save(); name = "" } catch { context.rollback(); self.error = error.localizedDescription }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.navigationTitle("Scan into…").failureAlert($error)
    }
}
