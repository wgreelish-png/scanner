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

struct SavedListsView: View {
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
    @FocusState private var nameFocused: Bool

    private var filtered: [CardList] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return lists.filter { !$0.isCardShowInventory && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.outcomeTitle.localizedCaseInsensitiveContains(query)) }
    }

    private var importedInventory: CardList? { lists.first { $0.isCardShowInventory } }

    var body: some View {
        List {
            Section { ShowBudgetSummaryCard() }
            Section {
                NavigationLink { CardShowInventoryView() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.indigo)
                            .frame(width: 44, height: 52)
                            .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Card Show Inventory").font(.headline)
                            if let importedInventory {
                                Text("\(importedInventory.quantity) cards · Saved on this iPhone").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Import your TCGTracking location.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 3)
                }.accessibilityIdentifier("savedLists.cardShowInventory")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if let importedInventory {
                            Button("Remove Saved Copy", role: .destructive) {
                                guard pendingDeletion == nil else { return }
                                pendingDeletion = ListDeletionRequest(list: importedInventory)
                            }.accessibilityIdentifier("savedLists.removeCardShowInventory")
                        }
                    }
            }
            Section {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                layout {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Lists").font(.caption).foregroundStyle(.secondary)
                        Text(lists.count.formatted()).font(.title2.bold()).accessibilityIdentifier("savedLists.count")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Cards").font(.caption).foregroundStyle(.secondary)
                        Text(lists.reduce(0) { $0 + $1.quantity }.formatted()).font(.title2.bold())
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Known value").font(.caption).foregroundStyle(.secondary)
                        Text(lists.reduce(Decimal.zero) { $0 + $1.knownValue }.money)
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
                    NavigationLink {
                        CardListView(list: list, session: sessions.first { $0.listID == list.id })
                    } label: {
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
                                    Text(list.outcomeTitle).font(.caption.weight(.medium))
                                        .accessibilityIdentifier("savedList.outcome." + list.id.uuidString)
                                    Text("·")
                                    Text(list.createdAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption)
                                }.foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
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
        .listStyle(.insetGrouped)
        .navigationTitle("My Lists")
        .searchable(text: $search, prompt: "Search lists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newName = ""; creationError = nil; showingNewList = true
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New List").accessibilityIdentifier("savedLists.newList")
            }
        }
        .sheet(isPresented: $showingNewList) { newListSheet }
        .sheet(item: $pendingDeletion) { request in ListDeletionConfirmationView(request: request) }
        .failureAlert($error)
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
                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("listDeletion.error")
                    }
                }
                Section {
                    Button(model.error == nil ? "Delete List" : "Retry Delete", role: .destructive) {
                        if model.confirm(context: context) { dismiss() }
                    }.disabled(model.isDeleting || model.didDelete)
                        .accessibilityIdentifier("listDeletion.confirm")
                    if model.isDeleting { ProgressView("Deleting list…") }
                }
            }.navigationTitle("Delete List?").navigationBarTitleDisplayMode(.inline)
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

