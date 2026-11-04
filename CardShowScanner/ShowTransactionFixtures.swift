#if DEBUG
import SwiftUI
import SwiftData

/// Explicit, isolated UI-test data. No camera, website or provider request runs.
@MainActor struct ShowTransactionFixtureScreen: View {
    @State private var fixture: ShowTransactionFixtureStore
    init() { _fixture = State(initialValue: ShowTransactionFixtureStore()) }
    var body: some View {
        NavigationStack {
            ShowHomeView(store: fixture.store)
                .toolbar {
                    if ProcessInfo.processInfo.arguments.contains("--show-offer-checkout-fixture"),
                       let list = fixture.offerList {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink("Review Offer") {
                                CardListView(list: list, transactionStore: fixture.store)
                            }.accessibilityIdentifier("showFixture.reviewOffer")
                        }
                    }
                }
        }.modelContainer(fixture.container)
    }
}

@MainActor private final class ShowTransactionFixtureStore {
    let container: ModelContainer
    let store: ShowBudgetStore
    var offerList: CardList? {
        (try? container.mainContext.fetch(FetchDescriptor<CardList>()))?.first { $0.name == "Trade 5" }
    }
    init() {
        let argument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--show-transactions-fixture-id=") }
        let token = argument.flatMap { UUID(uuidString: String($0.dropFirst("--show-transactions-fixture-id=".count))) } ?? UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShowTransactionsFixture-" + token.uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema([CardList.self, InventoryCard.self, ScanSession.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(url: directory.appendingPathComponent("scans.store"))])
        store = ShowBudgetStore(url: directory.appendingPathComponent("budget.json"))
        if store.book.shows.isEmpty { _ = try! store.create(name: "Synthetic show", startingCents: 30_000) }
        if store.inventorySourceLocationID == nil {
            try! store.seedInventory([
                .init(sourceInventoryID: 1, card: Self.card("Stock A", price: 35), quantity: 2),
                .init(sourceInventoryID: 2, card: Self.card("Stock B", price: 5), quantity: 1)
            ], sourceLocationID: 9001)
        }
        let context = container.mainContext
        if (try! context.fetchCount(FetchDescriptor<CardList>())) == 0 {
            for (name, price) in [("Trade 32", Decimal(40)), ("Trade 5", Decimal(string: "6.25")!),
                                  ("Trade 35", Decimal(string: "43.75")!), ("Buy 14", Decimal(20))] {
                let list = CardList(name: name), session = ScanSession(listName: name)
                session.listID = list.id; session.game = "Pokémon"
                session.setRates(OfferRates(cash: 70, trade: 80, maximum: 75))
                context.insert(list); context.insert(session)
                let row = try! InventoryCard(card: Self.card(name, price: price))
                context.insert(row); list.cards.append(row)
                if ProcessInfo.processInfo.arguments.contains("--show-transactions-large-incoming") {
                    for index in 1...79 {
                        let extra = try! InventoryCard(card: Self.card(name + " extra " + String(index), price: 0))
                        context.insert(extra); list.cards.append(extra)
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--show-cost-profit-ui-fixture") {
                let list = CardList(name: "Profit Example"), session = ScanSession(listName: "Profit Example")
                session.listID = list.id; session.game = "Pokémon"
                session.setRates(OfferRates(cash: 70, trade: 80, maximum: 75))
                context.insert(list); context.insert(session)
                let row = try! InventoryCard(card: Self.card("Profit Example", price: 10))
                context.insert(row); list.cards.append(row)
            }
            try! context.save()
        }
    }
    private static func card(_ name: String, price: Decimal) -> CardCandidate {
        CardCandidate(identity: .init(game: "Pokémon", productID: "mock:" + name, printing: "Normal"),
            name: name, set: "Synthetic set", number: "1", marketPrice: price,
            confidence: 100, printings: ["Normal"])
    }
}
#endif
