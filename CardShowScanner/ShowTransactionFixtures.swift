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
            var inventory: [ShowInventorySeed] = [
                .init(sourceInventoryID: 1, card: Self.card("Stock A", price: 35), quantity: 2),
                .init(sourceInventoryID: 2, card: Self.card("Stock B", price: 5), quantity: 1)
            ]
            if ProcessInfo.processInfo.arguments.contains("--inventory-bulk-labels-fixture") {
                inventory.append(.init(sourceInventoryID: 3,
                    card: Self.card("Bulk Stock", price: Decimal(string: "0.50")!), quantity: 1))
            }
            if ProcessInfo.processInfo.arguments.contains("--inventory-write-in-labels-fixture") {
                inventory.append(.init(sourceInventoryID: 4, card: Self.card("Unavailable Stock", price: nil), quantity: 1))
                inventory.append(.init(sourceInventoryID: 5, card: Self.card("Zero Stock", price: 0), quantity: 1))
            }
            if ProcessInfo.processInfo.arguments.contains("--inventory-games-fixture") {
                inventory.append(.init(sourceInventoryID: 6,
                    card: Self.card("YGO Stock", price: 10, game: "Yu-Gi-Oh!"), quantity: 2))
                inventory.append(.init(sourceInventoryID: 7,
                    card: Self.card("Magic Stock", price: 20, game: "Magic: The Gathering"), quantity: 1))
            }
            try! store.seedInventory(inventory, sourceLocationID: 9001)
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
            // Seed only the prerequisite for a focused UI scenario. The purchase,
            // sale and undo controls each have their own test; every receipt and
            // balance here is produced by the same durable APIs as those controls.
            // Staying inside the empty-fixture branch preserves edits on relaunch.
            if ProcessInfo.processInfo.arguments.contains("--show-cost-profit-ui-fixture"),
               let stage = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--show-cost-profit-stage=") }),
               let list = try! context.fetch(FetchDescriptor<CardList>()).first(where: { $0.name == "Profit Example" }),
               let showID = store.activeShow?.id {
                let purchased = "--show-cost-profit-stage=purchased", sold = "--show-cost-profit-stage=sold"
                precondition(stage == purchased || stage == sold, "Unknown cost/profit fixture stage")
                let snapshot = try! ShowTransactionListService.incomingSnapshot(for: list, kind: .purchase, context: context)
                let purchase = try! ShowTransactionListService.record(.init(kind: .purchase,
                    incomingListID: snapshot.listID, incomingListName: snapshot.name, incoming: snapshot.cards,
                    incomingValueCents: 700), showID: showID, context: context, store: store)
                if stage == sold {
                    _ = try! store.recordTransaction(.init(kind: .sale,
                        outgoing: [.init(inventoryID: purchase.incoming[0].inventoryID, quantity: 1)],
                        saleReceivedCents: 1_000), showID: showID)
                }
            }
        }
    }
    private static func card(_ name: String, price: Decimal?, game: String = "Pokémon") -> CardCandidate {
        CardCandidate(identity: .init(game: game, productID: "mock:" + name, printing: "Normal"),
            name: name, set: "Synthetic set", number: "1", marketPrice: price,
            confidence: 100, printings: ["Normal"])
    }
}
#endif
