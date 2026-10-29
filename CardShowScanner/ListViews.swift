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
    @Environment(\.modelContext) private var context
    @Query(sort: \CardList.createdAt, order: .reverse) private var lists: [CardList]
    @State private var newName = ""
    @State private var error: String?
    @State private var pendingDeletion: ListDeletionRequest?
    @Query private var sessions: [ScanSession]
    var body: some View {
        List {
            Section("New list") {
                TextField("List name", text: $newName).accessibilityIdentifier("savedLists.newName")
                Button("Create") {
                    context.insert(CardList(name: newName.trimmingCharacters(in: .whitespacesAndNewlines)))
                    save(); newName = ""
                }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("savedLists.create")
            }
            Section("Saved lists") {
                ForEach(lists) { list in
                    NavigationLink {
                        CardListView(list: list, session: sessions.first { $0.listID == list.id })
                    } label: {
                        VStack(alignment: .leading) {
                            Text(list.name).font(.headline)
                            Text("\(list.quantity) cards • \(list.knownValue.money) known subtotal").font(.caption)
                            Text(list.outcomeTitle).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .accessibilityIdentifier("savedList.outcome." + list.id.uuidString)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        // A destructive swipe role removes the row visually
                        // before confirmation. Keep the gesture, and delete
                        // only from the independently presented sheet.
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
        }.navigationTitle("My Lists")
            .sheet(item: $pendingDeletion) { request in ListDeletionConfirmationView(request: request) }
            .failureAlert($error)
    }
    private func save() {
        do { try CardListService.save(context) } catch { self.error = error.localizedDescription }
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
            listOutcomeSection
            Section("Export inventory") {
                Button("Export CSV to Files", systemImage: "square.and.arrow.up") { exportCSV() }
                    .buttonStyle(.borderless).frame(minHeight: 44)
                    .disabled(list.cards.isEmpty || exporting || shareURL != nil)
                    .accessibilityIdentifier("list.exportCSV")
                Button("Share CSV", systemImage: "paperplane") { share() }
                    .buttonStyle(.borderless).frame(minHeight: 44)
                    .disabled(list.cards.isEmpty || exporting || shareURL != nil)
                    .accessibilityIdentifier("list.shareCSV")
                Text("Exports all \(list.quantity) cards in scan order, including quantity, condition, printing and market value. Search and sorting do not limit the export.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if let session = reviewSession {
                    // This row contains several independent controls. Automatic
                    // List button styling can otherwise make the whole offer
                    // panel trigger its Continue Scanning action.
                    SessionReviewHeader(session: session, list: list,
                        onContinue: { continueScanning(session) },
                        onSavedOffers: { open(.savedOffers(session.id), session: session) })
                        .buttonStyle(.borderless)
                }
                else {
                    LabeledContent("Total quantity", value: String(list.quantity))
                    LabeledContent("Known market subtotal", value: list.knownValue.money)
                    if list.unpricedQuantity > 0 { Text("Partial valuation: \(list.unpricedQuantity) copies have no price.").foregroundStyle(.orange) }
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
            Section {
                Button("Search & Add Card", systemImage: "magnifyingglass") { showingCatalogSearch = true }
                    .buttonStyle(.borderless).frame(minHeight: 44).accessibilityIdentifier("list.searchAndAdd")
            }
            Picker("Sort", selection: $sort) { ForEach(["Scan Order", "Name", "Value"], id: \.self) { Text($0) } }
            if list.cards.isEmpty { ContentUnavailableView("No cards yet", systemImage: "rectangle.stack", description: Text("Open the scanner to add cards.")) }
            ForEach(filtered) { item in
                Button { editing = item } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.snapshot.name).font(.headline)
                        Text("\(item.snapshot.set) • \(item.snapshot.number)").font(.caption)
                        Text("\(item.snapshot.identity.printing) • \(item.snapshot.identity.condition) • \(item.snapshot.identity.language)").font(.caption)
                        Text("Qty \(item.quantity) • \(item.snapshot.marketPrice.map { ($0 * Decimal(item.quantity)).money } ?? "Price unavailable")")
                        if item.cashOverrideText != nil || item.tradeOverrideText != nil || item.maximumOverrideText != nil {
                            Text("Per-copy offer overrides applied").font(.caption).foregroundStyle(.secondary)
                        }
                    }.foregroundStyle(.primary).frame(minHeight: 60)
                }.swipeActions {
                    Button("Remove", role: .destructive) { context.delete(item); save() }
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
                        Button("Rename") { name = list.name; rename = true }
                        Button("Export CSV to Files") { exportCSV() }
                            .disabled(list.cards.isEmpty || exporting || shareURL != nil)
                        Button("Share CSV") { share() }
                            .disabled(list.cards.isEmpty || exporting || shareURL != nil)
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
            .sheet(item: $editing) { item in CardEditorView(item: item) }
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
    private var listOutcomeSection: some View {
        Section("List outcome") {
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
            Text("The outcome stays with this saved list until you change or clear it.")
                .font(.caption).foregroundStyle(.secondary)
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
    let item: InventoryCard
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PricingSource.defaultsKey) private var pricingSource = PricingSource.tcgTracking.rawValue
    @State private var pricing: CardEditorPricingModel
    @State private var quantity: Int
    @State private var error: String?
    @State private var cashOverride: String
    @State private var tradeOverride: String
    @State private var maximumOverride: String
    @State private var showingConnection = false
    init(item: InventoryCard) {
        self.item = item
        _pricing = State(initialValue: CardEditorPricingModel(card: item.snapshot)); _quantity = State(initialValue: item.quantity)
        _cashOverride = State(initialValue: item.cashOverrideText ?? "")
        _tradeOverride = State(initialValue: item.tradeOverrideText ?? "")
        _maximumOverride = State(initialValue: item.maximumOverrideText ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Card identity — edit to correct a match") {
                    TextField("Name", text: $pricing.card.name)
                    Picker("Game", selection: identityBinding(\.game)) { ForEach(CatalogOptions.games, id: \.self) { Text($0) } }
                    TextField("Set", text: $pricing.card.set)
                    TextField("Number", text: $pricing.card.number)
                    TextField("Product ID", text: identityBinding(\.productID)).textInputAutocapitalization(.never)
                    TextField("SKU ID (optional)", text: Binding(get: { pricing.card.identity.skuID ?? "" }, set: { pricing.setSKU($0) }))
                    Picker("Type / printing", selection: identityBinding(\.printing)) {
                        ForEach(Array(Set(pricing.card.printings + [pricing.card.identity.printing])).sorted(), id: \.self) { Text($0) }
                    }.pickerStyle(.menu)
                    TextField("Language", text: identityBinding(\.language))
                    TextField("Image URL (optional)", text: Binding(get: { pricing.card.imageURL?.absoluteString ?? "" }, set: { pricing.card.imageURL = URL(string: $0) })).keyboardType(.URL).textInputAutocapitalization(.never)
                }
                Section("Market details") {
                    NavigationLink { MarketInsightsView(card: pricing.card) } label: {
                        Label("Market Details", systemImage: "chart.line.uptrend.xyaxis")
                    }.accessibilityIdentifier("cardEditor.marketDetails")
                    Text("View public prices and optional exact-condition market activity for this card.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Graded Research (experimental)") {
                    NavigationLink { ResearchView(card: pricing.card) } label: {
                        Label("View Graded Research", systemImage: "chart.bar.xaxis")
                    }.disabled(pricing.priceLoading)
                        .accessibilityIdentifier("cardEditor.research")
                    Text("View reported sales and grading estimates for this catalog card. Research does not apply a new inventory price or change saved offers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Inventory") {
                    PricingSourcePicker(accessibilityID: "cardEditor.pricingSource")
                    Picker("Condition", selection: identityBinding(\.condition)) { ForEach(CatalogOptions.conditions, id: \.self) { Text($0) } }
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...100000)
                    TextField("Market price USD — blank means unknown", text: Binding(get: { pricing.price }, set: { pricing.setPrice($0) })).keyboardType(.decimalPad)
                    if let metadata = pricing.card.marketPriceMetadata {
                        Text(metadata.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    if pricing.priceLoading { ProgressView("Checking market value…") }
                    if let message = pricing.priceMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if pricing.priceConnectionRequired {
                        Button("Connect TCGTracking", systemImage: "person.crop.circle") {
                            pricing.cancelLookup(); showingConnection = true
                        }
                    }
                    Button("Refresh Market Price & Types", systemImage: "arrow.clockwise") { pricing.refreshPrice() }
                        .disabled(pricing.priceLoading)
                    Text("Condition and type use the exact catalog quote. You can enter a market price manually if a quote is unavailable.").font(.caption)
                    Text("Added \(item.addedAt.formatted())").font(.caption)
                }
                Section("Offer overrides • USD per copy") {
                    TextField("Cash (blank uses session rate)", text: $cashOverride).keyboardType(.decimalPad)
                    TextField("Trade (blank uses session rate)", text: $tradeOverride).keyboardType(.decimalPad)
                    TextField("Maximum buy (blank uses session rate)", text: $maximumOverride).keyboardType(.decimalPad)
                    Text("Overrides apply to each copy of this exact variant/condition. Unpriced cards remain excluded until a market price is supplied. No automatic bulk classification is performed.").font(.caption)
                }
            }.navigationTitle("Edit Card")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(pricing.priceLoading) }
                }
                .task { pricing.loadPrintingOptions() }
                .onChange(of: pricingSource) { _, _ in pricing.pricingSourceChanged() }
                .onDisappear { pricing.cancelLookup() }
                .fullScreenCover(isPresented: $showingConnection, onDismiss: { pricing.refreshPrice() }) {
                    TCGTrackingConnectionView(continueTitle: "Return to Card") {
                        guard showingConnection else { return }
                        OnlineMarketPricing.connectionDidChange(); showingConnection = false
                    }
                }
                .failureAlert($error)
        }
    }
    private func identityBinding(_ keyPath: WritableKeyPath<CardIdentity, String>) -> Binding<String> {
        Binding(get: { pricing.card.identity[keyPath: keyPath] }, set: { value in
            pricing.changeIdentity { $0[keyPath: keyPath] = value }
        })
    }
    private func save() {
        guard !pricing.priceLoading else { return }
        guard !pricing.card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pricing.card.identity.productID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pricing.card.identity.language.isEmpty, !pricing.card.identity.printing.isEmpty else {
            error = "Name, product ID, language, and printing are required."; return
        }
        let text = pricing.price.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        guard text.isEmpty || (text.range(of: #"^[0-9]+(?:\.[0-9]{1,6})?$"#, options: .regularExpression) != nil && parsed != nil && parsed! >= 0) else { error = "Enter a nonnegative USD price or leave it blank."; return }
        guard [cashOverride, tradeOverride, maximumOverride].allSatisfy({ $0.isEmpty || MoneyInput.parse($0) != nil }) else {
            error = "Offer overrides must be nonnegative USD amounts or blank."; return
        }
        let cashText = cashOverride.isEmpty ? nil : CSVExportService.number(MoneyInput.parse(cashOverride))
        let tradeText = tradeOverride.isEmpty ? nil : CSVExportService.number(MoneyInput.parse(tradeOverride))
        let maximumText = maximumOverride.isEmpty ? nil : CSVExportService.number(MoneyInput.parse(maximumOverride))
        do {
            let batches = try context.fetch(FetchDescriptor<ScanSession>())
            if let batch = batches.first(where: { $0.listID != nil && $0.listID == item.list?.id }), pricing.card.identity.game != batch.game {
                error = "The card game must match this batch. Start a new session for a different game."; return
            }
        } catch { self.error = error.localizedDescription; return }
        pricing.card.marketPrice = text.isEmpty ? nil : parsed
        do {
            try CardListService.edit(item, card: pricing.card, quantity: quantity,
                cashOverride: cashText, tradeOverride: tradeText, maximumOverride: maximumText, context: context)
            DiagnosticLog.shared.record("inventory.edited"); dismiss()
        } catch { context.rollback(); self.error = error.localizedDescription }
    }
}
