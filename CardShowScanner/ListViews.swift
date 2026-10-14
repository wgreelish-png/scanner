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
                        CardListView(list: list)
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
                Button("Delete List", role: .destructive) { if let deleting { context.delete(deleting); save() }; deleting = nil }
            }
    }
    private func save() {
        do { try CardListService.save(context) } catch { self.error = error.localizedDescription }
    }
}

struct CardListView: View {
    @Bindable var list: CardList
    @Environment(\.modelContext) private var context
    @AppStorage("pricingPercentage") private var percentage = 70.0
    @State private var search = ""
    @State private var sort = "Name"
    @State private var rename = false
    @State private var name = ""
    @State private var error: String?
    @State private var editing: InventoryCard?
    @State private var exportText = ""
    @State private var exporting = false
    @State private var shareURL: URL?
    var filtered: [InventoryCard] {
        list.cards.filter { search.isEmpty || [$0.snapshot.name, $0.snapshot.set, $0.snapshot.number, $0.snapshot.identity.productID].contains { $0.localizedCaseInsensitiveContains(search) } }
            .sorted {
                switch sort {
                case "Date": return $0.addedAt > $1.addedAt
                case "Value": return ($0.snapshot.marketPrice ?? -1) * Decimal($0.quantity) > ($1.snapshot.marketPrice ?? -1) * Decimal($1.quantity)
                default: return $0.snapshot.name.localizedStandardCompare($1.snapshot.name) == .orderedAscending
                }
            }
    }
    var body: some View {
        List {
            Section {
                LabeledContent("Total quantity", value: String(list.quantity))
                LabeledContent("Known market subtotal", value: list.knownValue.money)
                LabeledContent("At \(Int(percentage))%", value: (list.knownValue * Decimal(percentage) / 100).money)
                if list.unpricedQuantity > 0 { Text("Partial valuation: \(list.unpricedQuantity) copies have no price.").foregroundStyle(.orange) }
                NavigationLink("Scan into this list") { ScannerView(list: list) }
            }
            Picker("Sort", selection: $sort) { ForEach(["Name", "Date", "Value"], id: \.self) { Text($0) } }
            if list.cards.isEmpty { ContentUnavailableView("No cards yet", systemImage: "rectangle.stack", description: Text("Open the scanner to add cards.")) }
            ForEach(filtered) { item in
                Button { editing = item } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.snapshot.name).font(.headline)
                        Text("\(item.snapshot.set) • \(item.snapshot.number)").font(.caption)
                        Text("\(item.snapshot.identity.printing) • \(item.snapshot.identity.condition) • \(item.snapshot.identity.language)").font(.caption)
                        Text("Qty \(item.quantity) • \(item.snapshot.marketPrice.map { ($0 * Decimal(item.quantity)).money } ?? "Price unavailable")")
                    }.foregroundStyle(.primary).frame(minHeight: 60)
                }.swipeActions {
                    Button("Remove", role: .destructive) { context.delete(item); save() }
                }
            }
        }.navigationTitle(list.name).searchable(text: $search)
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
    private var csv: String { CSVExportService.render(list.cards.sorted { $0.addedAt < $1.addedAt }.map { ExportRow(card: $0.snapshot, quantity: $0.quantity) }) }
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
    init(item: InventoryCard) {
        self.item = item
        _card = State(initialValue: item.snapshot); _quantity = State(initialValue: item.quantity)
        _price = State(initialValue: CSVExportService.number(item.snapshot.marketPrice))
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
        card.marketPrice = text.isEmpty ? nil : parsed
        do {
            if let duplicate = item.list?.cards.first(where: { $0.id != item.id && $0.snapshot.identity == card.identity }) {
                duplicate.quantity += quantity; try duplicate.update(card); context.delete(item)
            } else { item.quantity = quantity; try item.update(card) }
            try CardListService.save(context); DiagnosticLog.shared.record("inventory.edited"); dismiss()
        } catch { context.rollback(); self.error = error.localizedDescription }
    }
}
