import SwiftUI

/// Top-level, read-only research entry. Search uses the downloaded catalog and
/// never creates a list, adds inventory or starts a camera.
struct ResearchHubView: View {
    @AppStorage("defaultGame") private var game = "Pokémon"
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var search: ManualCardSearchModel
    @State private var selectedCard: CardCandidate?
    @State private var isVisible = false
    private let onOpenScan: (() -> Void)?
    private let openSettings: (() -> Void)?

    init(onOpenScan: (() -> Void)? = nil, openSettings: (() -> Void)? = nil) {
        self.onOpenScan = onOpenScan
        self.openSettings = openSettings
        let savedGame = UserDefaults.standard.string(forKey: "defaultGame") ?? "Pokémon"
        _search = State(initialValue: ManualCardSearchModel(
            game: CatalogOptions.games.contains(savedGame) ? savedGame : "Pokémon"))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Prices, sales and graded cards — all in one place.")
                    .font(.subheadline).foregroundStyle(.secondary)
                findCardPanel
                slabEntry
                searchContent
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Research")
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(item: $selectedCard) { card in
            ResearchCardSelectionView(card: card)
        }
        .onAppear {
            isVisible = true
            if !CatalogOptions.games.contains(game) { game = search.game }
            if search.game != game { search.changeGame(game) }
            else if !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { search.load() }
        }
        .onDisappear { isVisible = false; search.cancel() }
        .onChange(of: game) { _, game in if isVisible { search.changeGame(game) } }
    }

    private var findCardPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.title3.weight(.semibold)).foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find a Card").font(.title3.bold())
                    Text("Search by name, number or set.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Picker("Game", selection: $game) {
                ForEach(CatalogOptions.games, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu).accessibilityIdentifier("researchHub.game")
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Name, number or set", text: Binding(get: { search.query }, set: { search.updateQuery($0) }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).accessibilityIdentifier("researchHub.search")
                if !search.query.isEmpty {
                    Button { search.updateQuery("") } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.accessibilityLabel("Clear card search")
                }
            }
            .padding(12).background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .researchHubPanel()
    }

    private var slabEntry: some View {
        NavigationLink { PSAResearchFlow() } label: {
            HStack(spacing: 14) {
                Image(systemName: "barcode.viewfinder")
                    .font(.title2).foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Research a PSA Slab").font(.headline).foregroundStyle(.primary)
                    Text("Look up a certificate or find the card manually.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }.researchHubPanel()
        }.buttonStyle(.plain).accessibilityIdentifier("home.psaResearch")
    }

    @ViewBuilder private var searchContent: some View {
        if search.isSearching {
            HStack { Spacer(); ProgressView("Searching cards…"); Spacer() }
                .padding(.vertical, 12).accessibilityIdentifier("researchHub.searching")
        }
        if let error = search.error {
            VStack(alignment: .leading, spacing: 12) {
                Label("Catalog not ready", systemImage: "arrow.down.circle").font(.headline)
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                Text("Use Scan to download this game's catalog first. If it is already downloaded, refresh it in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    if let onOpenScan {
                        Button("Open Scan", action: onOpenScan).accessibilityIdentifier("researchHub.openScan")
                    }
                    Button("Retry Search") { search.load() }.disabled(search.isSearching)
                    if let openSettings {
                        Button("Open Settings", action: openSettings).accessibilityIdentifier("researchHub.openSettings")
                    }
                }.font(.subheadline.weight(.semibold))
            }.researchHubPanel().accessibilityIdentifier("researchHub.catalogStatus")
        } else if !search.results.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Closest matches").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
                                         count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 14) {
                    ForEach(search.results) { card in
                        Button { selectedCard = card } label: { ResearchSearchTile(card: card) }
                            .buttonStyle(.plain).disabled(search.isSearching)
                            .accessibilityIdentifier("researchHub.result." + card.identity.productID)
                    }
                }
            }
        } else if !search.isSearching && !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView("No matching cards", systemImage: "magnifyingglass",
                                   description: Text("Try a name first, then add a card number or set to narrow the results."))
        } else if !search.isSearching {
            VStack(alignment: .leading, spacing: 8) {
                Label("Start with a name", systemImage: "text.magnifyingglass").font(.headline)
                Text("Type Darkrai, then add a number such as 99. Up to five artwork previews help you choose the right card.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Search uses your downloaded catalog. Artwork, prices and sales data may need internet.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 8)
        }
    }
}

private struct ResearchSearchTile: View {
    let card: CardCandidate
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ResearchHubArtwork(url: card.imageURL)
                .aspectRatio(5.0 / 7.0, contentMode: .fit)
            Text(card.name).font(.headline).foregroundStyle(.primary)
            Text(card.set).font(.caption).foregroundStyle(.secondary)
            Text(card.number).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}

/// A research draft has no persistence action. A new card always begins at NM;
/// inherited snapshot prices/SKUs cannot become its selected-condition quote.
private struct ResearchCardSelectionView: View {
    @State private var pricing: CardEditorPricingModel
    init(card: CardCandidate) {
        var draft = card
        draft.identity.condition = "Near Mint"
        draft.identity.skuID = nil; draft.marketPrice = nil; draft.marketPriceMetadata = nil
        _pricing = State(initialValue: CardEditorPricingModel(card: draft, pricing: OpenAPIMarketPricing.shared,
                                                            manualPriceAllowed: false))
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    ResearchHubArtwork(url: pricing.card.imageURL).frame(width: 100, height: 140)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pricing.card.name).font(.headline)
                        Text(pricing.card.set).font(.subheadline).foregroundStyle(.secondary)
                        Text(pricing.card.number).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
            Section("Your card") {
                Picker("Printing", selection: identityBinding(\.printing)) {
                    ForEach(Array(Set(pricing.card.printings + [pricing.card.identity.printing])).sorted(), id: \.self) {
                        Text($0).tag($0)
                    }
                }.pickerStyle(.menu).accessibilityIdentifier("researchHub.printing")
                Picker("Condition", selection: identityBinding(\.condition)) {
                    ForEach(CatalogOptions.conditions, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("researchHub.condition")
                LabeledContent("Language", value: pricing.card.identity.language)
            }
            Section {
                NavigationLink { MarketInsightsView(card: pricing.card) } label: {
                    Label("Market Details & Sales", systemImage: "chart.xyaxis.line")
                }.accessibilityIdentifier("researchHub.marketDetails")
                NavigationLink { ResearchView(card: pricing.card) } label: {
                    Label("Graded Research", systemImage: "seal")
                }.accessibilityIdentifier("researchHub.gradedResearch")
            } footer: {
                Text("Market Details uses the selected printing, condition and language. Choose a grader and grade in Graded Research. Browsing does not add cards or change your lists.")
            }
        }
        .navigationTitle("Card Research").navigationBarTitleDisplayMode(.inline)
        .onAppear { pricing.loadPrintingOptions() }
        .onDisappear { pricing.cancelLookup() }
    }

    private func identityBinding(_ keyPath: WritableKeyPath<CardIdentity, String>) -> Binding<String> {
        Binding(get: { pricing.card.identity[keyPath: keyPath] }, set: { value in
            pricing.changeIdentity { $0[keyPath: keyPath] = value }
        })
    }
}

private struct ResearchHubArtwork: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    .overlay { Image(systemName: "rectangle.portrait").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
    }
}

private extension View {
    func researchHubPanel() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
