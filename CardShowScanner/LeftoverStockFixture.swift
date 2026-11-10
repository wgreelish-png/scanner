#if DEBUG
import SwiftUI
import SwiftData

/// Synthetic, memory-only destination for the focused reconciliation UI test.
@MainActor struct LeftoverStockFixtureScreen: View {
    @State private var model: LeftoverStockModel
    @State private var container: ModelContainer
    @State private var exportResult = "Not exported"
    private let inventoryID: UUID
    private let originalInventory: Data

    init() {
        let container = try! ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let disk = LeftoverFixtureDisk()
        let store = LeftoverStockStore(read: { _ in disk.data }, write: { data, _ in disk.data = data })
        func card(_ product: String, sku: String, name: String) -> CardCandidate {
            .init(identity: .init(game: "Pokémon", productID: product, skuID: sku, printing: "Holofoil"),
                  name: name, set: "Synthetic set", number: product, confidence: 100, printings: ["Holofoil"])
        }
        let remaining = card("p:42", sku: "4200", name: "Counted fixture card")
        let absent = card("p:43", sku: "4300", name: "Not counted fixture card")
        let extra = card("p:44", sku: "4400", name: "Extra fixture card")
        let baseline = LeftoverStockBaseline(location: .init(id: 9001, name: "Card Show"), fetchedAt: .now,
            rows: [.init(inventoryID: 7001, card: remaining, quantity: 5), .init(inventoryID: 7002, card: absent, quantity: 3)])
        let session = try! store.start(baseline: baseline)
        let count = CardList(name: "Synthetic leftover count")
        container.mainContext.insert(count)
        for (candidate, quantity) in [(remaining, 2), (extra, 1)] {
            let row = try! InventoryCard(card: candidate, quantity: quantity)
            container.mainContext.insert(row); count.cards.append(row)
        }
        let inventory = CardList(name: "Existing inventory sentinel")
        container.mainContext.insert(inventory)
        let sentinel = try! InventoryCard(card: absent, quantity: 9)
        container.mainContext.insert(sentinel); inventory.cards.append(sentinel)
        try! container.mainContext.save()
        try! store.addCountList(id: count.id, sessionID: session.id)
        inventoryID = inventory.id; originalInventory = sentinel.data
        let model = LeftoverStockModel(store: store, provider: LeftoverFixtureProvider())
        model.refresh(context: container.mainContext)
        _container = State(initialValue: container); _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            LeftoverStockView(model: model)
                .safeAreaInset(edge: .top) {
                    HStack {
                        Text(exportResult).font(.caption).accessibilityIdentifier("leftoverFixture.result")
                        Button("Verify Export Contents") { verifyExport() }
                            .disabled(!model.canExportReplacement)
                            .accessibilityIdentifier("leftoverFixture.verifyExport")
                    }.padding(8).background(.regularMaterial)
                }
        }.modelContainer(container)
    }

    private func verifyExport() {
        do {
            let context = container.mainContext
            let csv = try model.replacementCSV(context: context)
            let comparison = try model.comparisonCSV(context: context)
            let list = try context.fetch(FetchDescriptor<CardList>()).first { $0.id == inventoryID }
            let inventoryKept = list?.quantity == 9 && list?.cards.count == 1 && list?.cards.first?.data == originalInventory
            let lines = csv.split(whereSeparator: \.isNewline)
            let validCSV = lines.count == 3 && csv.contains("4200") && csv.contains("4400") && !csv.contains("4300")
                && csv.contains("\"2\"") && csv.contains("\"1\"") && comparison.contains("4300")
            exportResult = validCSV && inventoryKept ? "2 export rows · 3 cards · Inventory unchanged" : "Export validation failed"
        } catch { exportResult = "Export validation failed" }
    }
}

@MainActor private final class LeftoverFixtureDisk { var data: Data? }
@MainActor private final class LeftoverFixtureProvider: CardShowInventoryProviding {
    func fetch(expectedLocationID: Int?) async throws -> CardShowInventorySnapshot { throw CardShowInventoryFailure.invalidResponse }
    func cancel() {}
}
#endif
