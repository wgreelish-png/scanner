import SwiftUI
import SwiftData

/// Refresh is explicit. The dedicated SwiftData list is available immediately,
/// including when the website or the phone's connection is unavailable.
@MainActor struct CardShowInventoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var lists: [CardList]
    @State private var model: CardShowInventoryModel
    @State private var visible = false
    @State private var showingConnection = false
    @State private var copyMessage: String?

    init(provider: (any CardShowInventoryProviding)? = nil) {
        _model = State(initialValue: CardShowInventoryModel(provider: provider))
    }

    private var savedList: CardList? { lists.first { $0.isCardShowInventory } }

    var body: some View {
        List {
            Section {
                Label("Your show inventory", systemImage: "shippingbox.fill")
                    .font(.title3.bold()).foregroundStyle(.indigo)
                if let list = savedList {
                    LabeledContent("Cards", value: list.quantity.formatted()).accessibilityIdentifier("cardShowInventory.quantity")
                    LabeledContent("Inventory rows", value: list.cards.count.formatted()).accessibilityIdentifier("cardShowInventory.rows")
                    LabeledContent("Known market subtotal", value: list.knownValue.money)
                    if list.unpricedQuantity > 0 {
                        Text("\(list.unpricedQuantity) copies have no market price.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let link = list.cardShowInventory {
                        Text("Saved on this iPhone · Updated \(link.refreshedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("cardShowInventory.updated")
                    }
                    NavigationLink { CardListView(list: list) } label: {
                        Label("Open Saved Inventory", systemImage: "rectangle.stack")
                    }.accessibilityIdentifier("cardShowInventory.open")
                    Button("Make an Editable Copy", systemImage: "doc.on.doc") { duplicate(list) }
                        .buttonStyle(.borderless).disabled(model.isRefreshing).accessibilityIdentifier("cardShowInventory.copy")
                    if let copyMessage { Text(copyMessage).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Import the cards from your TCGTracking Card Show location. The saved list stays available when reception is poor.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    copyMessage = nil; model.refresh(context: context)
                } label: {
                    Label(savedList == nil ? "Import Inventory" : "Refresh Inventory", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).disabled(model.isRefreshing)
                    .accessibilityIdentifier("cardShowInventory.refresh")
                if model.isRefreshing {
                    ProgressView("Downloading complete inventory…").accessibilityIdentifier("cardShowInventory.loading")
                }
                if let message = model.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("cardShowInventory.status")
                }
                Button {
                    model.setActive(false); showingConnection = true
                } label: {
                    Label(model.needsSignIn ? "Sign In to TCGTracking" : "TCGTracking Account", systemImage: "person.crop.circle")
                }.buttonStyle(.borderless).disabled(model.isRefreshing).accessibilityIdentifier("cardShowInventory.connect")
            } footer: {
                Text("Refresh updates this saved copy from the Card Show location. Use an editable copy for local scanning or corrections. Saved card details, quantities and last imported values work offline; artwork and new research may need internet.")
            }
        }
        .navigationTitle("Card Show Inventory").navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingConnection, onDismiss: {
            visible = true; model.setActive(scenePhase == .active)
            if scenePhase == .active { model.refresh(context: context) }
        }) {
            TCGTrackingConnectionView(continueTitle: "Return to Inventory") { showingConnection = false }
        }
        .onAppear { visible = true; model.setActive(scenePhase == .active && !showingConnection) }
        .onDisappear { visible = false; model.setActive(false) }
        .onChange(of: scenePhase) { _, phase in model.setActive(visible && !showingConnection && phase == .active) }
    }

    private func duplicate(_ list: CardList) {
        do {
            try CardListService.duplicate(list, context: context)
            copyMessage = "Editable copy saved in My Lists."
        } catch {
            context.rollback(); copyMessage = "The copy could not be saved. Your imported inventory is kept; try again."
        }
    }
}

#if DEBUG
/// Explicit synthetic inventory UI destination, never a live-network fallback.
@MainActor struct CardShowInventoryFixtureScreen: View {
    @State private var container: ModelContainer
    private let provider = CardShowInventoryFixtureProvider()
    init() {
        _container = State(initialValue: try! ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }
    var body: some View {
        NavigationStack { CardShowInventoryView(provider: provider) }.modelContainer(container)
    }
}

@MainActor private final class CardShowInventoryFixtureProvider: CardShowInventoryProviding {
    private var count = 0
    func fetch(expectedLocationID: Int?) async throws -> CardShowInventorySnapshot {
        try Task.checkCancellation(); count += 1
        let card = CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:42", skuID: "100", printing: "Holofoil"),
            name: "Synthetic show inventory", set: "Synthetic test set", number: "42", marketPrice: 10,
            confidence: 100, printings: ["Holofoil"])
        return CardShowInventorySnapshot(location: .init(id: 9001, name: "Card Show"),
            rows: [.init(inventoryID: 7001, card: card, quantity: count == 1 ? 2 : 3)], fetchedAt: .now)
    }
    func cancel() {}
}
#endif
