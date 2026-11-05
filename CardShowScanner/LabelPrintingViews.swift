import SwiftUI
import UIKit

/// Printer settings also reflect the connection started from Price Tags.
@MainActor struct LabelPrinterSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var queue = LabelPrintQueue.shared
    @State private var printer = NiimbotPrinter.shared

    var body: some View {
        Form {
            LabelPrinterConnectionSection(printer: printer)
            Section("Labels") {
                NavigationLink { LabelPrintQueueView() } label: {
                    LabeledContent("Saved print queue", value: queue.entries.count.formatted())
                }.accessibilityIdentifier("labelPrinter.queue")
                Text("Create labels from Show → Price Tags. Asking prices and label copies are local drafts; printing never changes stock, costs, sales, or budgets.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text("Supports NIIMBOT D110 and D110-M. Charge the printer, load matching labels and close its lid. Price Tags searches automatically; use Search to try again. Check one test label before printing a batch.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("labelPrinter.hardwareNote")
                DisclosureGroup("Printer protocol credits") {
                    Text(NiimbotProtocol.thirdPartyNotice)
                        .font(.footnote).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Label Printer").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ClearLabelPrintQueueButton(identifier: "labelPrinter.clearQueue") }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { queue.stop(using: printer) }
        }
        .onDisappear { if printer.isConfiguringPaper || !printer.isConnected { printer.stop() } }
    }
}

@MainActor private struct LabelPrinterConnectionSection: View {
    let printer: NiimbotPrinter
    @State private var queue = LabelPrintQueue.shared
    @State private var paperPreferences = LabelPaperPreferences.shared
    private var paperBusy: Bool { queue.isPrinting || printer.isPrinting || printer.isConfiguringPaper }

    @ViewBuilder var body: some View {
        Section {
            Label(printer.isConnected ? "\(printer.modelName) connected" : "Printer not connected",
                  systemImage: printer.isConnected ? "checkmark.circle.fill" : "printer")
                .foregroundStyle(printer.isConnected ? Color.green : Color.primary)
                .accessibilityIdentifier("labelPrinter.connection")
            Text(printer.status).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("labelPrinter.status")
            if let error = printer.error {
                Text(error).font(.footnote).foregroundStyle(.orange)
                    .accessibilityIdentifier("labelPrinter.error")
            }
            if printer.isConnected {
                Button("Disconnect", role: .destructive) { printer.disconnect() }
                    .disabled(paperBusy).accessibilityIdentifier("labelPrinter.disconnect")
            } else {
                Button { printer.startSearch() } label: {
                    HStack {
                        Text(printer.isScanning ? "Search Again" : "Search for D110 / D110-M")
                        Spacer()
                        if printer.isScanning { ProgressView() }
                    }
                }.disabled(paperBusy).accessibilityIdentifier("labelPrinter.search")
                ForEach(printer.devices) { device in
                    Button { printer.connect(device.id) } label: {
                        Label(device.name, systemImage: "printer")
                    }.disabled(paperBusy).accessibilityIdentifier("labelPrinter.device." + device.id.uuidString)
                }
            }
        } header: { Text("Bluetooth printer") } footer: {
            Text("Disconnect the printer in other apps before searching. Allow Bluetooth access and keep this app open while connecting and printing.")
        }
        Section {
            LabeledContent("Last used label size", value: paperPreferences.size.title)
                .accessibilityIdentifier("labelPrinter.paperSize")
            Picker("Paper type", selection: Binding(get: { printer.paperMode }, set: { mode in
                guard !paperBusy else { return }
                printer.selectPaperMode(mode)
            })) {
                ForEach(NiimbotPaperMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented).disabled(paperBusy)
                .accessibilityIdentifier("labelPrinter.paperMode")
            Button("Apply Paper Type") {
                guard !paperBusy else { return }
                printer.applyPaperMode()
            }.frame(minHeight: 44).disabled(!printer.isConnected || paperBusy)
                .accessibilityIdentifier("labelPrinter.applyPaperMode")
            Button("Read Printer Setting") {
                guard !paperBusy else { return }
                printer.readPaperMode()
            }.frame(minHeight: 44).disabled(!printer.isConnected || paperBusy)
                .accessibilityIdentifier("labelPrinter.readPaperMode")
            if printer.isConfiguringPaper { ProgressView().accessibilityLabel("Updating paper setting") }
            if let status = printer.paperModeStatus {
                Text(status).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("labelPrinter.paperModeStatus")
            }
        } header: { Text("Paper type") } footer: {
            Text("Choose Gap for standard labels separated by gaps, or Transparent for clear labels. The choice is applied when printing. Read Printer Setting reads the configured type. Label size is remembered from label preparation; check it matches the loaded roll.")
        }
    }
}

private enum InventoryLabelStep: Hashable { case configure, review, queue }

private struct LabelSelectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// The sheet owns navigation. All values copied here remain independent of stock.
@MainActor struct InventoryLabelFlowView: View {
    let inventory: [ShowInventoryItem]
    let marketQuotes: [UUID: TagMarketQuote]
    let mode: InventoryLabelBatchMode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [InventoryLabelStep]
    @State private var search = ""
    @State private var selectedIDs: Set<UUID>
    @State private var drafts: [InventoryLabelDraft]
    @State private var style: InventoryLabelStyle = .cardDetails
    @State private var paper: InventoryLabelSize
    @State private var paperPreferences: LabelPaperPreferences
    @State private var editing: InventoryLabelDraft?
    @State private var queue = LabelPrintQueue.shared
    @State private var printer = NiimbotPrinter.shared
    @State private var approvals = TagApprovalStore.shared
    @State private var error: String?
    @State private var approvedNotice: String?
    @State private var showingPricingSettings = false
    @State private var acknowledgedPricingWarnings = false
    @State private var keepExistingStickerIDs: Set<UUID> = []
    @State private var showingDiscard = false
    @State private var preparing = false
    @State private var expandedReviewIDs: Set<UUID> = []
    @State private var showingIndividualEdits = false
    @State private var showingBatchPriceEditor = false

    init(inventory: [ShowInventoryItem], initialInventoryID: UUID? = nil,
         marketQuotes: [UUID: TagMarketQuote] = [:], mode: InventoryLabelBatchMode = .custom,
         paperPreferences: LabelPaperPreferences = .shared) {
        self.inventory = inventory
        self.marketQuotes = marketQuotes
        self.mode = mode
        _paperPreferences = State(initialValue: paperPreferences)
        _paper = State(initialValue: paperPreferences.size)
        let initial = inventory.first { $0.id == initialInventoryID && $0.quantity > 0 }
        let batchDrafts = InventoryLabelBatch.drafts(mode: mode, inventory: inventory,
            marketQuotes: marketQuotes, store: .shared)
        var initialDrafts = initial.map {
            [InventoryLabelBatch.draft(for: $0, mode: .custom, marketQuotes: marketQuotes, store: .shared)]
        } ?? batchDrafts
        for index in initialDrafts.indices { initialDrafts[index].paperSize = paperPreferences.size }
        _selectedIDs = State(initialValue: Set(initialDrafts.map(\.id)))
        _drafts = State(initialValue: initialDrafts)
        _path = State(initialValue: initialDrafts.isEmpty ? [] : [.configure])
    }

    private var available: [ShowInventoryItem] {
        inventory.filter { $0.quantity > 0 }.sorted {
            $0.card.name.localizedStandardCompare($1.card.name) == .orderedAscending
        }
    }
    private var filtered: [ShowInventoryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return available.filter { item in
            query.isEmpty || [item.card.name, item.card.set, item.card.number,
                item.card.identity.condition, item.card.identity.printing].joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }
    private var orderedDrafts: [InventoryLabelDraft] {
        drafts.sorted {
            let first = TagPricingContext.review(for: $0, store: approvals).priority
            let second = TagPricingContext.review(for: $1, store: approvals).priority
            if first != second { return first < second }
            return $0.cardName.localizedStandardCompare($1.cardName) == .orderedAscending
        }
    }
    private var printableDrafts: [InventoryLabelDraft] {
        drafts.filter { draft in
            InventoryLabelBatch.shouldPrint(draft, approval: approvals.record(for: draft.id),
                reprintAll: mode == .all, keepExisting: keepExistingStickerIDs.contains(draft.id))
        }
    }
    private var labelCount: Int { printableDrafts.reduce(0) { $0 + $1.copies } }
    private var bulkCount: Int { drafts.filter(\.isBulk).reduce(0) { $0 + $1.copies } }
    private var requiresManualReview: Bool { drafts.contains { !$0.pricingWarnings.isEmpty } }
    private var validation: String? {
        guard !drafts.isEmpty else { return "Select at least one card." }
        guard approvals.isLoaded else { return approvals.error ?? "Reload saved tag approvals before continuing." }
        if let draft = drafts.first(where: { !$0.isBulk && $0.tag == nil }) {
            return "Enter a whole-dollar asking price for \(draft.cardName). A known $0 price is valid; cents are not allowed."
        }
        if drafts.contains(where: { !(1...InventoryLabelDraft.maximumCopies).contains($0.copies) }) {
            return "Choose 1–100 labels per card. Matched stock quantities have not been reduced automatically."
        }
        if labelCount > LabelPrintQueue.maximumLabels {
            return "This batch has \(labelCount.formatted()) labels. Reduce copies or select fewer cards to stay within 250 labels."
        }
        return nil
    }

    var body: some View {
        NavigationStack(path: $path) {
            selection
                .navigationDestination(for: InventoryLabelStep.self) { step in
                    Group {
                        switch step {
                        case .configure: configuration
                        case .review: review
                        case .queue: LabelPrintQueueView()
                        }
                    }
                }
        }
        .toolbar { closeToolbar }
        .sheet(item: $editing) { draft in
            InventoryLabelEditor(draft: draft) { updated in
                if let index = drafts.firstIndex(where: { $0.id == updated.id }) {
                    drafts[index] = updated
                    keepExistingStickerIDs.remove(updated.id)
                    resetApprovalReview()
                }
            }
        }
        .sheet(isPresented: $showingPricingSettings) {
            TagPricingSettingsView(store: approvals) { updateProfitInputs() }
        }
        .sheet(isPresented: $showingBatchPriceEditor) {
            LabelBatchPriceEditor(cardCount: drafts.filter { !$0.isBulk }.count) { cents in
                for index in drafts.indices where !drafts[index].isBulk {
                    drafts[index].askingPriceText = InventoryLabelDraft.inputText(cents)
                    drafts[index].isManualOverride = true
                }
                keepExistingStickerIDs.removeAll()
                resetApprovalReview()
            }
        }
        .alert("Label preparation", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .alert("Discard saved label queue?", isPresented: $showingDiscard) {
            Button("Discard Queue", role: .destructive) {
                do {
                    if queue.isLoaded { try queue.clear() } else { try queue.discardSavedQueue() }
                } catch { self.error = error.localizedDescription }
            }
            Button("Keep Queue", role: .cancel) {}
        } message: {
            Text("This removes the saved label queue and its completion receipts. Check any uncertain physical labels first. Inventory and financial records are unaffected.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stopPrinting() }
        }
        .onAppear { updatePaperSize(paperPreferences.size) }
        .onChange(of: paperPreferences.size) { _, size in updatePaperSize(size) }
        .onDisappear {
            stopPrinting()
            if printer.isConfiguringPaper || !printer.isConnected { printer.stop() }
        }
    }

    @ToolbarContentBuilder private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Close") { endEditing(); stopPrinting(); dismiss() }
                .accessibilityIdentifier("labels.close")
        }
    }

    private var selection: some View {
        List {
            if available.isEmpty {
                ContentUnavailableView("No available cards", systemImage: "shippingbox",
                    description: Text("Add cards to Show Inventory before making labels."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
            ForEach(filtered) { item in
                Button {
                    if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
                    else { selectedIDs.insert(item.id) }
                } label: {
                    HStack(spacing: 12) {
                        LabelInventoryThumbnail(card: item.card)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.card.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text([item.card.set, item.card.number].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(InventoryLabelDraft.shortCondition(item.card.identity.condition)) · \(item.quantity.formatted()) available")
                                .font(.caption).foregroundStyle(.secondary)
                            if let saved = approvals.record(for: item.id) {
                                Text("Approved \(saved.approvedTag.displayText)\(saved.needsLabels ? " · Needs Labels" : "")")
                                    .font(.caption).foregroundStyle(saved.needsLabels ? Color.orange : Color.secondary)
                            }
                            TagRepricingSummary(evaluation: TagPricingContext.review(
                                for: TagPricingContext.draft(for: item, marketQuotes: marketQuotes, store: approvals),
                                store: approvals))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title2).foregroundStyle(selectedIDs.contains(item.id) ? Color.indigo : Color.secondary)
                            .contentTransition(.identity)
                            .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    }.contentShape(Rectangle())
                }.buttonStyle(LabelSelectionButtonStyle())
                    .accessibilityLabel("\(item.card.name), \(item.quantity) available")
                    .accessibilityAddTraits(selectedIDs.contains(item.id) ? .isSelected : [])
                    .accessibilityIdentifier("labels.select." + item.id.uuidString)
            }
        }
        .navigationTitle("Select Label Cards").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name, set, or card number")
        .scrollDismissesKeyboard(.interactively)
        .onSubmit(of: .search) { endEditing() }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button(search.isEmpty ? "Select All" : "Select All Results") {
                    selectedIDs.formUnion(filtered.map(\.id))
                }.disabled(filtered.isEmpty).accessibilityIdentifier("labels.selectAll")
                Spacer()
                Button("Clear") { selectedIDs.removeAll() }
                    .disabled(selectedIDs.isEmpty).accessibilityIdentifier("labels.clearSelection")
            }.font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 12).background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { ClearLabelPrintQueueButton() }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { endEditing() }.fixedSize().frame(minWidth: 64, minHeight: 44)
                    .accessibilityIdentifier("labels.selection.keyboardDone")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LabelActionBar {
                Text("\(selectedIDs.count.formatted()) cards selected").font(.subheadline)
                    .accessibilityIdentifier("labels.selectedCount")
                Button("Continue") { endEditing(); synchronizeDrafts(); path.append(.configure) }
                    .buttonStyle(.borderedProminent).disabled(selectedIDs.isEmpty)
                    .accessibilityIdentifier("labels.continueSelection")
            }
        }
        .accessibilityIdentifier("labels.selection")
    }

    private var configuration: some View {
        List {
            savedQueueSection
            pricingSettingsSection
            approvalNoticeSection
            pricingWarningsSection
            if drafts.contains(where: { $0.tag == nil }) {
                Section("Missing prices") {
                    Text("\(drafts.filter { $0.tag == nil }.count.formatted()) cards need a price. Edit them individually, or leave them out of this batch.")
                        .font(.footnote).foregroundStyle(.orange)
                    Button("Skip Unpriced Cards") {
                        let missing = Set(drafts.filter { $0.tag == nil }.map(\.id))
                        drafts.removeAll { missing.contains($0.id) }
                        selectedIDs.subtract(missing)
                        keepExistingStickerIDs.subtract(missing)
                        resetApprovalReview()
                    }.accessibilityIdentifier("labels.skipUnpriced")
                }
            }
            Section("Label layout") {
                Picker("Style", selection: $style) {
                    ForEach(InventoryLabelStyle.allCases) { value in
                        Text(value.title).tag(value).accessibilityIdentifier("labels.style." + value.rawValue)
                    }
                }.accessibilityIdentifier("labels.style")
                Picker("Physical paper", selection: Binding(get: { paper }, set: { size in
                    updatePaperSize(size)
                    paperPreferences.select(size)
                })) {
                    ForEach(InventoryLabelSize.allCases) { value in
                        Text(value.title).tag(value).accessibilityIdentifier("labels.paper." + value.rawValue)
                    }
                }.accessibilityIdentifier("labels.paper")
                Text("Your last label size is remembered. Check it matches the loaded roll. The printable area is 12 mm wide.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let draft = printableDrafts.first {
                Section("Print preview") {
                    InventoryLabelPreview(draft: draft)
                    Text("\(draft.cardName) · \(paper.title)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Match Stock Quantities") { matchQuantities() }
                    .accessibilityIdentifier("labels.matchQuantities")
                Button("Use One Label per Card") {
                    for index in drafts.indices { drafts[index].copies = 1 }
                    resetApprovalReview()
                }.accessibilityIdentifier("labels.oneEach")
            } header: { Text("Copies") } footer: {
                Text(mode == .custom
                     ? "Custom batches start with one copy per entry. Match Stock Quantities makes one label per physical card. Maximum 100 per entry and 250 labels per batch. Bulk cards do not print individual tags."
                     : "One label per available physical copy is selected automatically. Use One Label per Card to make one per inventory entry. Maximum 100 per entry and 250 labels per batch. Bulk cards do not print individual tags.")
            }
            Section("Bulk price changes") {
                Button("Use Suggested Prices") {
                    for index in drafts.indices where drafts[index].pricing.tag != nil {
                        drafts[index].useSuggestedPrice()
                    }
                    keepExistingStickerIDs.removeAll()
                    resetApprovalReview()
                }.accessibilityIdentifier("labels.useSuggestedPrices")
                if mode == .custom {
                    Button("Set Same Price for Selected Cards") { showingBatchPriceEditor = true }
                        .disabled(drafts.allSatisfy(\.isBulk))
                        .accessibilityIdentifier("labels.setBatchPrice")
                }
                Text("These changes stay in the draft until approval. Use Suggested Prices replaces selected manual prices; cost and profit warnings still require review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Asking prices & copies") {
                if drafts.count > 1 {
                    DisclosureGroup("Edit Individual Cards (\(drafts.count.formatted()))", isExpanded: $showingIndividualEdits) {
                        configurationRows
                    }.accessibilityIdentifier("labels.individualEdits")
                } else {
                    configurationRows
                }
            }
            if bulkCount > 0 {
                Section("2 for $1 category") {
                    Text("\(bulkCount.formatted()) selected bulk copies. No individual tags will be printed.")
                        .font(.footnote).accessibilityIdentifier("labels.bulkCount")
                }
            }
            if let validation {
                Section { Label(validation, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange) }
                    .accessibilityIdentifier("labels.validation")
            }
            Section {
                Text("Market below $0.75: 2 for $1 category. $0.75 to under $1: $1. $1 to under $100: round down to $1. $100 and above: round down to $5. Individual tags always use whole dollars. Saved manual prices stay until you choose Use Suggested Price. Approval saves pricing history without changing inventory, costs or budgets.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Label Details").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { ClearLabelPrintQueueButton() } }
        .onChange(of: style) { _, value in for index in drafts.indices { drafts[index].style = value } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LabelActionBar {
                VStack(spacing: 10) {
                    HStack {
                        Text("\(labelCount.formatted()) labels").font(.subheadline).monospacedDigit()
                            .accessibilityIdentifier("labels.totalCount")
                        Spacer()
                        Button("Review Details") { path.append(.review) }
                            .font(.subheadline).disabled(validation != nil || preparing)
                            .accessibilityIdentifier("labels.continueReview")
                    }
                    approvalButton
                }
            }
        }
        .accessibilityIdentifier("labels.configuration")
    }

    private func updatePaperSize(_ size: InventoryLabelSize) {
        paper = size
        for index in drafts.indices { drafts[index].paperSize = size }
    }

    @ViewBuilder private var approvalNoticeSection: some View {
        if let approvedNotice {
            Section {
                Text(approvedNotice).font(.footnote).foregroundStyle(.green)
                    .accessibilityIdentifier("labels.approvedNotice")
            }
        }
    }

    @ViewBuilder private var pricingWarningsSection: some View {
        if requiresManualReview {
            Section("Price warnings") {
                ForEach(Array(Set(drafts.flatMap(\.pricingWarnings))).sorted(), id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Toggle("I reviewed the warnings and approve a manual override", isOn: $acknowledgedPricingWarnings)
                    .accessibilityIdentifier("labels.acknowledgePricingWarnings")
            }
        }
    }

    private var approvalButton: some View {
        Button { prepareQueue() } label: {
            Group {
                if preparing { ProgressView() }
                else { Text(queue.isLoaded && queue.entries.isEmpty && labelCount > 0 ? "Approve & Prepare Labels" : "Approve Prices") }
            }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .disabled(preparing || validation != nil || (requiresManualReview && !acknowledgedPricingWarnings) || queue.isPrinting)
        .accessibilityIdentifier("labels.prepare")
    }

    private var review: some View {
        List {
            savedQueueSection
            pricingSettingsSection
            approvalNoticeSection
            Section("Review before preparing") {
                LabeledContent("Total labels", value: labelCount.formatted())
                    .accessibilityIdentifier("labels.reviewCount")
                if bulkCount > 0 {
                    LabeledContent("Bulk copies · no individual tags", value: bulkCount.formatted())
                        .accessibilityIdentifier("labels.reviewBulkCount")
                }
                LabeledContent("Paper", value: paper.title)
                LabeledContent("Style", value: style.title)
                Text(mode == .all
                     ? "Print All includes replacement copies of unchanged individual tags. Preparing approves the selected prices; printing still needs a separate Print action."
                     : "Preparing approves selected prices and saves the market review baseline. Unchanged, already-labeled stickers are skipped. Printing needs a separate Print action.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            pricingWarningsSection
            ForEach(orderedDrafts) { draft in
                if drafts.count > 1 {
                    DisclosureGroup(isExpanded: Binding(get: { expandedReviewIDs.contains(draft.id) }, set: {
                        if $0 { expandedReviewIDs.insert(draft.id) } else { expandedReviewIDs.remove(draft.id) }
                    })) {
                        reviewDetails(draft, summaryVisible: true)
                    } label: { reviewSummary(draft) }
                    .accessibilityIdentifier("labels.expandReview." + draft.id.uuidString)
                } else {
                    Section { reviewDetails(draft) } header: { Text(draft.cardName) }
                }
            }
            TagBundleReviewSection(lines: TagPricingContext.bundleLines(drafts: drafts,
                inventory: inventory, preferences: approvals.preferences), preferences: approvals.preferences)
            if let validation {
                Section { Text(validation).font(.footnote).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Review Labels").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { ClearLabelPrintQueueButton() } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LabelActionBar {
                Text("\(labelCount.formatted()) labels · \(paper.title)").font(.caption)
                approvalButton
            }
        }
        .accessibilityIdentifier("labels.review")
    }

    private var configurationRows: some View {
        ForEach(orderedDrafts) { draft in
            Button { editing = draft } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(draft.cardName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text("\(draft.condition) · \(draft.copies.formatted()) \(draft.isBulk ? "bulk copies" : "copies")")
                            .font(.caption).foregroundStyle(.secondary)
                        TagRepricingSummary(evaluation: TagPricingContext.review(for: draft, store: approvals))
                        if draft.isManualOverride {
                            Text("Manual price retained").font(.caption).foregroundStyle(.secondary)
                        }
                        if let warning = draft.pricingWarnings.first {
                            Text(warning).font(.caption).foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(draft.priceText ?? "Enter price")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(draft.tag == nil ? Color.orange : Color.primary)
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("labels.edit." + draft.id.uuidString)
        }
    }

    private func reviewSummary(_ draft: InventoryLabelDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(draft.cardName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(draft.priceText ?? "Needs input").font(.subheadline.bold())
                    .foregroundStyle(draft.tag == nil ? Color.orange : Color.primary)
                    .accessibilityIdentifier("labels.review.price." + draft.id.uuidString)
            }
            HStack {
                Text(draft.condition)
                Text("·")
                Text("\(draft.copies.formatted()) \(draft.isBulk ? "bulk copies" : "copies")")
                    .accessibilityIdentifier("labels.review.copies." + draft.id.uuidString)
                Spacer(minLength: 4)
                if !draft.pricingWarnings.isEmpty {
                    Label("Review", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }.font(.caption).foregroundStyle(.secondary)
            if draft.isManualOverride { Text("Manual price retained").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 4)
    }

    @ViewBuilder private func reviewDetails(_ draft: InventoryLabelDraft, summaryVisible: Bool = false) -> some View {
        if draft.isBulk {
            Label("2 for $1 category — no individual tag", systemImage: "tray.2")
        } else {
            InventoryLabelPreview(draft: draft)
        }
        if !summaryVisible {
            LabeledContent("Asking price", value: draft.priceText ?? "Needs input")
                .accessibilityIdentifier("labels.review.price." + draft.id.uuidString)
            LabeledContent("Condition", value: draft.condition)
            LabeledContent("Copies", value: draft.copies.formatted())
                .accessibilityIdentifier("labels.review.copies." + draft.id.uuidString)
        }
        TagRepricingSummary(evaluation: TagPricingContext.review(for: draft, store: approvals))
        if draft.isManualOverride {
            Text("Manual price retained. Use Suggested Price in the editor to replace it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(draft.pricingWarnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange)
        }
        TagPricingDisclosure(draft: draft)
        if !draft.isBulk {
            if mode == .all {
                Label("Print All includes this tag, even if already labeled.", systemImage: "printer")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let saved = approvals.record(for: draft.id), saved.approvedTag == draft.tag, !saved.needsLabels {
                Label("Existing sticker retained · no reprint", systemImage: "checkmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if canKeepExistingSticker(for: draft) {
                Toggle("Keep Existing Sticker", isOn: keepExistingStickerBinding(for: draft.id))
                    .accessibilityIdentifier("labels.keepExistingSticker." + draft.id.uuidString)
                Text("Confirm you checked the physical \(draft.priceText ?? "") sticker and already have the labels you need. This records it as labeled and skips printing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Button("Edit Price or Copies") { editing = draft }
            .accessibilityIdentifier("labels.reviewEdit." + draft.id.uuidString)
    }

    private var pricingSettingsSection: some View {
        Section {
            DisclosureGroup("Pricing settings") {
                LabeledContent("Minimum desired profit", value: approvals.preferences.minimumDesiredProfitCents
                    .map { ShowBudgetMoney.decimal($0).money } ?? "Not configured")
                Text("Unknown acquisition cost or an unset profit target requires a manual review override.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Edit Pricing Settings") { showingPricingSettings = true }
                    .disabled(!approvals.isLoaded).accessibilityIdentifier("labels.pricingSettings")
            }
            if !approvals.isLoaded {
                Text(approvals.error ?? "Saved tag approvals are unavailable.")
                    .font(.footnote).foregroundStyle(.orange)
                Button("Reload Tag Approvals") { approvals.reload(); updateProfitInputs() }
                    .accessibilityIdentifier("labels.reloadApprovals")
            }
        }
    }

    @ViewBuilder private var savedQueueSection: some View {
        if !queue.isLoaded || !queue.entries.isEmpty {
            Section("Saved queue needs review") {
                Text(queue.isLoaded
                     ? "A queue with \(queue.entries.count.formatted()) labels is saved. Review it or explicitly discard it before preparing this batch."
                     : (queue.error ?? "Your saved queue could not be opened."))
                    .font(.footnote).foregroundStyle(.orange)
                Button("Review Saved Queue") { path.append(.queue) }
                    .accessibilityIdentifier("labels.reviewSavedQueue")
                if !queue.isLoaded {
                    Button("Reload Saved Queue") { queue.reload() }
                        .accessibilityIdentifier("labels.reloadQueue")
                }
                Button("Discard Saved Queue", role: .destructive) { showingDiscard = true }
                    .disabled(queue.isPrinting).accessibilityIdentifier("labels.discardQueue")
            }
        }
    }

    private func synchronizeDrafts() {
        let previous = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
        drafts = available.filter { selectedIDs.contains($0.id) }.map { item in
            var draft = previous[item.id] ?? InventoryLabelBatch.draft(for: item, mode: mode,
                marketQuotes: marketQuotes, store: approvals)
            draft.style = style; draft.paperSize = paper
            return draft
        }
        keepExistingStickerIDs.formIntersection(selectedIDs)
        resetApprovalReview()
    }
    private func matchQuantities() {
        let quantities = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0.quantity) })
        for index in drafts.indices { drafts[index].copies = quantities[drafts[index].id] ?? 1 }
        resetApprovalReview()
    }
    private func updateProfitInputs() {
        let items = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        for index in drafts.indices {
            guard let item = items[drafts[index].id] else { continue }
            drafts[index].profitInputs = approvals.preferences.profitInputs(for: item)
        }
        resetApprovalReview()
    }
    private func resetApprovalReview() {
        acknowledgedPricingWarnings = false
        approvedNotice = nil
    }
    private func canKeepExistingSticker(for draft: InventoryLabelDraft) -> Bool {
        guard let tag = draft.tag, !draft.isBulk else { return false }
        return approvals.record(for: draft.id).map { $0.approvedTag == tag } ?? true
    }
    private func keepExistingStickerBinding(for id: UUID) -> Binding<Bool> {
        Binding(get: { keepExistingStickerIDs.contains(id) }, set: { keep in
            if keep { keepExistingStickerIDs.insert(id) }
            else { keepExistingStickerIDs.remove(id) }
            resetApprovalReview()
        })
    }
    private func prepareQueue() {
        guard validation == nil, (!requiresManualReview || acknowledgedPricingWarnings),
              approvals.isLoaded, !queue.isPrinting, !preparing else { return }
        preparing = true
        defer { preparing = false }
        var pricesSaved = false
        do {
            let requests = try drafts.map { draft -> TagApprovalRequest in
                guard let tag = draft.tag else { throw InventoryLabelFailure.invalidPrice }
                return TagApprovalRequest(id: draft.id, approvedTag: tag, currentMarket: draft.marketValue,
                    isManualOverride: draft.isManualOverride || !draft.pricingWarnings.isEmpty)
            }
            try approvals.approve(requests, keepingExistingStickerIDs: keepExistingStickerIDs)
            pricesSaved = true
            let draftsToPrint = printableDrafts
            guard !draftsToPrint.isEmpty else {
                approvedNotice = "Approved prices saved. No individual labels need printing."
                return
            }
            guard queue.isLoaded, queue.entries.isEmpty else {
                approvedNotice = "Approved prices saved. \(draftsToPrint.reduce(0) { $0 + $1.copies }.formatted()) labels still need printing. Clear the saved print queue to prepare replacements."
                return
            }
            var entries: [LabelQueueEntry] = []
            for draft in draftsToPrint {
                let raster = try InventoryLabelRenderer.renderRaster(draft)
                for copy in 1...draft.copies {
                    entries.append(try LabelQueueEntry(draft: draft, raster: raster, copyNumber: copy,
                        pricingRevisionID: approvals.record(for: draft.id)?.priceRevisionID))
                }
            }
            try queue.replace(with: entries)
            path.append(.queue)
        } catch {
            self.error = pricesSaved
                ? "Approved prices were saved. Labels still needed remain marked Needs Labels. Review the issue and retry preparation. \(error.localizedDescription)"
                : error.localizedDescription
        }
    }
    private func stopPrinting() { queue.stop(using: printer) }
    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// Text edits stay in this small sheet and reach the parent only on Save.
@MainActor private struct InventoryLabelEditor: View {
    let draft: InventoryLabelDraft
    let onSave: (InventoryLabelDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var price: String
    @State private var copies: String
    @State private var baseDraft: InventoryLabelDraft
    @State private var bitmap: InventoryLabelBitmap?
    @State private var previewError: String?
    @State private var previewPrice: String?
    @FocusState private var focus: Field?
    private enum Field { case price, copies }

    init(draft: InventoryLabelDraft, onSave: @escaping (InventoryLabelDraft) -> Void) {
        self.draft = draft; self.onSave = onSave
        _price = State(initialValue: draft.priceCents.map { String($0 / 100) } ?? draft.askingPriceText)
        _copies = State(initialValue: String(draft.copies))
        _baseDraft = State(initialValue: draft)
    }
    private var edited: InventoryLabelDraft {
        var value = baseDraft
        value.askingPriceText = price
        value.copies = Int(copies) ?? 0
        if !value.isBulk, ShowBudgetMoney.parse(price) != baseDraft.priceCents {
            value.isManualOverride = true
        }
        return value
    }
    private var issue: String? {
        if !edited.isBulk {
            guard edited.priceCents != nil else { return "Enter a whole-dollar asking price. $0 is valid." }
            guard edited.tag != nil else { return "Individual tags use whole dollars. Remove cents before saving." }
        }
        guard (1...InventoryLabelDraft.maximumCopies).contains(edited.copies) else { return "Enter 1–100 copies. The requested count has not been reduced." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(draft.cardName).font(.headline)
                    Text([draft.cardNumber, draft.condition].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                    LabeledContent("Paper", value: draft.paperSize.title)
                }
                Section("Asking price") {
                    if edited.isBulk {
                        Label("2 for $1 category", systemImage: "tray.2")
                        Text("Market below $0.75 belongs in the bulk category. These cards do not have individual price tags.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("$").foregroundStyle(.secondary)
                            TextField("Required", text: $price).keyboardType(.decimalPad)
                                .focused($focus, equals: .price).accessibilityIdentifier("labels.editor.price")
                        }
                        Text("Use whole dollars. Manual prices stay until you choose Use Suggested Price.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Use Suggested Price") {
                        baseDraft.useSuggestedPrice()
                        price = baseDraft.priceCents.map { String($0 / 100) } ?? baseDraft.askingPriceText
                        focus = nil
                        updatePreview()
                    }.disabled(baseDraft.pricing.tag == nil)
                        .accessibilityIdentifier("labels.editor.useSuggestedPrice")
                    ForEach(edited.pricingWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    TagPricingDisclosure(draft: edited)
                }
                Section(edited.isBulk ? "Bulk copies for bundle review" : "Copies") {
                    TextField("1–100", text: $copies).keyboardType(.numberPad)
                        .focused($focus, equals: .copies).accessibilityIdentifier("labels.editor.copies")
                }
                if let issue {
                    Section { Text(issue).font(.footnote).foregroundStyle(.orange) }
                        .accessibilityIdentifier("labels.editor.validation")
                }
                if !edited.isBulk {
                    Section("Actual print preview") {
                        if let bitmap {
                            LabelBitmapImage(image: bitmap.previewImage,
                                description: previewDescription)
                        }
                        else { Text(previewError ?? "Enter a price, then update the preview.").foregroundStyle(.secondary) }
                        Button("Update Preview") { focus = nil; updatePreview() }
                            .disabled(issue != nil).accessibilityIdentifier("labels.editor.preview")
                        if previewPrice != price {
                            Text("Update the preview to see your edited price.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Edit Label").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("labels.editor.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) { ClearLabelPrintQueueButton(identifier: "labels.editor.clearQueue") }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }.accessibilityIdentifier("labels.editor.keyboardDone")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                LabelActionBar {
                    Text(draft.paperSize.title).font(.caption)
                    Button("Save Label") {
                        focus = nil
                        do {
                            if !edited.isBulk {
                                try edited.validate()
                                _ = try InventoryLabelRenderer.render(edited)
                            }
                            onSave(edited); dismiss()
                        } catch { bitmap = nil; previewError = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(issue != nil)
                        .accessibilityIdentifier("labels.editor.save")
                }
            }
            .onAppear { updatePreview() }
            .onChange(of: price) { _, text in if text.count > 40 { price = String(text.prefix(40)) } }
            .onChange(of: copies) { _, text in if text.count > 10 { copies = String(text.prefix(10)) } }
        }
        .accessibilityIdentifier("labels.editor")
    }

    private func updatePreview() {
        guard !edited.isBulk else { bitmap = nil; previewError = nil; return }
        do {
            bitmap = try InventoryLabelRenderer.render(edited)
            previewError = nil; previewPrice = price
        } catch { bitmap = nil; previewError = error.localizedDescription }
    }
    private var previewDescription: String {
        let amount = previewPrice.flatMap(ShowBudgetMoney.parse).map { StickerPrice.individual($0).displayText } ?? "Price required"
        return "\(draft.style.title), \(amount), \(draft.paperSize.title)"
    }
}

@MainActor private struct InventoryLabelPreview: View {
    let draft: InventoryLabelDraft
    @State private var image: UIImage?
    @State private var error: String?

    var body: some View {
        Group {
            if let image {
                LabelBitmapImage(image: image,
                    description: "\(draft.style.title), \(draft.priceText ?? "Price required"), \(draft.paperSize.title)")
            }
            else { Text(error ?? "Preparing preview…").font(.footnote).foregroundStyle(.secondary) }
        }.onAppear { render() }.onChange(of: draft) { _, _ in render() }
    }
    private func render() {
        do { image = try InventoryLabelRenderer.render(draft).previewImage; error = nil }
        catch { image = nil; self.error = error.localizedDescription }
    }
}

private struct LabelBitmapImage: View {
    let image: UIImage
    var description = ""
    var body: some View {
        Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
            .padding(12).frame(maxWidth: .infinity)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.35)))
            .accessibilityLabel("Bitmap of the label sent to the printer")
            .accessibilityValue(description)
            .accessibilityIdentifier("labels.bitmapPreview")
    }
}

/// Artwork uses an already-cached response or local file, never a network fetch.
private struct LabelInventoryThumbnail: View {
    let card: CardCandidate
    private var image: UIImage? {
        guard let url = card.imageURL else { return nil }
        if url.isFileURL, let data = try? Data(contentsOf: url) { return UIImage(data: data) }
        guard let response = URLCache.shared.cachedResponse(for: URLRequest(url: url)) else { return nil }
        return UIImage(data: response.data)
    }
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "rectangle.portrait").font(.title2).foregroundStyle(.secondary) }
        }.frame(width: 42, height: 60).accessibilityHidden(true)
    }
}

private struct LabelActionBar<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 12) { content() }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.bar)
    }
}

/// A durable receipt for every copy; returning to this view never starts a job.
@MainActor struct LabelPrintQueueView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var queue = LabelPrintQueue.shared
    @State private var printer = NiimbotPrinter.shared
    @State private var selected: Set<UUID> = []
    @State private var showingRetry = false
    @State private var acknowledged = false
    @State private var showingDiscard = false
    @State private var actionError: String?
    @State private var previewEntry: LabelQueueEntry?

    private var selectedUncertain: Bool {
        queue.entries.contains { selected.contains($0.id) && $0.state == .uncertain }
    }
    private var hasRetryable: Bool { queue.entries.contains { $0.state.isRetryable } }
    private var paperTitles: String {
        Set(queue.entries.map { $0.paperSize.title }).sorted().joined(separator: ", ")
    }
    private var styleTitles: String {
        Set(queue.entries.map { $0.style.title }).sorted().joined(separator: ", ")
    }

    var body: some View {
        List {
            if !queue.isLoaded {
                Section("Saved queue unavailable") {
                    Text(queue.error ?? "The saved queue could not be opened.").font(.footnote).foregroundStyle(.orange)
                    Button("Reload Saved Queue") { queue.reload() }.accessibilityIdentifier("labelQueue.reload")
                    Button("Discard Saved Queue", role: .destructive) { showingDiscard = true }
                        .accessibilityIdentifier("labelQueue.discardSaved")
                }
            } else {
                summary
                if queue.entries.isEmpty {
                    Section {
                        ContentUnavailableView("No queued labels", systemImage: "printer",
                            description: Text("Select cards in Show Inventory to prepare a label batch."))
                    }
                } else {
                    LabelPrinterConnectionSection(printer: printer)
                    if let error = queue.error {
                        Section { Text(error).font(.footnote).foregroundStyle(.orange) }
                            .accessibilityIdentifier("labelQueue.error")
                    }
                    if hasRetryable {
                        Section {
                            Text("Select only labels that need another copy. Check label means the printer may already have printed it. Completed copies cannot be retried.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Retry Selected (\(selected.count))") {
                                if selectedUncertain { acknowledged = false; showingRetry = true }
                                else { retrySelected() }
                            }.disabled(selected.isEmpty || queue.isPrinting)
                                .accessibilityIdentifier("labelQueue.retrySelected")
                        } header: { Text("Manual retry") }
                    }
                    Section("Labels & completion receipts") {
                        ForEach(queue.entries) { entry in queueRow(entry) }
                    }
                    Section {
                        Button("Clear Completed Receipts") {
                            perform { try queue.clearCompleted() }
                        }.disabled(queue.completedCount == 0 || queue.isPrinting)
                            .accessibilityIdentifier("labelQueue.clearCompleted")
                        Button("Discard Entire Queue", role: .destructive) { showingDiscard = true }
                            .disabled(queue.isPrinting).accessibilityIdentifier("labelQueue.discard")
                    } footer: {
                        Text("Queue actions never change inventory quantities, card values, sales, or budgets.")
                    }
                }
            }
        }
        .navigationTitle("Label Print Queue").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ClearLabelPrintQueueButton(identifier: "labelQueue.clearQueue") } }
        .safeAreaInset(edge: .bottom, spacing: 0) { printControls }
        .sheet(isPresented: $showingRetry) { retryConfirmation }
        .sheet(item: $previewEntry) { entry in
            NavigationStack {
                List {
                    Section(entry.cardName) {
                        QueuedLabelPreview(raster: entry.raster)
                        LabeledContent("Asking price", value: entry.priceText)
                        LabeledContent("Copy", value: entry.copyNumber.formatted())
                        LabeledContent("Status", value: entry.state.title)
                        LabeledContent("Paper", value: entry.paperSize.title)
                        LabeledContent("Style", value: entry.style.title)
                    }
                }.navigationTitle("Queued Label").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { ClearLabelPrintQueueButton(identifier: "labelQueue.preview.clearQueue") }
                        ToolbarItem(placement: .topBarTrailing) { Button("Done") { previewEntry = nil } }
                    }
            }
        }
        .alert("Discard label queue?", isPresented: $showingDiscard) {
            Button("Discard Queue", role: .destructive) {
                perform {
                    if queue.isLoaded { try queue.clear() } else { try queue.discardSavedQueue() }
                    selected = []
                }
            }
            Button("Keep Queue", role: .cancel) {}
        } message: {
            Text("This removes saved labels and completion receipts. Check uncertain physical labels first. Inventory and financial records are unaffected.")
        }
        .alert("Label queue", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { queue.stop(using: printer) }
        }
        .onChange(of: queue.entries.map(\.id)) { _, ids in
            selected.formIntersection(ids)
            if selected.isEmpty { showingRetry = false }
            if let previewEntry, !ids.contains(previewEntry.id) { self.previewEntry = nil }
        }
        .onDisappear {
            queue.stop(using: printer)
            if !printer.isConnected { printer.stop() }
        }
        .accessibilityIdentifier("labelQueue.screen")
    }

    private var summary: some View {
        Section {
            LabeledContent("Labels", value: queue.entries.count.formatted())
                .accessibilityIdentifier("labelQueue.totalCount")
            if !queue.entries.isEmpty {
                LabeledContent("Paper", value: paperTitles).accessibilityIdentifier("labelQueue.paper")
                LabeledContent("Style", value: styleTitles).accessibilityIdentifier("labelQueue.style")
            }
            LabeledContent("Completed", value: queue.completedCount.formatted())
                .accessibilityIdentifier("labelQueue.completedCount")
            LabeledContent("Queued", value: queue.pendingCount.formatted())
            if queue.failedCount > 0 { LabeledContent("Not printed", value: queue.failedCount.formatted()) }
            if queue.uncertainCount > 0 { LabeledContent("Check label", value: queue.uncertainCount.formatted()).foregroundStyle(.orange) }
            Text("Completed means the printer confirmed completion. Check the physical output before applying labels. Printing starts only when you tap Print Queued Labels.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text(queue.isPrinting ? "Printing in order" : "Review saved queue") }
    }

    private func queueRow(_ entry: LabelQueueEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if entry.state.isRetryable {
                Button {
                    if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
                } label: {
                    Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title2).frame(minWidth: 36, minHeight: 44)
                }.buttonStyle(.plain).disabled(queue.isPrinting)
                    .accessibilityLabel("Select \(entry.cardName), copy \(entry.copyNumber), for retry")
                    .accessibilityAddTraits(selected.contains(entry.id) ? .isSelected : [])
                    .accessibilityIdentifier("labelQueue.select." + entry.id.uuidString)
            } else {
                Image(systemName: entry.state == .completed ? "checkmark.circle.fill" : (entry.state == .sending ? "printer.fill" : "clock"))
                    .foregroundStyle(entry.state == .completed ? Color.green : Color.secondary)
                    .frame(width: 36).accessibilityHidden(true)
            }
            Button { previewEntry = entry } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.cardName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("\(entry.priceText) · Copy \(entry.copyNumber) · \(entry.paperSize.title)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.style.title)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.state.title).font(.caption.weight(.semibold))
                        .foregroundStyle(entry.state == .uncertain ? Color.orange : Color.secondary)
                    if let issue = entry.lastIssue { Text(issue.localizedDescription).font(.caption).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("labelQueue.entry." + entry.id.uuidString)
        }.padding(.vertical, 4)
    }

    private var printControls: some View {
        LabelActionBar {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(queue.completedCount)/\(queue.entries.count) completed").font(.caption).monospacedDigit()
                    .accessibilityIdentifier("labelQueue.progress")
                Text("Paper type: \(printer.paperMode.title)").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("labelQueue.paperMode")
                if queue.isPrinting {
                    ProgressView(value: Double(queue.completedCount), total: Double(max(1, queue.entries.count)))
                        .accessibilityLabel("Print progress")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if queue.isPrinting {
                Button("Pause Printing", role: .destructive) { queue.stop(using: printer) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("labelQueue.pause")
            } else {
                Button("Print Queued Labels") {
                    guard !printer.isConfiguringPaper else { return }
                    let sender = printer.senderForCurrentPaperMode()
                    Task {
                        guard !printer.isConfiguringPaper else { return }
                        await queue.start(using: sender)
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(!queue.canStart || !printer.isConnected || printer.isConfiguringPaper || scenePhase != .active)
                    .accessibilityIdentifier("labelQueue.print")
            }
        }
    }

    private var retryConfirmation: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Some selected labels may already have printed. Inspect the printer and every selected Check label copy. Retry only copies you still need.")
                    Toggle("I checked the printed labels", isOn: $acknowledged)
                        .accessibilityIdentifier("labelQueue.acknowledgeUncertain")
                }
            }.navigationTitle("Check Before Retrying").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { showingRetry = false } }
                    ToolbarItem(placement: .topBarTrailing) { ClearLabelPrintQueueButton(identifier: "labelQueue.retry.clearQueue") }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    LabelActionBar {
                        Button("Requeue Selected Labels") { retrySelected(); showingRetry = false }
                            .buttonStyle(.borderedProminent).disabled(!acknowledged || selected.isEmpty)
                            .accessibilityIdentifier("labelQueue.confirmRetry")
                    }
                }
        }
    }
    private func retrySelected() {
        perform { try queue.retry(ids: selected, acknowledgeUncertain: acknowledged); selected = [] }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { actionError = error.localizedDescription }
    }
}

@MainActor private struct QueuedLabelPreview: View {
    let raster: LabelRaster
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { LabelBitmapImage(image: image) }
            else { Text("Preview unavailable").foregroundStyle(.secondary) }
        }.onAppear { image = try? InventoryLabelRenderer.image(raster: raster) }
    }
}
