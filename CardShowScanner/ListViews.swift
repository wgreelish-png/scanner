import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Keep selection feedback visible while a finger is still on the row.
private struct ListSelectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

@MainActor struct SavedListsView: View {
    var onOpenScan: (() -> Void)? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \CardList.createdAt, order: .reverse) private var lists: [CardList]
    @Query private var sessions: [ScanSession]
    @State private var search = ""
    @State private var newName = ""
    @State private var showingNewList = false
    @State private var error: String?
    @State private var creationError: String?
    @State private var pendingDeletion: ListDeletionRequest?
    @State private var selectingLists = false
    @State private var selectedListIDs = Set<UUID>()
    @State private var pendingBulkDeletion: ListBulkDeletionRequest?
    @State private var transactionStore = ShowBudgetStore.shared
    @FocusState private var nameFocused: Bool

    private var filtered: [CardList] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return lists.filter { !$0.isCardShowInventory && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ShowTransactionListService.outcomeTitle(for: $0, store: transactionStore).localizedCaseInsensitiveContains(query)) }
    }

    private var visibleSelectionIDs: Set<UUID> {
        Set(filtered.map(\.id))
    }

    var body: some View {
        List {
            Section {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                layout {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Lists").font(.caption).foregroundStyle(.secondary)
                        Text(lists.filter { !$0.isCardShowInventory }.count.formatted()).font(.title2.bold()).accessibilityIdentifier("savedLists.count")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Cards").font(.caption).foregroundStyle(.secondary)
                        Text(lists.filter { !$0.isCardShowInventory }.reduce(0) { $0 + $1.quantity }.formatted()).font(.title2.bold())
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Known value").font(.caption).foregroundStyle(.secondary)
                        Text(lists.filter { !$0.isCardShowInventory }.reduce(Decimal.zero) { $0 + $1.knownValue }.money)
                            .font(.headline).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.vertical, 8)
            }
            Section("Your lists") {
                if lists.allSatisfy({ $0.isCardShowInventory }) {
                    ContentUnavailableView {
                        Label("Your collection starts here", systemImage: "rectangle.stack")
                    } description: {
                        Text("Scan cards into a new list or create an empty one with the + button.")
                    } actions: {
                        if let onOpenScan { Button("Scan Cards", action: onOpenScan).buttonStyle(.borderedProminent) }
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(filtered) { list in
                    Group {
                        if selectingLists {
                            Button { toggleSelection(list.id) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    selectionMark(list.id)
                                    savedListLabel(list)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(ListSelectionButtonStyle())
                                .accessibilityIdentifier("savedLists.select." + list.name)
                                .accessibilityAddTraits(selectedListIDs.contains(list.id) ? .isSelected : [])
                        } else {
                            NavigationLink {
                                CardListView(list: list, session: sessions.first { $0.listID == list.id })
                            } label: { savedListLabel(list) }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: !selectingLists) {
                        if !selectingLists {
                            Button("Delete") {
                                guard pendingDeletion == nil else { return }
                                pendingDeletion = ListDeletionRequest(list: list)
                                DiagnosticLog.shared.record("list.delete_requested", ["quantity": String(list.quantity)])
                            }.tint(.red).accessibilityIdentifier("savedList.requestDelete")
                            Button("Duplicate") {
                                do { try CardListService.duplicate(list, context: context) }
                                catch { context.rollback(); self.error = error.localizedDescription }
                            }.tint(.blue)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("My Lists")
        .searchable(text: $search, prompt: "Search lists")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(selectingLists ? "Done" : "Select") {
                    selectingLists.toggle()
                    if !selectingLists { selectedListIDs.removeAll() }
                }.disabled(lists.isEmpty).accessibilityIdentifier("savedLists.selectionMode")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if selectingLists {
                    Button("Select All") { selectedListIDs.formUnion(visibleSelectionIDs) }
                        .disabled(visibleSelectionIDs.isEmpty).accessibilityIdentifier("savedLists.selectAll")
                } else {
                    Button {
                        newName = ""; creationError = nil; showingNewList = true
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New List").accessibilityIdentifier("savedLists.newList")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selectingLists {
                Button("Delete Selected (\(selectedListIDs.count))", role: .destructive) {
                    guard pendingBulkDeletion == nil else { return }
                    let selected = lists.filter { selectedListIDs.contains($0.id) }
                    guard !selected.isEmpty else { return }
                    pendingBulkDeletion = ListBulkDeletionRequest(lists: selected)
                }.buttonStyle(.borderedProminent).tint(.red)
                    .frame(maxWidth: .infinity, minHeight: 44).padding().background(.regularMaterial)
                    .disabled(selectedListIDs.isEmpty).accessibilityIdentifier("savedLists.deleteSelected")
            }
        }
        .sheet(isPresented: $showingNewList) { newListSheet }
        .sheet(item: $pendingDeletion) { request in ListDeletionConfirmationView(request: request) }
        .sheet(item: $pendingBulkDeletion) { request in
            ListBulkDeletionConfirmationView(request: request) {
                selectedListIDs.subtract(request.ids)
                if selectedListIDs.isEmpty { selectingLists = false }
            }
        }
        .onChange(of: Set(lists.map(\.id))) { _, existing in selectedListIDs.formIntersection(existing) }
        .failureAlert($error)
    }

    private func toggleSelection(_ id: UUID) {
        if !selectedListIDs.insert(id).inserted { selectedListIDs.remove(id) }
    }
    private func selectionMark(_ id: UUID) -> some View {
        Image(systemName: selectedListIDs.contains(id) ? "checkmark.circle.fill" : "circle")
            .font(.title2).foregroundStyle(.indigo).frame(width: 28, height: 44).accessibilityHidden(true)
            .contentTransition(.identity)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
    private func savedListLabel(_ list: CardList) -> some View {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "rectangle.stack.fill")
                                .font(.title2).foregroundStyle(.indigo)
                                .frame(width: 44, height: 52)
                                .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(list.name).font(.headline)
                                Text("\(list.quantity) cards • \(list.knownValue.money) known subtotal")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Text(ShowTransactionListService.outcomeTitle(for: list, store: transactionStore)).font(.caption.weight(.medium))
                                        .accessibilityIdentifier("savedList.outcome." + list.id.uuidString)
                                    Text("·")
                                    Text(list.createdAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption)
                                }.foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        }
    }

    private var newListSheet: some View {
        NavigationStack {
            Form {
                Section("List name") {
                    TextField("For example, Saturday inventory", text: $newName)
                        .focused($nameFocused).submitLabel(.done).onSubmit { nameFocused = false }
                        .accessibilityIdentifier("savedLists.newName")
                }
                Text("Add cards by scanning or searching the catalog.").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("New List").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingNewList = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createList() }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("savedLists.create")
                }
            }
            .failureAlert($creationError)
        }.presentationDetents([.medium])
    }

    private func createList() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let list = CardList(name: name)
        context.insert(list)
        do {
            try CardListService.save(context)
            showingNewList = false
            newName = ""
        } catch {
            context.delete(list)
            creationError = error.localizedDescription
        }
    }
}

struct ListDeletionConfirmationView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var model: ListDeletionModel
    init(request: ListDeletionRequest) { _model = State(initialValue: ListDeletionModel(request: request)) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.request.name).font(.headline)
                    Text("This list and its \(model.request.quantity) cards will be deleted.")
                    if model.request.isImportedInventory {
                        Text("This removes the saved copy from this iPhone. Import again to download your TCGTracking inventory.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("Saved offer estimates and session history will stay in All Sessions.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 12) {
                    if let error = model.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("listDeletion.error")
                    }
                    if model.isDeleting { ProgressView("Deleting list…") }
                    Button(role: .destructive) {
                        if model.confirm(context: context) { dismiss() }
                    } label: {
                        Text(model.error == nil ? "Delete List" : "Retry Delete")
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                        .disabled(model.isDeleting || model.didDelete)
                        .accessibilityIdentifier("listDeletion.confirm")
                }
                .padding(16).frame(maxWidth: .infinity).background(.regularMaterial)
            }
            .navigationTitle("Delete List?").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.cancel(); dismiss() }
                            .disabled(model.isDeleting).accessibilityIdentifier("listDeletion.cancel")
                    }
                }
        }.presentationDetents([.medium, .large])
            .interactiveDismissDisabled(model.isDeleting)
            .onAppear { model.presented() }
            .onDisappear { model.dismissed() }
    }
}

