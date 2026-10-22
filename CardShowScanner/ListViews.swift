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
    @State private var deleting: CardList?
    @Query private var sessions: [ScanSession]
    var body: some View {
        List {
            Section("New list") {
                TextField("List name", text: $newName)
                Button("Create") {
                    context.insert(CardList(name: newName.trimmingCharacters(in: .whitespacesAndNewlines)))
                    save(); newName = ""
                }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Saved lists") {
                ForEach(lists) { list in
                    NavigationLink {
                        CardListView(list: list, session: sessions.first { $0.listID == list.id })
                    } label: {
                        VStack(alignment: .leading) {
                            Text(list.name).font(.headline)
                            Text("\(list.quantity) cards • \(list.knownValue.money) known subtotal").font(.caption)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = list }
                        Button("Duplicate") {
                            do { try CardListService.duplicate(list, context: context) }
                            catch { context.rollback(); self.error = error.localizedDescription }
                        }.tint(.blue)
                    }
                }
            }
        }.navigationTitle("My Lists").failureAlert($error)
            .confirmationDialog("Delete this list and its cards?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete List", role: .destructive) { if let deleting {
                    do { try SessionService.deleteList(deleting, context: context) }
                    catch { self.error = error.localizedDescription }
                }; deleting = nil }
            }
    }
    private func save() {
        do { try CardListService.save(context) } catch { self.error = error.localizedDescription }
    }
}

