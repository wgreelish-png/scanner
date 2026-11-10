import SwiftUI
import SwiftData

private struct ManualSearchSelection: Identifiable {
    let id = UUID()
    let card: CardCandidate
}

struct ManualCardSearchView: View {
    let list: CardList
    let allowsGameChange: Bool
    let draft: ScanBatchDraft?
    let focusSearchOnAppear: Bool
    private let pricing: any MarketPricing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: ManualCardSearchModel
    @State private var selection: ManualSearchSelection?
    @State private var didAddCard = false
    @State private var isVisible = false
    @FocusState private var searchFocused: Bool
    init(list: CardList, game: String, allowsGameChange: Bool, draft: ScanBatchDraft? = nil,
         focusSearchOnAppear: Bool = false,
         catalog: any CardCatalogSearching = CachedCardCatalog.shared,
         pricing: any MarketPricing = StandardMarketPricing()) {
        self.list = list; self.allowsGameChange = allowsGameChange; self.draft = draft
        self.focusSearchOnAppear = focusSearchOnAppear
        self.pricing = pricing
        _model = State(initialValue: ManualCardSearchModel(game: TCGGameRegistry.scannerKey(for: game) != nil ? game : "Pokémon", catalog: catalog))
    }
    private var activityState: DiagnosticActivityState {
        .init(selectedCount: model.results.count, canProceed: !model.isSearching && !model.results.isEmpty,
              blockReason: model.isSearching ? .preparing : (model.error != nil ? .unavailable : (model.results.isEmpty ? .noSelection : .ready)),
              cardCount: (draft?.list ?? list).quantity,
              searchHasText: !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if allowsGameChange && list.cards.isEmpty {
                        Picker("Game", selection: Binding(get: { model.game }, set: { model.changeGame($0) })) {
                            ForEach(CatalogOptions.games(including: model.game), id: \.self) { Text($0) }
                        }
                    }
                    TextField("Name, card number or set", text: Binding(get: { model.query }, set: { model.updateQuery($0) }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($searchFocused)
                        .accessibilityIdentifier("catalog.query")
                    Text("Search saved \(model.game) cards. Add a number or set to narrow the five closest matches.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.isSearching {
                    ProgressView(model.query.isEmpty ? "Opening saved catalog…" : "Searching…")
                }
                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(.secondary)
                        Button("Retry Search") {
                            DiagnosticLog.shared.activity(.action, screen: .manualSearch, action: .retrySearch, state: activityState)
                            model.load()
                        }.disabled(model.isSearching)
                    }
                } else if !model.isSearching && !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.results.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass", description: Text("Try the card name, its number, or its set."))
                }
                if !model.results.isEmpty {
                    Section("Closest matches") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 16) {
                            ForEach(model.results) { card in
                                Button {
                                    DiagnosticLog.shared.activity(.action, screen: .manualSearch, action: .selectCard, state: activityState)
                                    searchFocused = false
                                    selection = ManualSearchSelection(card: card)
                                } label: { CatalogSearchTile(card: card) }
                                    .buttonStyle(.plain).disabled(model.isSearching).accessibilityIdentifier("catalog.result." + card.identity.productID)
                            }
                        }
                    }
                }
            }.navigationTitle("Search & Add").navigationBarTitleDisplayMode(.inline)
                .scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            DiagnosticLog.shared.activity(.action, screen: .manualSearch, action: .close, state: activityState)
                            closeSearch()
                        }
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { searchFocused = false }
                            .fixedSize().frame(minWidth: 64, minHeight: 44)
                            .accessibilityIdentifier("catalog.keyboardDone")
                    }
                }
                .sheet(item: $selection, onDismiss: {
                    // Finish the confirmation's dismissal before closing its
                    // presenter. The scanner resumes only after this sheet ends.
                    if didAddCard { closeSearch() }
                    else if focusSearchOnAppear, isVisible, selection == nil { searchFocused = true }
                }) { selected in
                    ManualCardConfirmationView(card: selected.card, list: list, draft: draft, pricing: pricing) { _ in
                        didAddCard = true; searchFocused = false; selection = nil
                    }
                }
                .onAppear {
                    isVisible = true
                    DiagnosticLog.shared.activity(.screen, screen: .manualSearch, state: activityState)
                }
                .onChange(of: activityState) { _, state in
                    DiagnosticLog.shared.activity(.state, screen: .manualSearch, state: state)
                }
                .task {
                    model.load()
                    guard focusSearchOnAppear else { return }
                    // Wait for the presented sheet's search field to enter the
                    // responder hierarchy; disappearing cancels this request.
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    guard isVisible, selection == nil, !Task.isCancelled else { return }
                    searchFocused = true
                }
                .onDisappear {
                    DiagnosticLog.shared.activity(.exit, screen: .manualSearch, state: activityState)
                    isVisible = false; searchFocused = false; model.cancel()
                }
        }
    }
    private func closeSearch() {
        isVisible = false; searchFocused = false; model.cancel()
        dismiss()
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
    let draft: ScanBatchDraft?
    let onAdded: (CardCandidate) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var model: ManualCardAddModel
    @State private var hasRequestedPrice = false
    init(card: CardCandidate, list: CardList, draft: ScanBatchDraft?, pricing: any MarketPricing,
         onAdded: @escaping (CardCandidate) -> Void) {
        self.list = list; self.draft = draft; self.onAdded = onAdded
        _model = State(initialValue: ManualCardAddModel(card: card, pricing: pricing))
    }
    private var validPrinting: Bool {
        model.pricing.card.printings.isEmpty || model.pricing.card.printings.contains(model.pricing.card.identity.printing)
    }
    private var activityState: DiagnosticActivityState {
        .init(isPreparing: model.isSaving,
              canProceed: hasRequestedPrice && !model.isSaving && !model.isSaved && !model.pricing.priceLoading && validPrinting,
              blockReason: model.isSaving ? .saving : (!hasRequestedPrice || model.pricing.priceLoading ? .preparing
                  : (!validPrinting ? .invalidInput : (model.isSaved ? .unavailable : .ready))),
              cardCount: (draft?.list ?? list).quantity)
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
                    if let metadata = model.pricing.card.marketPriceMetadata {
                        Text(metadata.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = model.pricing.priceMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Button("Retry Market Price") {
                        DiagnosticLog.shared.activity(.action, screen: .manualConfirmation, action: .retryPrice, state: activityState)
                        model.pricing.refreshPrice()
                    }.disabled(model.pricing.priceLoading)
                    Text("Recent quotes are cached. You can add this card unpriced when a quote is unavailable.").font(.caption).foregroundStyle(.secondary)
                }.disabled(model.isSaving || model.isSaved)
                if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button("Add to List", systemImage: "plus.circle.fill") { add() }
                        .disabled(!hasRequestedPrice || model.isSaving || model.isSaved || model.pricing.priceLoading || !validPrinting)
                        .accessibilityIdentifier("catalog.confirmAdd")
                    Text("Adds one physical card as a new row at the end of this list.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Confirm Card").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        DiagnosticLog.shared.activity(.action, screen: .manualConfirmation, action: .cancel, state: activityState)
                        dismiss()
                    }.disabled(model.isSaving)
                } }
                .onAppear { DiagnosticLog.shared.activity(.screen, screen: .manualConfirmation, state: activityState) }
                .onChange(of: activityState) { _, state in
                    DiagnosticLog.shared.activity(.state, screen: .manualConfirmation, state: state)
                }
                .task {
                    guard !hasRequestedPrice else { return }
                    hasRequestedPrice = true; model.pricing.loadInitialPrice()
                }
                .onDisappear {
                    DiagnosticLog.shared.activity(.exit, screen: .manualConfirmation, state: activityState)
                    model.pricing.cancelLookup()
                }
                .confirmationDialog("Finish the other active session?", isPresented: $model.needsSessionSwitch) {
                    Button("Finish & Add to This List") { add(finishingOtherSession: true) }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Its list and saved offers will be kept. This card will be added to \(list.name).") }
        }
    }
    private func identityBinding(_ keyPath: WritableKeyPath<CardIdentity, String>) -> Binding<String> {
        Binding(get: { model.pricing.card.identity[keyPath: keyPath] }, set: { value in
            DiagnosticLog.shared.activity(.action, screen: .manualConfirmation,
                action: keyPath == \CardIdentity.printing ? .changePrinting : .changeCondition, state: activityState)
            model.pricing.changeIdentity { $0[keyPath: keyPath] = value }
        })
    }
    private func add(finishingOtherSession: Bool = false) {
        DiagnosticLog.shared.activity(.action, screen: .manualConfirmation, action: .addCard, state: activityState)
        if model.add(to: list, context: context, finishingOtherSession: finishingOtherSession, draft: draft) {
            DiagnosticLog.shared.activity(.outcome, screen: .manualConfirmation, action: .addSucceeded, state: activityState)
            onAdded(model.pricing.card)
        } else if model.error != nil {
            DiagnosticLog.shared.activity(.outcome, screen: .manualConfirmation, action: .addFailed, state: activityState)
        }
    }
}