@MainActor struct CardListView: View {
    private enum ReviewDestination: Hashable {
        case scanner(UUID)
        case savedOffers(UUID)
    }
    private struct ReceiptRoute: Identifiable { let id: UUID }
    @Bindable var list: CardList
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    var session: ScanSession? = nil
    var onContinueScanning: (() -> Void)? = nil
    var transactionEditing = false
    @Query private var sessions: [ScanSession]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private enum ReviewSection: String, CaseIterable { case cards = "Cards", offer = "Offer" }
    @State private var reviewSection = ReviewSection.cards
    @State private var openingScanner = false
    @State private var offerCardPrice = ""
    @State private var offerTransactionMode = TradeTransactionMode.cashOnly
    @State private var restoredOfferInputs = false
    @State private var continueGame = "Pokémon"
    @State private var confirmContinue = false
    @State private var reviewDestination: ReviewDestination?
    @State private var destinationSession: ScanSession?
    @State private var search = ""
    @State private var sort = "Scan Order"
    @State private var rename = false
    @State private var name = ""
    @State private var error: String?
    @State private var selectedCard: InventoryCard?
    @State private var showingCatalogSearch = false
    @State private var showingInventoryImport = false
    @State private var showingOfferRates = false
    @State private var exportText = ""
    @State private var exporting = false
    @State private var shareURL: URL?
    @State private var savingOutcome = false
    @State private var outcomeError: String?
    @State private var outcomeBudgetMessage: String?
    @State private var pendingOutcomeBudget = false
    @State private var isVisible = false
    @State private var transactionStore: ShowBudgetStore
    @State private var newTransactionKind: ShowTransactionKind?
    @State private var transactionOfferContext: ShowTransactionOfferContext?
    @State private var receiptRoute: ReceiptRoute?

