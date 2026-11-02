import SwiftUI
import SwiftData

/// Explicitly refreshed source snapshot, separate from Show's local working stock.
@MainActor struct CardShowInventoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var lists: [CardList]
    @State private var model: CardShowInventoryModel
    @State private var visible = false
    @State private var showingConnection = false
    @State private var copyMessage: String?
    @State private var removingSnapshot = false
    @State private var removalError: String?

    init(provider: (any CardShowInventoryProviding)? = nil) {
        _model = State(initialValue: CardShowInventoryModel(provider: provider))
    }

    private var savedList: CardList? { lists.first { $0.isCardShowInventory } }

    var body: some View {
        List {
            Section {
                Label("Imported source snapshot", systemImage: "arrow.down.doc.fill")
                    .font(.title3.bold()).foregroundStyle(.indigo)
                Text("TCGTracking · Card Show location")
                    .font(.caption).foregroundStyle(.secondary)
                if let list = savedList {
                    LabeledContent("Cards", value: list.quantity.formatted()).accessibilityIdentifier("cardShowInventory.quantity")
                    LabeledContent("Inventory rows", value: list.cards.count.formatted()).accessibilityIdentifier("cardShowInventory.rows")
                    LabeledContent("Imported market subtotal", value: list.knownValue.money)
                    if list.unpricedQuantity > 0 {
                        Text("\(list.unpricedQuantity) copies have no market price.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let link = list.cardShowInventory {
                        Text("Saved on this iPhone · Updated \(link.refreshedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("cardShowInventory.updated")
                    }
                    NavigationLink { CardListView(list: list) } label: {
                        Label("Open Imported Snapshot", systemImage: "rectangle.stack")
                    }.accessibilityIdentifier("cardShowInventory.open")
                    Button("Make an Editable Copy", systemImage: "doc.on.doc") { duplicate(list) }
                        .buttonStyle(.borderless).disabled(model.isRefreshing).accessibilityIdentifier("cardShowInventory.copy")
                    if let copyMessage { Text(copyMessage).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Import your TCGTracking Card Show location to start local show stock. This saved snapshot also stays available when reception is poor.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    copyMessage = nil; model.refresh(context: context)
                } label: {
                    Label(savedList == nil ? "Import Source Snapshot" : "Refresh Source Snapshot", systemImage: "arrow.clockwise")
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
                Text("Refresh updates this source snapshot only. Local show stock starts from the first import once; later refreshes do not restock sold cards or remove cards you bought locally. Record sales, trades, and purchases from Show home. The saved snapshot works offline; artwork and new research may need internet.")
            }
        }
        .navigationTitle("Card Show Inventory").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if savedList != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Remove Imported Snapshot", systemImage: "trash", role: .destructive) { removingSnapshot = true }
                            .disabled(model.isRefreshing)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Snapshot options")
                }
            }
        }
        .confirmationDialog("Remove the imported snapshot?", isPresented: $removingSnapshot, titleVisibility: .visible) {
            Button("Remove Snapshot", role: .destructive) {
                guard let savedList else { return }
                do { _ = try ListBulkDeletionService.delete(ids: [savedList.id], context: context) }
                catch { removalError = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your local working stock, transactions and budget are kept. Website inventory is unchanged.") }
        .failureAlert($removalError)
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
