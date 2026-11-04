import SwiftUI

/// Saved-card actions remain explicit; research uses only a value copy.
enum CardResearchContext {
    case savedCard(InventoryCard)
    case importedCard(InventoryCard)
    case showInventory(UUID, ShowBudgetStore)

    var detailsTitle: String {
        switch self {
        case .savedCard: return "Edit Card"
        case .importedCard: return "Imported Card Details"
        case .showInventory: return "Inventory Details"
        }
    }
    var detailsIdentifier: String {
        switch self {
        case .savedCard: return "cardResearch.editCard"
        case .importedCard: return "cardResearch.importedDetails"
        case .showInventory: return "cardResearch.inventoryDetails"
        }
    }
    var detailsSymbol: String {
        switch self {
        case .savedCard: return "pencil"
        case .importedCard: return "info.circle"
        case .showInventory: return "shippingbox"
        }
    }
}

/// One shared card header and two read-only modes. Only explicit inventory Save
/// outside this page can commit a card or quote; research never applies values.
struct CardResearchView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var model: CardResearchModel
    @State private var visible = false
    @State private var showingInfo = false
    @State private var showingConnection = false
    @State private var showingCardDetails = false
    private let inputCard: CardCandidate
    private let cardContext: CardResearchContext?

    init(card: CardCandidate, initialSection: CardResearchSection = .market,
         grader: String = "PSA", grade: String = "",
         publicPricing: any MarketPricing = StandardMarketPricing(),
         opportunities: any OpportunitiesProviding = ConfiguredOpportunitiesProvider(),
         research: any ResearchProviding = ConfiguredResearchProvider(),
         context: CardResearchContext? = nil) {
        inputCard = card
        cardContext = context
        _model = State(initialValue: CardResearchModel(card: card, initialSection: initialSection,
            grader: grader, grade: grade, publicPricing: publicPricing, opportunities: opportunities, research: research))
    }

    var body: some View {
        List {
            Section {
                if textSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) { artwork; identity }
                } else {
                    HStack(alignment: .top, spacing: 14) { artwork; identity }
                }
                ResearchOptionButtons(title: "Printing", options: model.printings,
                    selection: model.card.requiresPrintingSelection == true ? "" : model.card.identity.printing,
                    accessibilityPrefix: "cardResearch.printing", onSelect: model.selectPrinting)
                ResearchOptionButtons(title: "Language", options: model.languages,
                    selection: model.card.identity.language,
                    accessibilityPrefix: "cardResearch.language", compactLanguageLabels: true,
                    onSelect: model.selectLanguage)
                if let url = MarketplaceLinks.tcgplayerProduct(model.card.identity.productID) {
                    Link(destination: url) {
                        Label("View Card on TCGplayer", systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(Color.white)
                            .background(Color.indigo, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityIdentifier("cardResearch.tcgplayer")
                        .accessibilityHint("Opens raw-card listings and sales history. Choose the matching printing and condition on TCGplayer.")
                }
            }.listRowBackground(Color.indigo.opacity(0.07))
            if model.section == .market {
                Section {
                    CardConditionPicker(selection: Binding(get: { model.card.identity.condition }, set: { model.selectCondition($0) }),
                                        accessibilityPrefix: "cardResearch.condition")
                }
            }
            if model.section == .market {
                MarketInsightsContent(model: model.market, window: $model.marketWindow)
            } else {
                GradedResearchContent(model: model.graded)
            }
        }
        .navigationTitle("Card Research").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .tabBar)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 7) {
                Picker("Research view", selection: Binding(get: { model.section }, set: { model.selectSection($0) })) {
                    ForEach(CardResearchSection.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("cardResearch.section")
                if let status = compactStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("cardResearch.updated")
                }
            }.padding(.horizontal).padding(.vertical, 8).background(.regularMaterial)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let cardContext, case .showInventory(let id, let store) = cardContext {
                ShowInventoryQuickSellAction(itemID: id, store: store)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel(model.section == .market ? "Refresh market details" : "Refresh graded research")
                    .accessibilityIdentifier("cardResearch.refresh")
                if let cardContext {
                    Menu {
                        Button { showingCardDetails = true } label: {
                            Label(cardContext.detailsTitle, systemImage: cardContext.detailsSymbol)
                        }.accessibilityIdentifier(cardContext.detailsIdentifier)
                        Divider()
                        Button("Research Data Information", systemImage: "info.circle") { showingInfo = true }
                            .accessibilityIdentifier("cardResearch.info")
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Card actions").accessibilityIdentifier("cardResearch.options")
                } else {
                    Button { showingInfo = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Research data information").accessibilityIdentifier("cardResearch.info")
                }
                Button { showingConnection = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("TCGTracking API Connection").accessibilityIdentifier("cardResearch.connection")
            }
        }
        .navigationDestination(isPresented: $showingConnection) { ResearchConnectionView() }
        .navigationDestination(isPresented: $showingCardDetails) {
            if let cardContext { cardDetails(cardContext) }
        }
        .onChange(of: showingConnection) { wasShowing, isShowing in
            if wasShowing && !isShowing { model.connectionDidChange() }
        }
        .sheet(isPresented: $showingInfo) { CardResearchInfoSheet(model: model) }
        .onAppear { visible = true; if scenePhase == .active { model.start() } }
        .onDisappear { visible = false; model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if visible && phase == .active { model.start() } else { model.stop() }
        }
        .onChange(of: inputCard.identity) { _, _ in model.changeCard(inputCard) }
    }

    @ViewBuilder private func cardDetails(_ context: CardResearchContext) -> some View {
        switch context {
        case .savedCard(let item): CardEditorView(item: item)
        case .importedCard(let item): CardShowInventoryCardView(item: item)
        case .showInventory(let id, let store): ShowWorkingInventoryDetailView(itemID: id, store: store)
        }
    }

    private var artwork: some View {
        AsyncImage(url: model.card.imageURL) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay { Image(systemName: "rectangle.portrait").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }.frame(width: 86, height: 120).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
    }
    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.card.name).font(.title3.bold()).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("cardResearch.name")
            Text(model.card.set).font(.subheadline).foregroundStyle(.secondary)
            Text(model.card.number.isEmpty ? model.card.identity.game : "#" + model.card.number + " · " + model.card.identity.game)
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var compactStatus: String? {
        if model.section == .graded {
            if let date = model.graded.details?.meta.generatedAt { return "Experimental · Updated " + ResearchDateLabel.compact(date) }
            return "Graded Research · Experimental"
        }
        guard let metadata = model.market.publicDetails?.metadata else { return nil }
        var parts: [String] = []
        if metadata.isOffline == true { parts.append("Offline cache") }
        else if metadata.isCached == true { parts.append("Cached") }
        if let date = metadata.updatedAt { parts.append("Updated " + date.formatted(date: .abbreviated, time: .omitted)) }
        else { parts.append("Checked " + metadata.fetchedAt.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }
}

/// Matches the condition control while giving longer option names room to wrap.
private struct ResearchOptionButtons: View {
    let title: String
    let options: [String]
    let selection: String
    let accessibilityPrefix: String
    var compactLanguageLabels = false
    let onSelect: (String) -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    private var visibleOptions: [String] { options.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    private var columns: Int {
        if textSize.isAccessibilitySize { return compactLanguageLabels ? 2 : 1 }
        return min(compactLanguageLabels ? 5 : 2, max(1, visibleOptions.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(compactLanguageLabels && !selection.isEmpty ? title + " · " + selection : title)
                .font(.subheadline).foregroundStyle(.secondary)
            if selection.isEmpty { Text("Choose \(title.lowercased())").font(.caption).foregroundStyle(.secondary) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 8) {
                ForEach(visibleOptions, id: \.self) { option in
                    Button { onSelect(option) } label: {
                        Text(displayLabel(option)).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selection == option ? Color.white : Color.primary)
                            .background(selection == option ? Color.indigo : Color.indigo.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(title): \(option)")
                        .accessibilityAddTraits(selection == option ? .isSelected : [])
                        .accessibilityIdentifier(accessibilityPrefix + "." + option)
                }
            }
        }.padding(.vertical, 3).accessibilityIdentifier(accessibilityPrefix)
    }

    private func displayLabel(_ value: String) -> String {
        guard compactLanguageLabels else { return value }
        return ["English": "EN", "Japanese": "JP", "French": "FR", "German": "DE", "Italian": "IT",
                "Spanish": "ES", "Portuguese": "PT", "Russian": "RU", "Korean": "KO",
                "Simplified Chinese": "CS", "Traditional Chinese": "CT"][value] ?? value
    }
}

private struct CardResearchInfoSheet: View {
    let model: CardResearchModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Selections on this page are for research. They do not save a card, apply a price or change offers.")
                    Text("All prices are USD. Missing data is unavailable; returned zeroes remain zero.")
                }
                if model.section == .market {
                    Section("Market data") {
                        Text("Current market prices use the public Open API for the selected printing, language and condition.")
                        if let metadata = model.market.publicDetails?.metadata {
                            LabeledContent("Price data updated", value: metadata.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable")
                            LabeledContent("Retrieved", value: metadata.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        Text("Asking prices and market quotes are separate from completed sales. Open API and Beta activity are both supplied by TCGTracking.")
                    }
                    Section("Optional sales activity") {
                        Text("Beta activity covers active opportunities. Missing coverage does not mean zero sales or stock. Reported period counts overlap and must not be added together.")
                        if let details = model.market.activityDetails {
                            LabeledContent("Data generated", value: details.meta.generatedAt.map(ResearchDateLabel.full) ?? "Unavailable")
                            if let date = details.sku.trends?.updatedAt { LabeledContent("Activity updated", value: ResearchDateLabel.full(date)) }
                        }
                    }
                } else {
                    Section("Graded Research") {
                        Text("Research remains experimental. Estimates, sales and population apply only to the exact returned printing, language, grader and grade. A guide estimate is separate from a recorded sale.")
                        Text("RAW research does not distinguish card condition. A provider rating is not a measured probability or an authenticity check.")
                        if let date = model.graded.details?.meta.generatedAt { LabeledContent("Data generated", value: ResearchDateLabel.full(date)) }
                        if let date = model.graded.selectedVariant?.updatedAt { LabeledContent("Variant updated", value: ResearchDateLabel.full(date)) }
                        if let date = model.graded.selectedGrade?.syncedOn { LabeledContent("Grade synced", value: date) }
                    }
                }
            }.navigationTitle("About This Data").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private enum ResearchDateLabel {
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    static func compact(_ value: String) -> String { date(value)?.formatted(date: .abbreviated, time: .omitted) ?? value }
    static func full(_ value: String) -> String { date(value)?.formatted(date: .abbreviated, time: .shortened) ?? value }
}