    init(list: CardList, session: ScanSession? = nil,
         onContinueScanning: (() -> Void)? = nil, transactionEditing: Bool = false,
         transactionStore: ShowBudgetStore = .shared) {
        self.list = list; self.session = session
        self.onContinueScanning = onContinueScanning; self.transactionEditing = transactionEditing
        _transactionStore = State(initialValue: transactionStore)
    }
    private var inventoryTransaction: ShowTransactionReceipt? { transactionStore.transaction(forListID: list.id) }
    private var reviewSession: ScanSession? { session ?? sessions.first { $0.listID == list.id } }
    var filtered: [InventoryCard] {
        list.orderedCards.filter { search.isEmpty || [$0.snapshot.name, $0.snapshot.set, $0.snapshot.number, $0.snapshot.identity.productID].contains { $0.localizedCaseInsensitiveContains(search) } }
            .sorted {
                switch sort {
                case "Scan Order": return $0.addedAt == $1.addedAt ? $0.id.uuidString < $1.id.uuidString : $0.addedAt < $1.addedAt
                case "Value": return ($0.snapshot.marketPrice ?? -1) * Decimal($0.quantity) > ($1.snapshot.marketPrice ?? -1) * Decimal($1.quantity)
                default: return $0.snapshot.name.localizedStandardCompare($1.snapshot.name) == .orderedAscending
                }
            }
    }
    var body: some View {
        List {
            if reviewSection == .cards { cardRows }
            else { offerSection }
        }.navigationTitle(reviewSession == nil ? list.name : "Review & Offer").searchable(text: $search)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top) { reviewSummary }
            .safeAreaInset(edge: .bottom) { reviewActions }
            .onChange(of: reviewSection) { _, _ in
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .onAppear {
                isVisible = true; openingScanner = false
                continueGame = reviewSession?.game ?? list.orderedCards.first?.snapshot.identity.game ?? "Pokémon"
                restoreOfferInputs()
                synchronizeBudgetOutcomes()
            }
            .onDisappear { isVisible = false }
            .onChange(of: scenePhase) { _, phase in if isVisible && phase == .active { synchronizeBudgetOutcomes() } }
            .confirmationDialog("Continue this list?", isPresented: $confirmContinue) {
                Button("Continue Scanning") {
                    guard reviewDestination == nil else { return }
                    do {
                        if let session = reviewSession {
                            try SessionService.resume(session, context: context, finishingOtherSession: true)
                            openingScanner = true; continueScanning(session)
                        } else {
                            let continued = try SessionService.continueList(list, game: continueGame, context: context, finishingOtherSession: true)
                            openingScanner = true; continueScanning(continued)
                        }
                        DiagnosticLog.shared.record("navigation.scan_opened", ["phase": "standalone_list"])
                    }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("New cards append to this list. Any other active session will be finished and kept.") }
            // Register destinations on the List itself, never on a lazily
            // created offer row. One route permits only one push at a time.
            .navigationDestination(item: $reviewDestination) { destination in
                switch destination {
                case .scanner(let id):
                    if let batch = navigationSession(id) { ScannerView(session: batch, list: list) }
                    else { ContentUnavailableView("Session unavailable", systemImage: "tray") }
                case .savedOffers(let id):
                    if let batch = navigationSession(id) { SavedOffersView(session: batch) }
                    else { ContentUnavailableView("Session unavailable", systemImage: "tray") }
                }
            }
            .toolbar {
                if !list.isCardShowInventory {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Search & Add Card", systemImage: "magnifyingglass") { showingCatalogSearch = true }
                            .accessibilityIdentifier("list.searchAndAdd")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !list.isCardShowInventory { Button("Rename") { name = list.name; rename = true } }
                        Button("Export CSV to Files", systemImage: "square.and.arrow.up") { exportCSV() }
                            .disabled(list.cards.isEmpty || exporting || shareURL != nil).accessibilityIdentifier("list.exportCSV")
                        Button("Share CSV", systemImage: "paperplane") { share() }
                            .disabled(list.cards.isEmpty || exporting || shareURL != nil).accessibilityIdentifier("list.shareCSV")
                        if let session = reviewSession {
                            Button("Offer Percentages", systemImage: "percent") { showingOfferRates = true }
                                .accessibilityIdentifier("list.offerPercentages")
                            if (try? session.savedOffers().isEmpty) == false {
                                Button("Previous Estimates", systemImage: "clock.arrow.circlepath") {
                                    open(.savedOffers(session.id), session: session)
                                }
                            }
                        }
                        if !transactionEditing {
                            Button("Clear List Outcome", systemImage: "arrow.uturn.backward") { recordOutcome(nil) }
                                .disabled(list.transactionOutcomeData == nil || savingOutcome || pendingOutcomeBudget || inventoryTransaction != nil)
                                .accessibilityIdentifier("list.clearOutcome")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                        .accessibilityLabel("List options")
                        .accessibilityIdentifier("list.options")
                }
            }
            .alert("Rename List", isPresented: $rename) {
                TextField("Name", text: $name)
                Button("Save") { if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { list.name = name; save() } }
                Button("Cancel", role: .cancel) {}
            }
            .navigationDestination(item: $selectedCard) { item in
                CardResearchView(card: item.snapshot, initialSection: .market,
                    context: list.isCardShowInventory ? .importedCard(item) : .savedCard(item))
            }
            .sheet(isPresented: $showingOfferRates) {
                if let session = reviewSession { SessionRatesView(session: session) }
            }
            .sheet(item: $newTransactionKind) { kind in
                ShowTransactionForm(store: transactionStore, initialKind: kind, initialListID: list.id,
                    offerContext: transactionOfferContext)
            }
            .sheet(item: $receiptRoute) { route in
                NavigationStack {
                    ShowTransactionDetailView(transactionID: route.id, store: transactionStore)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { receiptRoute = nil } } }
                }
            }
            .sheet(isPresented: $showingInventoryImport) {
                NavigationStack {
                    CardShowInventoryView()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingInventoryImport = false } } }
                }
            }
            .sheet(isPresented: $showingCatalogSearch) {
                ManualCardSearchView(list: list, game: reviewSession?.game ?? list.orderedCards.first?.snapshot.identity.game ?? continueGame,
                    allowsGameChange: reviewSession == nil && list.cards.isEmpty)
            }
            .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { cleanupShare() } })) {
                if let shareURL { ShareSheet(url: shareURL) }
            }
            .fileExporter(isPresented: $exporting, document: CSVDocument(text: exportText), contentType: .commaSeparatedText, defaultFilename: "CardShowList.csv") { result in
                if case .failure(let failure) = result { DiagnosticLog.shared.failure("csv.export_failed", failure); error = failure.localizedDescription }
                else { DiagnosticLog.shared.record("csv.exported") }
            }.failureAlert($error)
    }
    @ViewBuilder private var cardRows: some View {
        if list.isCardShowInventory {
            Section("TCGTracking inventory") {
                if let link = list.cardShowInventory {
                    Text("Saved on this iPhone · Updated " + link.refreshedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("This list mirrors your Card Show location. Use an editable copy to scan or change cards locally.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Picker("Sort", selection: $sort) { ForEach(["Scan Order", "Name", "Value"], id: \.self) { Text($0 == "Scan Order" && list.isCardShowInventory ? "Import Order" : $0).tag($0) } }
        if list.cards.isEmpty { ContentUnavailableView("No cards yet", systemImage: "rectangle.stack", description: Text(list.isCardShowInventory ? "Your last imported location is empty. Refresh inventory to check for changes." : "Open the scanner to add cards.")) }
        ForEach(filtered) { item in
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                selectedCard = item
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    AsyncImage(url: item.snapshot.imageURL) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                        else {
                            RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                                .overlay { Image(systemName: "rectangle.portrait").foregroundStyle(.secondary) }
                        }
                    }.frame(width: 52, height: 74).clipShape(RoundedRectangle(cornerRadius: 5))
                        .accessibilityIdentifier("list.cardThumbnail").accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                    Text(item.snapshot.name).font(.headline)
                    Text("\(item.snapshot.set) • \(item.snapshot.number)").font(.caption)
                    Text("\(item.snapshot.identity.printing) • \(item.snapshot.identity.condition) • \(item.snapshot.identity.language)").font(.caption)
                    Text("Qty \(item.quantity) • \(item.snapshot.marketPrice.map { ($0 * Decimal(item.quantity)).money } ?? "Price unavailable")")
                    if item.cashOverrideText != nil || item.tradeOverrideText != nil || item.maximumOverrideText != nil {
                        Text("Per-copy offer overrides applied").font(.caption).foregroundStyle(.secondary)
                    }
                    }.foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            }.accessibilityIdentifier("list.card." + item.id.uuidString)
            .swipeActions {
                if !list.isCardShowInventory { Button("Remove", role: .destructive) { context.delete(item); save() } }
            }
        }
    }

    private var offerSection: some View {
        Section {
            if let session = reviewSession {
                SessionReviewHeader(session: session, list: list,
                    onContinue: { continueScanning(session) },
                    onSavedOffers: { open(.savedOffers(session.id), session: session) },
                    myCardPriceText: $offerCardPrice, transactionMode: $offerTransactionMode,
                    restoredInputs: $restoredOfferInputs,
                    outcomeActions: transactionEditing ? nil : { totals, transaction in AnyView(listOutcomeActions(totals: totals, transaction: transaction)) },
                    showsContinueAction: false)
                    .buttonStyle(.borderless)
            } else {
                LabeledContent("Known market subtotal", value: list.knownValue.money)
                if list.unpricedQuantity > 0 {
                    Text("Partial valuation: \(list.unpricedQuantity) copies have no price.").foregroundStyle(.orange)
                }
                LabeledContent("Calculated cash offer", value: currentOfferTotals.cash.money)
                if !transactionEditing { listOutcomeActions(totals: currentOfferTotals, transaction: nil) }
                if !list.isCardShowInventory {
                    Picker("Game for continued scanning", selection: $continueGame) {
                        ForEach(CatalogOptions.games(including: continueGame), id: \.self) { Text($0) }
                    }
                }
            }
        }
    }

    private var reviewSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(list.quantity.formatted()) cards").font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("list.quantity")
                Spacer()
                Text(list.quantity > 0 && list.unpricedQuantity == list.quantity
                     ? "Market unavailable"
                     : list.knownValue.money + (list.unpricedQuantity > 0 ? " known" : " market"))
                    .font(.subheadline).monospacedDigit()
            }
            if !transactionEditing && !list.isCardShowInventory {
                HStack {
                    Text(ShowTransactionListService.outcomeTitle(for: list, store: transactionStore))
                        .accessibilityIdentifier("list.outcomeValue")
                    Spacer()
                    if let recordedAt = inventoryTransaction?.recordedAt ?? list.outcomeRecord?.recordedAt {
                        Text(recordedAt.formatted(date: .abbreviated, time: .shortened))
                            .accessibilityIdentifier("list.outcomeRecordedAt")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            if !transactionEditing && !list.isCardShowInventory && (pendingOutcomeBudget || outcomeError != nil) {
                Button {
                    reviewSection = .offer
                } label: {
                    Label(pendingOutcomeBudget ? "Outcome sync needs attention" : "Review outcome error", systemImage: "exclamationmark.circle")
                        .font(.caption)
                }.buttonStyle(.borderless).foregroundStyle(.orange)
                    .accessibilityIdentifier("list.outcomeAttention")
            }
            Picker("List section", selection: $reviewSection) {
                ForEach(ReviewSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("list.section")
        }.padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
    }

    @ViewBuilder private var reviewActions: some View {
        if list.isCardShowInventory {
            Button { showingInventoryImport = true } label: {
                Label("Refresh or Make Editable Copy", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent)
                .accessibilityIdentifier("list.manageCardShowInventory")
                .padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
        } else {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) { primaryReviewActions }
                } else {
                    HStack(spacing: 12) { primaryReviewActions }
                }
            }.padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
        }
    }

    @ViewBuilder private var primaryReviewActions: some View {
        if !transactionEditing { recordTransactionButton }
        Button(action: requestContinueScanning) {
            Label("Scan", systemImage: "viewfinder")
                .frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.bordered).disabled(openingScanner)
            .accessibilityLabel("Continue Scanning")
            .accessibilityIdentifier("list.continueScanning")
    }

    private var recordTransactionButton: some View {
        Button {
            if let receipt = inventoryTransaction { receiptRoute = ReceiptRoute(id: receipt.id) }
            else { openTransactionCheckout() }
        } label: {
            Label(inventoryTransaction == nil ? (recordedTransaction?.title ?? "Record Transaction") : "View Transaction",
                  systemImage: inventoryTransaction == nil && recordedTransaction == nil ? "checkmark.circle" : "checkmark.circle.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.borderedProminent)
            .disabled(savingOutcome || pendingOutcomeBudget)
            .accessibilityIdentifier("list.recordTransaction")
            .accessibilityHint("Review a purchase or trade using this scanned list.")
    }

    private func openTransactionCheckout() {
        guard newTransactionKind == nil else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        do {
            restoreOfferInputs()
            let hasPrice = !offerCardPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let price = CustomOfferAmount.parse(offerCardPrice)
            if offerTransactionMode != .cashOnly && hasPrice && price == nil {
                throw TradeTransactionFailure.invalidPrice
            }
            let input = TradeTransactionInput(mode: offerTransactionMode,
                myCardPrice: offerTransactionMode == .cashOnly ? nil : price)
            let checkout = try ShowTransactionOfferContext.make(totals: currentOfferTotals, input: input)
            transactionOfferContext = checkout
            newTransactionKind = checkout.kind
        } catch { self.error = error.localizedDescription }
    }

    private func restoreOfferInputs() {
        guard !restoredOfferInputs, let session = reviewSession else { return }
        restoredOfferInputs = true
        do {
            if let transaction = try session.savedOffers().last?.tradeTransaction {
                offerTransactionMode = transaction.mode
                if transaction.mode != .cashOnly, let price = transaction.myCardPrice {
                    offerCardPrice = CSVExportService.number(price)
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func requestContinueScanning() {
        guard !openingScanner, !confirmContinue, reviewDestination == nil else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        DiagnosticLog.shared.record("navigation.scan_requested", ["phase": "list_action_bar"])
        if let session = reviewSession, session.isActive {
            openingScanner = true
            continueScanning(session)
            DiagnosticLog.shared.record("navigation.scan_opened", ["phase": "list_action_bar"])
        } else { confirmContinue = true }
    }

    private var recordedTransaction: ListOutcomeKind? {
        guard let kind = list.outcomeRecord?.kind, kind != .nothingHappened else { return nil }
        return kind
    }
    private var currentOfferTotals: OfferTotals {
        OfferCalculator.calculate(list.cards.map(\.offerLine), rates: reviewSession?.rates ?? SessionService.defaults())
    }
    private func listOutcomeActions(totals: OfferTotals, transaction: TradeTransactionResult?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record the deal to update your show inventory and budget together.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                if let outcomeError {
                    Text(outcomeError).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("list.outcomeError")
                }
                if let outcomeBudgetMessage {
                    Text(outcomeBudgetMessage).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("list.outcomeBudgetStatus")
                }
                if pendingOutcomeBudget {
                    Button("Retry Outcome Sync") { synchronizeBudgetOutcomes() }
                        .accessibilityIdentifier("list.retryOutcomeSync")
                }
            }
            Button {
                recordOutcome(.nothingHappened, totals: totals, transaction: transaction)
            } label: {
                Label("Nothing Happened", systemImage: list.outcomeRecord?.kind == .nothingHappened
                      ? "checkmark.circle.fill" : "minus.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.bordered).tint(list.outcomeRecord?.kind == .nothingHappened ? Color.orange : Color.gray)
                .disabled(savingOutcome || pendingOutcomeBudget || inventoryTransaction != nil)
                .accessibilityIdentifier("list.nothingHappened")
                .accessibilityHint("Record that this deal did not go ahead.")

        }
    }
    private func recordOutcome(_ kind: ListOutcomeKind?, totals: OfferTotals? = nil, transaction: TradeTransactionResult? = nil) {
        guard !savingOutcome, !pendingOutcomeBudget else { return }
        savingOutcome = true
        defer { savingOutcome = false }
        do {
            let result = try ListBudgetOutcomeService.record(kind, totals: totals ?? currentOfferTotals,
                transaction: transaction, for: list, context: context)
            outcomeError = nil; outcomeBudgetMessage = result.message; pendingOutcomeBudget = result.isPending
        } catch {
            outcomeError = (error as? LocalizedError)?.errorDescription ?? "The outcome and budget could not be updated. Please try again."
        }
    }
    private func synchronizeBudgetOutcomes() {
        let wasPending = pendingOutcomeBudget
        do {
            let result = try ListBudgetOutcomeService.synchronizePending(context: context)
            pendingOutcomeBudget = result.isPending
            if wasPending {
                outcomeBudgetMessage = result.message ?? "Outcome and budget are up to date."
                if !result.isPending { outcomeError = nil }
            }
            else if let message = result.message { outcomeBudgetMessage = message }
        } catch {
            pendingOutcomeBudget = true
            outcomeError = (error as? LocalizedError)?.errorDescription ?? "The saved outcome needs to finish syncing. Tap Retry Outcome Sync."
        }
    }
    private func continueScanning(_ session: ScanSession) {
        guard reviewDestination == nil else { return }
        // A review opened from an existing scanner returns to that screen;
        // saved-list reviews open their scanner through the parent route.
        if let onContinueScanning { onContinueScanning() }
        else { open(.scanner(session.id), session: session) }
    }
    private func open(_ destination: ReviewDestination, session: ScanSession) {
        guard reviewDestination == nil else { return }
        // Retain the returned model until @Query observes a newly resumed list.
        destinationSession = session
        reviewDestination = destination
    }
    private func navigationSession(_ id: UUID) -> ScanSession? {
        if let destinationSession, destinationSession.id == id { return destinationSession }
        if let session, session.id == id { return session }
        return sessions.first { $0.id == id }
    }
    private var csv: String { CSVExportService.render(list.orderedCards.map { ExportRow(card: $0.snapshot, quantity: $0.quantity) }) }
    private func exportCSV() {
        guard !list.cards.isEmpty, !exporting, shareURL == nil else { return }
        exportText = csv; exporting = true
    }
    private func save() { do { try CardListService.save(context) } catch { self.error = error.localizedDescription } }
    private func share() {
        guard !list.cards.isEmpty, !exporting, shareURL == nil else { return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("CardShowList.csv")
            try Data(csv.utf8).write(to: url, options: .atomic); shareURL = url
            DiagnosticLog.shared.record("csv.share_prepared", ["records": String(list.cards.count)])
        } catch { self.error = error.localizedDescription }
    }
    private func cleanupShare() { if let shareURL { try? FileManager.default.removeItem(at: shareURL.deletingLastPathComponent()) }; shareURL = nil }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct CardEditorView: View {
    private enum Sheet: String, Identifiable { case artwork, correction; var id: Self { self } }
    private enum Field: Hashable { case market, cash, trade, maximum }
    let item: InventoryCard
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var pricing: CardEditorPricingModel
    @State private var quantity: Int
    @State private var error: String?
    @State private var cashOverride: String
    @State private var tradeOverride: String
    @State private var maximumOverride: String
    @State private var sheet: Sheet?
    @State private var adjustingPrice = false
    @State private var showingOffers = false
    @State private var saving = false
    @FocusState private var focusedField: Field?

    init(item: InventoryCard) {
        self.item = item
        _pricing = State(initialValue: CardEditorPricingModel(card: item.snapshot))
        _quantity = State(initialValue: item.quantity)
        _cashOverride = State(initialValue: item.cashOverrideText ?? "")
        _tradeOverride = State(initialValue: item.tradeOverrideText ?? "")
        _maximumOverride = State(initialValue: item.maximumOverrideText ?? "")
    }

    private var hasOfferOverrides: Bool { !cashOverride.isEmpty || !tradeOverride.isEmpty || !maximumOverride.isEmpty }
    var body: some View {
        Form {
            Section {
                if textSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) { artworkButton; cardIdentity }
                } else {
                    HStack(alignment: .top, spacing: 16) { artworkButton; cardIdentity }
                }
            }.listRowBackground(Color.indigo.opacity(0.07))

            marketSection
            Section("Printing & language") {
                Picker("Printing", selection: identityBinding(\.printing)) {
                    ForEach(Array(Set(pricing.card.printings + [pricing.card.identity.printing])).sorted(), id: \.self) { Text($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("cardEditor.printing")
                Menu {
                    ForEach(pricing.languages, id: \.self) { language in
                        Button(language) { pricing.changeIdentity { $0.language = language } }
                    }
                } label: {
                    LabeledContent("Language", value: pricing.card.identity.language)
                }.disabled(pricing.languages.isEmpty).accessibilityIdentifier("cardEditor.language")
            }
            Section("Your inventory") {
                Stepper(value: $quantity, in: 1...100_000) {
                    LabeledContent("Quantity", value: quantity.formatted())
                }.accessibilityIdentifier("cardEditor.quantity")
                if quantity > 1, let price = pricing.card.marketPrice {
                    LabeledContent("Total market value", value: (price * Decimal(quantity)).money)
                        .foregroundStyle(.secondary).accessibilityIdentifier("cardEditor.totalValue")
                }
            }
            Section {
                Button("Find Correct Card", systemImage: "magnifyingglass") {
                    focusedField = nil; sheet = .correction
                }.accessibilityIdentifier("cardEditor.correctMatch")
            }
            Section("Research") {
                NavigationLink { CardResearchView(card: pricing.card) } label: {
                    Label("Market & Graded Research", systemImage: "magnifyingglass")
                }.accessibilityIdentifier("cardEditor.research")
            }
            offerSection
        }
        .navigationTitle("Card Details").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .tabBar)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(saving).accessibilityIdentifier("cardEditor.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(pricing.priceLoading || saving)
                    .accessibilityIdentifier("cardEditor.save")
            }
            if focusedField != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { focusedField = nil } label: { Text("Done").fixedSize() }
                        .frame(minWidth: 64, minHeight: 44).layoutPriority(1)
                        .accessibilityIdentifier("cardEditor.keyboardDone")
                }
            }
        }
        .onAppear { pricing.resumeAfterNavigation() }
        .onDisappear { focusedField = nil; pricing.suspendForNavigation() }
        .sheet(item: $sheet) { selected in
            switch selected {
            case .artwork:
                CardArtworkSheet(card: pricing.card)
            case .correction:
                CardMatchCorrectionSheet(game: pricing.card.identity.game) { candidate in
                    pricing.replaceCard(with: candidate); sheet = nil
                }
            }
        }
        .failureAlert($error)
    }

    private var artworkButton: some View {
        Button { focusedField = nil; sheet = .artwork } label: {
            CardDetailsArtwork(url: pricing.card.imageURL)
                .frame(width: textSize.isAccessibilitySize ? 120 : 104, height: textSize.isAccessibilitySize ? 168 : 146)
        }.buttonStyle(.plain).accessibilityLabel("Enlarge card image")
            .accessibilityIdentifier("cardEditor.artwork")
    }

    private var cardIdentity: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(pricing.card.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cardEditor.name")
            Text(pricing.card.set).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !pricing.card.number.isEmpty {
                Text("#" + pricing.card.number).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("cardEditor.number")
            }
            Text(pricing.card.identity.game).font(.caption.weight(.medium)).foregroundStyle(.indigo)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color.indigo.opacity(0.1), in: Capsule())
                .accessibilityIdentifier("cardEditor.game")
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
    }

    private var marketSection: some View {
        Section {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Market price").font(.subheadline).foregroundStyle(.secondary)
                    if pricing.priceLoading {
                        HStack(spacing: 8) { ProgressView(); Text("Checking…").font(.headline) }
                    } else {
                        Text(pricing.card.marketPrice?.money ?? "Price unavailable")
                            .font(pricing.card.marketPrice == nil ? .headline : .largeTitle.bold()).monospacedDigit()
                            .accessibilityIdentifier("cardEditor.marketPrice")
                    }
                    Text("per card").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { focusedField = nil; pricing.refreshPrice() } label: {
                    Image(systemName: "arrow.clockwise").font(.title3).frame(width: 44, height: 44)
                }.buttonStyle(.borderless).disabled(pricing.priceLoading)
                    .accessibilityLabel("Refresh market price and printings").accessibilityIdentifier("cardEditor.refreshPrice")
            }.padding(.vertical, 4)

            CardConditionPicker(selection: identityBinding(\.condition))
            if let metadata = pricing.card.marketPriceMetadata {
                Text(compactPriceStatus(metadata)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("cardEditor.priceStatus")
            }
            if let message = pricing.priceMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
            DisclosureGroup("Adjust market price", isExpanded: $adjustingPrice) {
                TextField("Market price", text: Binding(get: { pricing.price }, set: { pricing.setPrice($0) }))
                    .keyboardType(.decimalPad).focused($focusedField, equals: .market)
                    .accessibilityIdentifier("cardEditor.manualPrice")
                Text("USD per card. Leave blank when unknown.").font(.caption).foregroundStyle(.secondary)
            }.font(.subheadline).accessibilityIdentifier("cardEditor.adjustPrice")
        }
    }

    private var offerSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showingOffers) {
                TextField("Cash", text: $cashOverride).keyboardType(.decimalPad).focused($focusedField, equals: .cash)
                    .accessibilityIdentifier("cardEditor.cashOverride")
                TextField("Trade", text: $tradeOverride).keyboardType(.decimalPad).focused($focusedField, equals: .trade)
                    .accessibilityIdentifier("cardEditor.tradeOverride")
                TextField("Maximum buy", text: $maximumOverride).keyboardType(.decimalPad).focused($focusedField, equals: .maximum)
                    .accessibilityIdentifier("cardEditor.maximumOverride")
                Text("USD per card. Leave blank to use session rates.").font(.caption).foregroundStyle(.secondary)
            } label: {
                HStack {
                    Text("Offer overrides")
                    Spacer()
                    if hasOfferOverrides { Text("Applied").font(.caption).foregroundStyle(.indigo) }
                }
            }.accessibilityIdentifier("cardEditor.offerOverrides")
        }
    }

    private func compactPriceStatus(_ metadata: MarketPriceMetadata) -> String {
        var labels: [String] = []
        if metadata.isOffline == true { labels.append("Offline cache") }
        else if metadata.isCached == true { labels.append("Cached") }
        if let updated = metadata.updatedAt {
            labels.append("Updated " + updated.formatted(date: .abbreviated, time: .omitted))
        } else {
            labels.append("Checked " + metadata.fetchedAt.formatted(date: .abbreviated, time: .omitted))
        }
        return labels.joined(separator: " · ")
    }

    private func identityBinding(_ keyPath: WritableKeyPath<CardIdentity, String>) -> Binding<String> {
        Binding(get: { pricing.card.identity[keyPath: keyPath] }, set: { value in
            focusedField = nil
            pricing.changeIdentity { $0[keyPath: keyPath] = value }
        })
    }

    private func save() {
        guard !pricing.priceLoading, !saving else { return }
        focusedField = nil
        guard !pricing.card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pricing.card.identity.productID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pricing.card.identity.language.isEmpty, !pricing.card.identity.printing.isEmpty else {
            error = "Choose a card, printing and language before saving."; return
        }
        let text = pricing.price.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        guard text.isEmpty || (text.range(of: #"^[0-9]+(?:\.[0-9]{1,6})?$"#, options: .regularExpression) != nil && parsed != nil && parsed! >= 0) else {
            error = "Enter a nonnegative USD price or leave it blank."; return
        }
        guard [cashOverride, tradeOverride, maximumOverride].allSatisfy({ $0.isEmpty || MoneyInput.parse($0) != nil }) else {
            error = "Offer overrides must be nonnegative USD amounts or blank."; return
        }
        let cashText = cashOverride.isEmpty ? nil : CSVExportService.number(MoneyInput.parse(cashOverride))
        let tradeText = tradeOverride.isEmpty ? nil : CSVExportService.number(MoneyInput.parse(tradeOverride))
        let maximumText = maximumOverride.isEmpty ? nil : CSVExportService.number(MoneyInput.parse(maximumOverride))
        saving = true
        defer { saving = false }
        do {
            let batches = try context.fetch(FetchDescriptor<ScanSession>())
            if let batch = batches.first(where: { $0.listID != nil && $0.listID == item.list?.id }), pricing.card.identity.game != batch.game {
                error = "The card game must match this batch. Start a new session for a different game."; return
            }
            pricing.card.marketPrice = text.isEmpty ? nil : parsed
            try CardListService.edit(item, card: pricing.card, quantity: quantity,
                cashOverride: cashText, tradeOverride: tradeText, maximumOverride: maximumText, context: context)
            DiagnosticLog.shared.record("inventory.edited"); dismiss()
        } catch { context.rollback(); self.error = "The card could not be saved. Your changes are kept; try Save again." }
    }
}

struct CardConditionPicker: View {
    @Binding var selection: String
    var accessibilityPrefix = "cardEditor.condition"
    @Environment(\.dynamicTypeSize) private var textSize
    private let conditions = [("Near Mint", "NM"), ("Lightly Played", "LP"), ("Moderately Played", "MP"),
                              ("Heavily Played", "HP"), ("Damaged", "DMG")]
    init(selection: Binding<String>, accessibilityPrefix: String = "cardEditor.condition") {
        _selection = selection; self.accessibilityPrefix = accessibilityPrefix
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Condition").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: textSize.isAccessibilitySize ? 2 : 5), spacing: 8) {
                ForEach(conditions, id: \.0) { condition, short in
                    Button { selection = condition } label: {
                        Text(short).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selection == condition ? Color.white : Color.primary)
                            .background(selection == condition ? Color.indigo : Color.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityLabel(condition)
                        .accessibilityAddTraits(selection == condition ? .isSelected : [])
                        .accessibilityIdentifier(accessibilityPrefix + "." + short)
                }
            }
            if !conditions.contains(where: { $0.0 == selection }) {
                Text(selection).font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }
}

private struct CardDetailsArtwork: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay { Image(systemName: "rectangle.portrait").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
    }
}

private struct CardArtworkSheet: View {
    let card: CardCandidate
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            CardDetailsArtwork(url: card.imageURL).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(card.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct CardMatchCorrectionSheet: View {
    let onSelect: (CardCandidate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search: ManualCardSearchModel
    init(game: String, onSelect: @escaping (CardCandidate) -> Void) {
        self.onSelect = onSelect
        _search = State(initialValue: ManualCardSearchModel(game: TCGGameRegistry.scannerKey(for: game) != nil ? game : "Pokémon"))
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Game", selection: Binding(get: { search.game }, set: { search.changeGame($0) })) {
                        ForEach(CatalogOptions.games(including: search.game), id: \.self) { Text($0) }
                    }.accessibilityIdentifier("cardCorrection.game")
                    TextField("Name, card number or set", text: Binding(get: { search.query }, set: { search.updateQuery($0) }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("cardCorrection.query")
                }
                if search.isSearching { ProgressView("Searching saved catalog…") }
                if let error = search.error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button("Retry Search") { search.load() }
                    }
                } else if !search.isSearching && !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && search.results.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass", description: Text("Try a name, number or set."))
                }
                ForEach(search.results) { card in
                    Button { onSelect(card) } label: {
                        HStack(spacing: 14) {
                            CardDetailsArtwork(url: card.imageURL).frame(width: 64, height: 90)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(card.name).font(.headline)
                                Text(card.set).font(.caption).foregroundStyle(.secondary)
                                Text(card.number).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.foregroundStyle(.primary).padding(.vertical, 3)
                    }.buttonStyle(.plain).accessibilityIdentifier("cardCorrection.result." + card.identity.productID)
                }
            }
            .navigationTitle("Find Correct Card").navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { search.load() }
            .onDisappear { search.cancel() }
        }
    }
}
