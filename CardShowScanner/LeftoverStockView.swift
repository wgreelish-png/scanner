import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// A separate stocktake of the entire Card Show website location. The frozen
/// source and independent count are kept on-device until the user exports them.
@MainActor struct LeftoverStockView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: LeftoverStockModel
    @State private var scanRoute: LeftoverStockScanRoute?
    @State private var lastScanRoute: LeftoverStockScanRoute?
    @State private var editingCard: InventoryCard?
    @State private var adjustment: LeftoverStockComparisonRow?
    @State private var search = ""
    @State private var comparisonGame = "All Games"
    @State private var confirmingNew = false
    @State private var confirmingFinish = false
    @State private var confirmingMissing = false
    @State private var showingConnection = false
    @State private var exporting = false
    @State private var exportText = ""
    @State private var exportFilename = "Card-Show-counted-stock"
    @State private var error: String?

    init(model: LeftoverStockModel? = nil) {
        _model = State(initialValue: model ?? LeftoverStockModel())
    }

    private var comparisonGames: [String] {
        let games = model.comparison?.rows.map { LeftoverStockModel.canonicalGame($0.card.identity.game) } ?? []
        return ["All Games"] + Set(games).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var visibleRows: [LeftoverStockComparisonRow] {
        (model.comparison?.rows ?? []).filter { row in
            (comparisonGame == "All Games" || LeftoverStockModel.canonicalGame(row.card.identity.game) == comparisonGame)
                && (search.isEmpty || [row.card.name, row.card.set, row.card.number, row.card.identity.game,
                    row.card.identity.printing, row.card.identity.condition, row.card.identity.language, row.skuID]
                    .joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            if !model.store.isLoaded {
                Section {
                    Text(model.store.error ?? "The saved count is unavailable.")
                    Button("Retry Opening Saved Count") { model.store.reload(); model.refresh(context: context) }
                }
            } else if let session = model.session {
                baselineSection(session)
                countingSection
                if !model.missingListIDs.isEmpty { missingSection }
                if let comparison = model.comparison {
                    summarySection(comparison)
                    if !comparison.issues.isEmpty { issuesSection(comparison) }
                    comparisonSection
                }
                instructionsSection
            } else {
                Section {
                    Label("Count your leftover cards", systemImage: "checklist")
                        .font(.title3.bold())
                    Text("Load the Card Show location, then count every card you still have across all games. Compare the saved website stock with your physical count and export its final quantities.")
                    Button {
                        Task { await model.startNewCount(context: context) }
                    } label: {
                        Label("Load Card Show & Start Count", systemImage: "arrow.down.doc")
                    }.disabled(model.isBusy).accessibilityIdentifier("leftoverStock.start")
                } footer: {
                    Text("This independent count does not change your local show inventory, acquisition costs or transactions. The website changes only when you import the CSV yourself.")
                }
            }
            if model.isFetching {
                Section { ProgressView("Loading the entire Card Show location…") }
            }
            if let message = model.message {
                Section { Text(message).font(.footnote).accessibilityIdentifier("leftoverStock.message") }
            }
            Section {
                Button {
                    model.cancel(); showingConnection = true
                } label: {
                    Label(model.needsSignIn ? "Sign In to TCGTracking" : "TCGTracking Account", systemImage: "person.crop.circle")
                }.disabled(model.isBusy).accessibilityIdentifier("leftoverStock.connect")
            }
        }
        .navigationTitle("Leftover Stock").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search source and counted cards")
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.session != nil { countActions }
        }
        .toolbar {
            if model.session != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Export Comparison CSV", systemImage: "arrow.up.doc") { exportComparison() }
                            .disabled(model.isBusy || !model.missingListIDs.isEmpty)
                            .accessibilityIdentifier("leftoverStock.exportComparison")
                        Button("Start a New Count", systemImage: "arrow.clockwise") { confirmingNew = true }
                            .disabled(model.isBusy)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Count options")
                }
            }
        }
        .sheet(item: $scanRoute, onDismiss: scannerClosed) { route in
            NavigationStack {
                ScannerView(session: route.draft?.session ?? route.session, list: route.draft?.list ?? route.list,
                            draft: route.draft, purpose: .leftoverStock)
            }
        }
        .sheet(item: $editingCard, onDismiss: { model.refresh(context: context) }) { card in
            NavigationStack { CardEditorView(item: card) }
        }
        .sheet(item: $adjustment) { row in
            LeftoverStockQuantityView(row: row) { quantity in
                try model.setCount(quantity, for: row, context: context)
            }
        }
        .fullScreenCover(isPresented: $showingConnection) {
            TCGTrackingConnectionView(continueTitle: "Return to Count") { showingConnection = false }
        }
        .confirmationDialog("Finish the entire Card Show count?", isPresented: $confirmingFinish, titleVisibility: .visible) {
            Button("All Games Counted — Finish") {
                do { try model.finishCount(context: context) } catch { self.error = error.localizedDescription }
            }.accessibilityIdentifier("leftoverStock.confirmFinish")
            Button("Keep Counting", role: .cancel) {}
        } message: {
            Text("Confirm you counted every remaining card across all games. Source cards you have not counted will be excluded from the replacement stock. You can continue scanning or correct quantities afterward; that will reopen the count.")
        }
        .confirmationDialog("Start a new leftover count?", isPresented: $confirmingNew, titleVisibility: .visible) {
            Button("Fetch New Baseline & Start Count") {
                let previous = model.session?.id
                Task { await model.startNewCount(context: context, replacing: previous) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A successful fetch replaces this comparison and starts a fresh count. Your previously counted lists remain saved. If loading fails, this count is kept.")
        }
        .confirmationDialog("Remove missing count references?", isPresented: $confirmingMissing, titleVisibility: .visible) {
            Button("Remove Missing References", role: .destructive) {
                do { try model.removeMissingReferences(context: context) } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A missing list may be an interrupted empty scan or a deleted count. Removing its reference does not restore its cards. Recount any affected cards before finishing.")
        }
        .fileExporter(isPresented: $exporting, document: CSVDocument(text: exportText), contentType: .commaSeparatedText,
                      defaultFilename: exportFilename) { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .failureAlert($error)
        .onAppear {
            model.refresh(context: context)
            DiagnosticLog.shared.activity(.screen, screen: .leftoverStock,
                state: .init(cardCount: model.comparison?.countedQuantity))
        }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh(context: context) } else if phase == .background { model.cancel() }
        }
    }

    private func baselineSection(_ session: LeftoverStockSession) -> some View {
        Section {
            LabeledContent("Website location", value: session.baseline.location.name)
            Text("Baseline saved \(session.baseline.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            Text("Resume this saved count offline. Its baseline stays fixed until you explicitly start a new count.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Frozen website baseline") }
    }

    private var countingSection: some View {
        Section {
            Picker("Game to count", selection: $model.selectedGame) {
                ForEach(model.games, id: \.self) { Text($0).tag($0) }
            }.disabled(model.isBusy).accessibilityIdentifier("leftoverStock.game")
            Button {
                do {
                    let route = try model.prepareScan(context: context)
                    lastScanRoute = route; scanRoute = route
                } catch { self.error = error.localizedDescription }
            } label: { Label("Scan \(model.selectedGame)", systemImage: "viewfinder") }
                .disabled(model.isBusy || !model.canScanSelectedGame || !model.missingListIDs.isEmpty)
                .accessibilityIdentifier("leftoverStock.scan")
            if !model.canScanSelectedGame {
                Text("Set quantities on the source cards below for this game.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.lists) { list in
                NavigationLink {
                    LeftoverCountCardsView(list: list)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(list.name)
                        Text("\(list.quantity) physical cards · Review and edit").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: { Text("Count every remaining card") } footer: {
            Text("Each confirmed scan adds one copy. Use Review and Edit for quantity, printing, condition or language corrections. Set Count below enters an absolute quantity for that exact SKU.")
        }
    }

    private var missingSection: some View {
        Section {
            Label("\(model.missingListIDs.count) saved count lists are unavailable", systemImage: "exclamationmark.triangle")
            Text("Export is blocked so a missing list cannot silently turn into zero stock. Restore the list, or remove its reference and recount those cards.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Remove Missing References") { confirmingMissing = true }.disabled(model.isBusy)
        }
    }

    private func summarySection(_ comparison: LeftoverStockComparison) -> some View {
        Section {
            LabeledContent("Website baseline", value: comparison.baselineQuantity.formatted())
                .accessibilityIdentifier("leftoverStock.baselineQuantity")
            LabeledContent("Physical cards counted", value: comparison.countedQuantity.formatted())
                .accessibilityIdentifier("leftoverStock.countedQuantity")
            LabeledContent("Fewer / not counted", value: comparison.notCountedQuantity.formatted())
            LabeledContent("Extra counted", value: comparison.extraQuantity.formatted())
            Label(model.isComplete ? "Count complete" : "Count in progress",
                  systemImage: model.isComplete ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(model.isComplete ? .green : .secondary)
                .accessibilityIdentifier("leftoverStock.completion")
        } header: { Text("All games · whole location") }
    }

    private func issuesSection(_ comparison: LeftoverStockComparison) -> some View {
        Section {
            ForEach(comparison.issues) { issue in
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.message).font(.subheadline)
                    ForEach(issue.rowIDs, id: \.self) { id in
                        if let item = model.item(id: id) {
                            Button("Review \(item.snapshot.name)") { editingCard = item }.font(.caption)
                        }
                    }
                }
            }
            Button {
                Task { await model.resolveMissingSKUs(context: context) }
            } label: {
                if model.isResolving { ProgressView("Checking exact SKU IDs…") }
                else { Label("Resolve Missing SKU IDs", systemImage: "magnifyingglass") }
            }.disabled(model.isBusy).accessibilityIdentifier("leftoverStock.resolve")
        } header: { Text("Resolve before replacement export") } footer: {
            Text("An exact TCGplayer SKU is required for each printing, condition and language. A missing price does not block a card with a known SKU.")
        }
    }

    private var comparisonSection: some View {
        Section {
            Picker("Compare game", selection: $comparisonGame) {
                ForEach(comparisonGames, id: \.self) { Text($0).tag($0) }
            }.accessibilityIdentifier("leftoverStock.comparisonGame")
            ForEach(visibleRows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.card.name).font(.headline)
                    Text([row.card.set, row.card.number].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(row.card.identity.game) · \(row.card.identity.printing) · \(row.card.identity.condition) · \(row.card.identity.language)")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Website \(row.baselineQuantity) → Counted \(row.countedQuantity)")
                        Spacer()
                        Text(row.status.title).foregroundStyle(.secondary)
                    }.font(.caption)
                    Button("Set Count") { adjustment = row }
                        .font(.subheadline).disabled(model.isBusy || !model.missingListIDs.isEmpty)
                }.padding(.vertical, 3)
            }
            if visibleRows.isEmpty { Text("No matching source or counted cards.").foregroundStyle(.secondary) }
        } header: { Text("Compare and correct") }
    }

    private var instructionsSection: some View {
        Section {
            Text("1. Save a backup of the website's Card Show stock and export this comparison.")
            if model.isComplete && model.comparison?.countedQuantity == 0 {
                Text("2. Your completed count is zero. Clear Card Show only, or delete and recreate only that location. Do not import an empty CSV.")
            } else {
                Text("2. Save the Counted Stock CSV. Open its import preview using Add and check every column mapping, exact card and quantity before clearing anything. Cancel that preview without importing.")
                Text("3. Clear only the Card Show location, or delete and recreate only that location.")
                Text("4. Import the checked Counted Stock CSV using Add. Select Card Show as the destination for every row, verify the preview again, then complete the import.")
            }
            Text("Do not use account-wide Full Replace. This file contains final absolute stock quantities and no prices. It is for an empty Card Show location, not for adding on top of existing stock.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Replace only Card Show on TCGTracking") }
    }

    private var countActions: some View {
        VStack(spacing: 6) {
            if model.isComplete && model.comparison?.countedQuantity == 0 {
                Label("Card Show should be empty", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                    .accessibilityIdentifier("leftoverStock.emptyComplete")
                Text("Clear only that website location. No stock CSV import is needed.").font(.caption)
            } else if model.isComplete {
                Button("Export Counted Stock CSV", systemImage: "square.and.arrow.up") { exportReplacement() }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    .disabled(!model.canExportReplacement || context.hasChanges)
                    .accessibilityIdentifier("leftoverStock.exportReplacement")
            } else {
                Button("Finish Count", systemImage: "checkmark.circle") { confirmingFinish = true }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    .disabled(model.isBusy || !model.missingListIDs.isEmpty || model.comparison?.canExport != true || context.hasChanges)
                    .accessibilityIdentifier("leftoverStock.finish")
            }
            Text(model.isComplete ? "Edits reopen this count. Website stock changes only after import." : "Finish only after counting the whole location, across all games.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding().frame(maxWidth: .infinity).background(.bar)
    }

    private func scannerClosed() {
        if let route = lastScanRoute { model.scanClosed(route, context: context) }
        lastScanRoute = nil
    }
    private func exportReplacement() {
        do {
            exportText = try model.replacementCSV(context: context)
            exportFilename = "Card-Show-counted-stock"; exporting = true
        } catch { self.error = error.localizedDescription }
    }
    private func exportComparison() {
        do {
            exportText = try model.comparisonCSV(context: context)
            exportFilename = "Card-Show-stock-comparison"; exporting = true
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor private struct LeftoverStockQuantityView: View {
    let row: LeftoverStockComparisonRow
    let save: (Int) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var quantity: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(row: LeftoverStockComparisonRow, save: @escaping (Int) throws -> Void) {
        self.row = row; self.save = save
        _quantity = State(initialValue: String(row.countedQuantity))
    }
    private var value: Int? {
        guard !quantity.isEmpty, quantity.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(quantity), (0...LeftoverStockReconciliation.maximumQuantity).contains(count) else { return nil }
        return count
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(row.card.name).font(.headline)
                    Text("\(row.card.identity.printing) · \(row.card.identity.condition) · \(row.card.identity.language)")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Website quantity", value: row.baselineQuantity.formatted())
                    TextField("Physical quantity counted", text: $quantity).keyboardType(.numberPad).focused($focused)
                        .accessibilityIdentifier("leftoverStock.quantityInput")
                } footer: { Text("Enter the total copies you physically have for this exact SKU. Zero removes it from your counted stock.") }
            }
            .navigationTitle("Set Count").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let value else { return }
                        do { try save(value); dismiss() } catch { self.error = error.localizedDescription }
                    }.disabled(value == nil).accessibilityIdentifier("leftoverStock.saveQuantity")
                }
            }
            .failureAlert($error)
            .onAppear { focused = true }
        }
    }
}
