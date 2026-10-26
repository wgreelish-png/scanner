import SwiftUI
import SwiftData

private struct ManualSearchSelection: Identifiable {
    let id = UUID()
    let card: CardCandidate
}

struct ManualCardSearchView: View {
    let list: CardList
    let allowsGameChange: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: ManualCardSearchModel
    @State private var selection: ManualSearchSelection?
    @State private var lastAdded: String?
    init(list: CardList, game: String, allowsGameChange: Bool) {
        self.list = list; self.allowsGameChange = allowsGameChange
        _model = State(initialValue: ManualCardSearchModel(game: CatalogOptions.games.contains(game) ? game : "Pokémon"))
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if allowsGameChange && list.cards.isEmpty {
                        Picker("Game", selection: Binding(get: { model.game }, set: { model.changeGame($0) })) {
                            ForEach(CatalogOptions.games, id: \.self) { Text($0) }
                        }
                    }
                    TextField("Name, card number or set", text: Binding(get: { model.query }, set: { model.updateQuery($0) }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("catalog.query")
                    Text("Search saved \(model.game) cards. Add a number or set to narrow the five closest matches.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let lastAdded { Label("Added \(lastAdded)", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.green) }
                }
                if model.isSearching {
                    ProgressView(model.query.isEmpty ? "Opening saved catalog…" : "Searching…")
                }
                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(.secondary)
                        Button("Retry Search") { model.load() }.disabled(model.isSearching)
                    }
                } else if !model.isSearching && !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.results.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass", description: Text("Try the card name, its number, or its set."))
                }
                if !model.results.isEmpty {
                    Section("Closest matches") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 16) {
                            ForEach(model.results) { card in
                                Button { selection = ManualSearchSelection(card: card) } label: { CatalogSearchTile(card: card) }
                                    .buttonStyle(.plain).disabled(model.isSearching).accessibilityIdentifier("catalog.result." + card.identity.productID)
                            }
                        }
                    }
                }
            }.navigationTitle("Search & Add").navigationBarTitleDisplayMode(.inline)
                .scrollDismissesKeyboard(.interactively)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .sheet(item: $selection) { selected in
                    ManualCardConfirmationView(card: selected.card, list: list) { card in
                        lastAdded = card.name; selection = nil
                    }
                }
                .task { model.load() }
                .onDisappear { model.cancel() }
        }
    }
}

private struct CatalogSearchTile: View {
    let card: CardCandidate
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            AsyncImage(url: card.imageURL) { phase in
                if let image = phase.image { image.resizable().scaledToFit() }
                else { Image(systemName: "rectangle.portrait").resizable().scaledToFit().padding(24).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity).aspectRatio(5.0 / 7.0, contentMode: .fit)
                .background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
            Text(card.name).font(.headline).foregroundStyle(.primary)
            Text(card.set).font(.caption).foregroundStyle(.secondary)
            Text(card.number).font(.caption.bold()).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .topLeading).contentShape(Rectangle())
    }
}

private struct CatalogCardPreview: View {
    let card: CardCandidate
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: card.imageURL) { phase in
                if let image = phase.image { image.resizable().scaledToFit() }
                else { Image(systemName: "rectangle.portrait").resizable().scaledToFit().padding(16).foregroundStyle(.secondary) }
            }.frame(width: 76, height: 106).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(card.name).font(.headline).foregroundStyle(.primary)
                Text(card.set).font(.subheadline).foregroundStyle(.secondary)
                Text(card.number).font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }
}

private struct ManualCardConfirmationView: View {
    let list: CardList
    let onAdded: (CardCandidate) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var model: ManualCardAddModel
    @State private var showingConnection = false
    @State private var hasRequestedPrice = false
    init(card: CardCandidate, list: CardList, onAdded: @escaping (CardCandidate) -> Void) {
        self.list = list; self.onAdded = onAdded; _model = State(initialValue: ManualCardAddModel(card: card))
    }
    private var validPrinting: Bool {
        model.pricing.card.printings.isEmpty || model.pricing.card.printings.contains(model.pricing.card.identity.printing)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { CatalogCardPreview(card: model.pricing.card) }
                Section("Printing & condition") {
                    Picker("Type / printing", selection: identityBinding(\.printing)) {
                        ForEach(Array(Set(model.pricing.card.printings + [model.pricing.card.identity.printing])).sorted(), id: \.self) { Text($0) }
                    }.pickerStyle(.menu)
                    Picker("Condition", selection: identityBinding(\.condition)) {
                        ForEach(CatalogOptions.conditions, id: \.self) { Text($0) }
                    }
                    if !validPrinting { Text("Choose a printing returned for this card.").foregroundStyle(.orange) }
                    LabeledContent("Market value", value: model.pricing.priceLoading ? "Checking…" : (model.pricing.card.marketPrice?.money ?? "Price unavailable"))
                    if let message = model.pricing.priceMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Button("Retry Market Price") { model.pricing.refreshPrice() }.disabled(model.pricing.priceLoading)
                    if model.pricing.priceConnectionRequired {
                        Button("Connect TCGTracking") { model.pricing.cancelLookup(); showingConnection = true }
                    }
                    Text("Prices require internet. If no quote is available, you can add the card without a market value.").font(.caption).foregroundStyle(.secondary)
                }.disabled(model.isSaving || model.isSaved)
                if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button("Add to List", systemImage: "plus.circle.fill") { add() }
                        .disabled(model.isSaving || model.isSaved || model.pricing.priceLoading || !validPrinting)
                        .accessibilityIdentifier("catalog.confirmAdd")
                    Text("Adds one physical card as a new row at the end of this list.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Confirm Card").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.isSaving) } }
                .task {
                    guard !hasRequestedPrice else { return }
                    hasRequestedPrice = true; model.pricing.refreshPrice()
                }
                .onDisappear { model.pricing.cancelLookup() }
                .confirmationDialog("Finish the other active session?", isPresented: $model.needsSessionSwitch) {
                    Button("Finish & Add to This List") { add(finishingOtherSession: true) }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Its list and saved offers will be kept. This card will be added to \(list.name).") }
                .fullScreenCover(isPresented: $showingConnection, onDismiss: { model.pricing.refreshPrice() }) {
                    TCGTrackingConnectionView(continueTitle: "Return to Card") {
                        guard showingConnection else { return }
                        OnlineMarketPricing.connectionDidChange(); showingConnection = false
                    }
                }
        }
    }
    private func identityBinding(_ keyPath: WritableKeyPath<CardIdentity, String>) -> Binding<String> {
        Binding(get: { model.pricing.card.identity[keyPath: keyPath] }, set: { value in
            model.pricing.changeIdentity { $0[keyPath: keyPath] = value }
        })
    }
    private func add(finishingOtherSession: Bool = false) {
        if model.add(to: list, context: context, finishingOtherSession: finishingOtherSession) { onAdded(model.pricing.card) }
    }
}
