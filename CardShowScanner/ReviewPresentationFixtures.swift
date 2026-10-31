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
        for index in 1...2 {
            let card = CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "mock:review:\(index)", printing: "Normal"),
                name: "Synthetic card \(index)", set: "Synthetic test set", number: String(index),
                marketPrice: index == 1 ? 25 : 15, confidence: 100, printings: ["Normal"])
            try! CardListService.add(card, to: list, context: context)
            session.record(card)
        }
        try! context.save()
    }
}
#endif
