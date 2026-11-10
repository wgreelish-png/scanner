#if DEBUG
import SwiftUI
import SwiftData

/// Explicit UI-test screen; it owns an isolated store and synthetic card values.
/// Opening this fixture never starts capture or uses a production account.
@MainActor struct ReviewPresentationFixtureScreen: View {
    @State private var fixture: ReviewPresentationFixtureStore

    init() {
        _fixture = State(initialValue: ReviewPresentationFixtureStore())
    }

    var body: some View {
        NavigationStack {
            CardListView(list: fixture.list, session: fixture.session)
        }.modelContainer(fixture.container)
    }
}

@MainActor private final class ReviewPresentationFixtureStore {
    let container: ModelContainer
    let list: CardList
    let session: ScanSession

    init() {
        container = try! ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        list = CardList(name: "Synthetic review fixture")
        session = ScanSession(listName: list.name)
        session.listID = list.id; session.game = "Pokémon"; session.statusRaw = "active"
        session.setRates(OfferRates(cash: 70, trade: 80, maximum: 75))
        let context = container.mainContext
        context.insert(list); context.insert(session)
        let count = ProcessInfo.processInfo.arguments.contains("--uitest-long-review") ? 80 : 2
        for index in 1...count {
            let card = CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "mock:review:\(index)", printing: "Normal"),
                name: "Synthetic card \(index)", set: "Synthetic test set", number: String(index),
                marketPrice: index == 1 ? 25 : index == 2 ? 15 : 0, confidence: 100, printings: ["Normal"])
            try! CardListService.add(card, to: list, context: context)
            session.record(card)
        }
        try! context.save()
    }
}

/// Exercises both manual-add sheets against the real save path without network.
@MainActor struct ManualCardAddFixtureScreen: View {
    @State private var fixture = ManualCardAddFixtureStore()
    @State private var showingSearch = false
    @State private var savedRows = 0

    var body: some View {
        NavigationStack {
            List {
                Text("Cards: \(fixture.list.quantity)").accessibilityIdentifier("manualAdd.quantity")
                Text("Saved rows: \(savedRows)").accessibilityIdentifier("manualAdd.savedRows")
                Button("Search & Add") { showingSearch = true }
                    .accessibilityIdentifier("manualAdd.open")
                ForEach(fixture.list.orderedCards) { row in
                    Text(row.snapshot.name).accessibilityIdentifier("manualAdd.card")
                }
            }.navigationTitle("Manual Add Fixture")
                .sheet(isPresented: $showingSearch) {
                    ManualCardSearchView(list: fixture.list, game: "Pokémon", allowsGameChange: false,
                        catalog: ManualAddFixtureCatalog(), pricing: ManualAddFixturePricing())
                }
                .onChange(of: showingSearch) { _, presented in
                    if !presented { savedRows = fixture.savedRowCount() }
                }
        }.modelContainer(fixture.container)
    }
}

@MainActor private final class ManualCardAddFixtureStore {
    let container: ModelContainer
    let list: CardList

    init() {
        container = try! ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        list = CardList(name: "Manual add fixture")
        container.mainContext.insert(list)
        try! container.mainContext.save()
    }

    func savedRowCount() -> Int {
        // A fresh context verifies that Add committed, rather than only appending
        // an unsaved row to the relationship visible in the presenting screen.
        (try? ModelContext(container).fetchCount(FetchDescriptor<InventoryCard>())) ?? -1
    }
}

private struct ManualAddFixtureCatalog: CardCatalogSearching {
    func search(_ query: String, game: String, limit: Int) async throws -> [CardCandidate] {
        try Task.checkCancellation()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "mock:manual-add:1", printing: "Normal"),
            name: "Synthetic manual card", set: "Synthetic test set", number: "1", confidence: 100, printings: ["Normal"])]
    }
}

private struct ManualAddFixturePricing: MarketPricing {
    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        try Task.checkCancellation()
        return MarketQuote(marketPrice: 12, skuID: "manual-add-1")
    }
}

/// Exercises the scanner's recent-card drawer without camera or timer races.
@MainActor struct ScannerRecentCardsFixtureScreen: View {
    @State private var fixture = ScannerRecentCardsFixtureStore()

    var body: some View {
        NavigationStack {
            ScannerView(session: fixture.session, list: fixture.list, model: fixture.model)
        }.modelContainer(fixture.container)
    }
}

@MainActor private final class ScannerRecentCardsFixtureStore {
    let container: ModelContainer
    let list: CardList
    let session: ScanSession
    let model: ScannerViewModel

    init() {
        container = try! ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        list = CardList(name: "Scanner recent-card fixture")
        session = ScanSession(listName: list.name)
        session.listID = list.id; session.game = "Pokémon"; session.statusRaw = "active"
        let context = container.mainContext
        context.insert(list); context.insert(session)
        for index in 1...3 {
            let card = CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "mock:scanner-recent:\(index)", printing: "Normal"),
                name: "Synthetic scan \(index)", set: "Synthetic scan set", number: String(index),
                marketPrice: Decimal(index * 10), confidence: 100, printings: ["Normal"])
            let row = try! InventoryCard(card: card)
            row.id = UUID(uuidString: "20000000-0000-0000-0000-00000000000\(index)")!
            row.addedAt = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            context.insert(row); list.cards.append(row); session.record(card)
        }
        try! context.save()
        model = ScannerViewModel(provider: MockScannerProvider())
        model.paused = true
    }
}

/// Runs the real five-tab shell against synthetic, in-memory lists. Its source
/// marker is acknowledged so merely visiting Show cannot seed financial stock.
@MainActor struct PersistentNavigationFixtureScreen: View {
    @State private var fixture = PersistentNavigationFixtureStore()

    var body: some View {
        HomeView().modelContainer(fixture.container)
    }
}

@MainActor private final class PersistentNavigationFixtureStore {
    let container: ModelContainer

    init() {
        container = try! ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let editable = CardList(name: "Navigation Test List")
        context.insert(editable)
        let editableCard = CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "mock:navigation:editable", printing: "Normal"),
            name: "Navigation Draft Card", set: "Synthetic navigation set", number: "1", marketPrice: 25,
            confidence: 100, printings: ["Normal"])
        let editableRow = try! InventoryCard(card: editableCard)
        editableRow.id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        context.insert(editableRow); editable.cards.append(editableRow)

        let imported = CardList(name: "Card Show")
        context.insert(imported)
        let importedCard = CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "mock:navigation:imported", printing: "Holofoil"),
            name: "Navigation Imported Card", set: "Synthetic navigation set", number: "2", marketPrice: 10,
            confidence: 100, printings: ["Holofoil"])
        let importedRow = try! InventoryCard(card: importedCard, quantity: 2)
        importedRow.id = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        importedRow.sourceInventoryID = 9_001
        context.insert(importedRow); imported.cards.append(importedRow)
        imported.inventorySourceData = try! JSONEncoder().encode(CardShowInventoryLink(locationID: 9_001,
            locationName: "Card Show", refreshedAt: Date(timeIntervalSince1970: 1_800_000_000),
            version: 2, syncID: UUID(), pendingWorkingSync: false))
        try! context.save()
    }
}
#endif