struct CardListView: View {
    private enum ReviewDestination: Hashable {
        case scanner(UUID)
        case savedOffers(UUID)
    }
    @Bindable var list: CardList
    @Environment(\.modelContext) private var context
    var session: ScanSession? = nil
    var onContinueScanning: (() -> Void)? = nil
    @Query private var sessions: [ScanSession]
    @State private var continueGame = "Pokémon"
    @State private var confirmContinue = false
    @State private var reviewDestination: ReviewDestination?
    @State private var destinationSession: ScanSession?
    @State private var search = ""
    @State private var sort = "Scan Order"
    @State private var rename = false
    @State private var name = ""
    @State private var error: String?
    @State private var editing: InventoryCard?
    @State private var showingCatalogSearch = false
    @State private var showingInventoryImport = false
    @State private var showingOfferRates = false
    @State private var exportText = ""
    @State private var exporting = false
    @State private var shareURL: URL?
    @State private var choosingOutcome = false
    @State private var savingOutcome = false
    @State private var outcomeError: String?
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
            if list.isCardShowInventory {
                Section("TCGTracking inventory") {
                    if let link = list.cardShowInventory {
                        Text("Saved on this iPhone · Updated " + link.refreshedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("This list mirrors your Card Show location. Use an editable copy to scan or change cards locally.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Refresh or Make Editable Copy", systemImage: "arrow.triangle.2.circlepath") { showingInventoryImport = true }
                        .buttonStyle(.borderless).accessibilityIdentifier("list.manageCardShowInventory")
                }
            }
            Section {
                if let session = reviewSession {
                    // This row contains several independent controls. Automatic
                    // List button styling can otherwise make the whole offer
                    // panel trigger its Continue Scanning action.
                    SessionReviewHeader(session: session, list: list,
                        onContinue: { continueScanning(session) },
                        onSavedOffers: { open(.savedOffers(session.id), session: session) },
                        outcomeActions: AnyView(listOutcomeActions))
                        .buttonStyle(.borderless)
                }
                else {
                    LabeledContent("Total quantity", value: String(list.quantity))
                    LabeledContent("Known market subtotal", value: list.knownValue.money)
                    if list.unpricedQuantity > 0 { Text("Partial valuation: \(list.unpricedQuantity) copies have no price.").foregroundStyle(.orange) }
                    listOutcomeActions
                    if !list.isCardShowInventory {
                        Picker("Game for continued scanning", selection: $continueGame) {
                            ForEach(CatalogOptions.games, id: \.self) { Text($0) }
                        }
                        Button("Continue Scanning", systemImage: "viewfinder") {
                            guard !confirmContinue, reviewDestination == nil else { return }
                            DiagnosticLog.shared.record("navigation.scan_requested", ["phase": "standalone_list"])
                            confirmContinue = true
                        }.buttonStyle(.borderless)
                    }
                }
            }
            if !list.isCardShowInventory {
                Section {
                    Button("Search & Add Card", systemImage: "magnifyingglass") { showingCatalogSearch = true }
                        .buttonStyle(.borderless).frame(minHeight: 44).accessibilityIdentifier("list.searchAndAdd")
                }
            }
            Picker("Sort", selection: $sort) { ForEach(["Scan Order", "Name", "Value"], id: \.self) { Text($0 == "Scan Order" && list.isCardShowInventory ? "Import Order" : $0).tag($0) } }
            if list.cards.isEmpty { ContentUnavailableView("No cards yet", systemImage: "rectangle.stack", description: Text(list.isCardShowInventory ? "Your last imported location is empty. Refresh inventory to check for changes." : "Open the scanner to add cards.")) }
            ForEach(filtered) { item in
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    editing = item
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
                }.swipeActions {
                    if !list.isCardShowInventory { Button("Remove", role: .destructive) { context.delete(item); save() } }
                }
            }
        }.navigationTitle(reviewSession == nil ? list.name : "Review & Offer").searchable(text: $search)
            .onAppear { continueGame = list.orderedCards.first?.snapshot.identity.game ?? "Pokémon" }
            .confirmationDialog("Continue this list?", isPresented: $confirmContinue) {
                Button("Continue Scanning") {
                    guard reviewDestination == nil else { return }
                    do {
                        let continued = try SessionService.continueList(list, game: continueGame, context: context, finishingOtherSession: true)
                        continueScanning(continued)
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
                        Button("Clear List Outcome", systemImage: "arrow.uturn.backward") { recordOutcome(nil) }
                            .disabled(list.transactionOutcomeData == nil || savingOutcome)
                            .accessibilityIdentifier("list.clearOutcome")
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
            .sheet(item: $editing) { item in
                if list.isCardShowInventory { CardShowInventoryCardView(item: item) }
                else { CardEditorView(item: item) }
            }
            .sheet(isPresented: $showingOfferRates) {
                if let session = reviewSession { SessionRatesView(session: session) }
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
    private var recordedTransaction: ListOutcomeKind? {
        guard let kind = list.outcomeRecord?.kind, kind != .nothingHappened else { return nil }
        return kind
    }
    private var listOutcomeActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Outcome")
                    Spacer(minLength: 12)
                    Text(list.outcomeTitle).accessibilityIdentifier("list.outcomeValue")
                }.accessibilityElement(children: .contain)
                if let record = list.outcomeRecord {
                    Text("Recorded \(record.recordedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("list.outcomeRecordedAt")
                }
                if let outcomeError {
                    Text(outcomeError).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("list.outcomeError")
                }
            }
            Button {
                choosingOutcome = true
            } label: {
                Label(recordedTransaction?.title ?? "Record Transaction",
                      systemImage: recordedTransaction == nil ? "checkmark.circle" : "checkmark.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent)
                .disabled(savingOutcome)
                .accessibilityIdentifier("list.recordTransaction")
                .accessibilityHint("Choose Purchase, Trade + Purchase, or Trade for this list.")
                .confirmationDialog("Record Transaction", isPresented: $choosingOutcome, titleVisibility: .visible) {
                    ForEach([ListOutcomeKind.purchase, .tradeAndPurchase, .trade]) { kind in
                        Button(kind.title) { recordOutcome(kind) }
                            .accessibilityIdentifier("list.outcome." + kind.rawValue)
                    }
                    Button("Cancel", role: .cancel) {}
                }
            Button {
                recordOutcome(.nothingHappened)
            } label: {
                Label("Nothing Happened", systemImage: list.outcomeRecord?.kind == .nothingHappened
                      ? "checkmark.circle.fill" : "minus.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.bordered).tint(list.outcomeRecord?.kind == .nothingHappened ? Color.orange : Color.gray)
                .disabled(savingOutcome)
                .accessibilityIdentifier("list.nothingHappened")
                .accessibilityHint("Record that this deal did not go ahead.")
            Divider()
            RecordListBudgetButton(listID: list.id, listName: list.name,
                                   suggestedKind: recordedTransaction == .trade || recordedTransaction == .tradeAndPurchase ? .trade : .purchase,
                                   startsWithCashPaid: recordedTransaction == .tradeAndPurchase)

        }
    }
    private func recordOutcome(_ kind: ListOutcomeKind?) {
        guard !savingOutcome else { return }
        savingOutcome = true
        defer { savingOutcome = false }
        do {
            try ListOutcomeService.set(kind, for: list, context: context)
            outcomeError = nil
        } catch {
            outcomeError = "The outcome could not be saved. Your previous status is kept. Please try again."
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
    private var languages: [String] {
        Array(Set([pricing.card.identity.language, "English", "Japanese", "French", "German", "Italian",
                   "Spanish", "Portuguese", "Russian", "Korean", "Simplified Chinese", "Traditional Chinese"]))
            .filter { !$0.isEmpty }.sorted()
    }

    var body: some View {
        NavigationStack {
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
                    Picker("Language", selection: identityBinding(\.language)) {
                        ForEach(languages, id: \.self) { Text($0) }
                    }.pickerStyle(.menu).accessibilityIdentifier("cardEditor.language")
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
            .task { pricing.loadPrintingOptions() }
            .onDisappear { pricing.cancelLookup() }
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
        _search = State(initialValue: ManualCardSearchModel(game: CatalogOptions.games.contains(game) ? game : "Pokémon"))
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Game", selection: Binding(get: { search.game }, set: { search.changeGame($0) })) {
                        ForEach(CatalogOptions.games, id: \.self) { Text($0) }
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