struct CardListView: View {
    @Bindable var list: CardList
    @Environment(\.modelContext) private var context
    var session: ScanSession? = nil
    @Query private var sessions: [ScanSession]
    @State private var continueGame = "Pokémon"
    @State private var confirmContinue = false
    @State private var continuedID: UUID?
    @State private var search = ""
    @State private var sort = "Scan Order"
    @State private var rename = false
    @State private var name = ""
    @State private var error: String?
    @State private var editing: InventoryCard?
    @State private var exportText = ""
    @State private var exporting = false
    @State private var shareURL: URL?
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
            Section {
                if let session { SessionReviewHeader(session: session, list: list) }
                else {
                    LabeledContent("Total quantity", value: String(list.quantity))
                    LabeledContent("Known market subtotal", value: list.knownValue.money)
                    if list.unpricedQuantity > 0 { Text("Partial valuation: \(list.unpricedQuantity) copies have no price.").foregroundStyle(.orange) }
                    Picker("Game for continued scanning", selection: $continueGame) {
                        ForEach(CatalogOptions.games, id: \.self) { Text($0) }
                    }
                    Button("Continue Scanning") { confirmContinue = true }
                }
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
        }.navigationTitle(session == nil ? list.name : "Review & Offer").searchable(text: $search)
            .onAppear { continueGame = list.orderedCards.first?.snapshot.identity.game ?? "Pokémon" }
            .confirmationDialog("Continue this list?", isPresented: $confirmContinue) {
                Button("Continue Scanning") {
                    do { continuedID = try SessionService.continueList(list, game: continueGame, context: context).id }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("New cards append to this list. Any other active session will be finished and kept.") }
            .navigationDestination(item: $continuedID) { id in
                if let resumed = sessions.first(where: { $0.id == id }) { ScannerView(session: resumed, list: list) }
            }
            .toolbar {
                Menu {
                    Button("Rename") { name = list.name; rename = true }
                    Button("Save CSV File") { exportText = csv; exporting = true }
                    Button("Share CSV") { share() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            .alert("Rename List", isPresented: $rename) {
                TextField("Name", text: $name)
                Button("Save") { if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { list.name = name; save() } }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $editing) { item in CardEditorView(item: item) }
            .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { cleanupShare() } })) {
                if let shareURL { ShareSheet(url: shareURL) }
            }
            .fileExporter(isPresented: $exporting, document: CSVDocument(text: exportText), contentType: .commaSeparatedText, defaultFilename: "CardShowList.csv") { result in
                if case .failure(let failure) = result { DiagnosticLog.shared.failure("csv.export_failed", failure); error = failure.localizedDescription }
                else { DiagnosticLog.shared.record("csv.exported") }
            }.failureAlert($error)
    }
    private var csv: String { CSVExportService.render(list.orderedCards.map { ExportRow(card: $0.snapshot, quantity: $0.quantity) }) }
    private func save() { do { try CardListService.save(context) } catch { self.error = error.localizedDescription } }
    private func share() {
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
    @State private var card: CardCandidate
    @State private var quantity: Int
    @State private var price: String
    @State private var error: String?
    @State private var cashOverride: String
    @State private var tradeOverride: String
    @State private var maximumOverride: String
    init(item: InventoryCard) {
        self.item = item
        _card = State(initialValue: item.snapshot); _quantity = State(initialValue: item.quantity)
        _price = State(initialValue: CSVExportService.number(item.snapshot.marketPrice))
        _cashOverride = State(initialValue: item.cashOverrideText ?? "")
        _tradeOverride = State(initialValue: item.tradeOverrideText ?? "")
        _maximumOverride = State(initialValue: item.maximumOverrideText ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Card identity — edit to correct a match") {
                    TextField("Name", text: $card.name)
                    Picker("Game", selection: $card.identity.game) { ForEach(CatalogOptions.games, id: \.self) { Text($0) } }
                    TextField("Set", text: $card.set)
                    TextField("Number", text: $card.number)
                    TextField("Product ID", text: $card.identity.productID).textInputAutocapitalization(.never)
                    TextField("SKU ID (optional)", text: Binding(get: { card.identity.skuID ?? "" }, set: { card.identity.skuID = $0.isEmpty ? nil : $0 }))
                    TextField("Printing", text: $card.identity.printing)
                    TextField("Language", text: $card.identity.language)
                    TextField("Image URL (optional)", text: Binding(get: { card.imageURL?.absoluteString ?? "" }, set: { card.imageURL = URL(string: $0) })).keyboardType(.URL).textInputAutocapitalization(.never)
                }
                Section("Inventory") {
                    Picker("Condition", selection: $card.identity.condition) { ForEach(CatalogOptions.conditions, id: \.self) { Text($0) } }
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...100000)
                    TextField("Market price USD — blank means unknown", text: $price).keyboardType(.decimalPad)
                    Text("When changing identity or finish, verify the market price and SKU too.").font(.caption)
                    Text("Added \(item.addedAt.formatted())").font(.caption)
                }
                Section("Offer overrides • USD per copy") {
                    TextField("Cash (blank uses session rate)", text: $cashOverride).keyboardType(.decimalPad)
                    TextField("Trade (blank uses session rate)", text: $tradeOverride).keyboardType(.decimalPad)
                    TextField("Maximum buy (blank uses session rate)", text: $maximumOverride).keyboardType(.decimalPad)
                    Text("Overrides apply to each copy of this exact variant/condition. Unpriced cards remain excluded until a market price is supplied. No automatic bulk classification is performed.").font(.caption)
                }
            }.navigationTitle("Edit Card")
                .onChange(of: card.identity.printing) { _, _ in price = ""; card.identity.skuID = nil }
                .onChange(of: card.identity.productID) { _, _ in price = ""; card.identity.skuID = nil }
                .onChange(of: card.identity.game) { _, _ in price = ""; card.identity.skuID = nil }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
                }.failureAlert($error)
        }
    }
    private func save() {
        guard !card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !card.identity.productID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !card.identity.language.isEmpty, !card.identity.printing.isEmpty else {
            error = "Name, product ID, language, and printing are required."; return
        }
        let text = price.trimmingCharacters(in: .whitespacesAndNewlines)
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
            if let batch = batches.first(where: { $0.listID != nil && $0.listID == item.list?.id }), card.identity.game != batch.game {
                error = "The card game must match this batch. Start a new session for a different game."; return
            }
        } catch { self.error = error.localizedDescription; return }
        card.marketPrice = text.isEmpty ? nil : parsed
        do {
            if let duplicate = item.list?.cards.first(where: { $0.id != item.id && $0.snapshot.identity == card.identity }) {
                guard duplicate.cashOverrideText == cashText,
                      duplicate.tradeOverrideText == tradeText,
                      duplicate.maximumOverrideText == maximumText else {
                    error = "An identical card already has different offer overrides. Match those overrides before merging."; return
                }
                duplicate.quantity += quantity; try duplicate.update(card); context.delete(item)
            } else {
                item.quantity = quantity; try item.update(card)
                item.cashOverrideText = cashText
                item.tradeOverrideText = tradeText
                item.maximumOverrideText = maximumText
            }
            try CardListService.save(context); DiagnosticLog.shared.record("inventory.edited"); dismiss()
        } catch { context.rollback(); self.error = error.localizedDescription }
    }
}
