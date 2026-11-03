import SwiftUI
import UIKit

/// Opening this screen does not initialize Bluetooth. Search is always explicit.
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
                Text("Create labels from Show Inventory. Asking prices and label copies are local drafts; printing never changes stock, costs, sales, or budgets.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text("First-version support targets the Bluetooth NIIMBOT D110. Charge the printer, load matching labels, close its lid, then tap Search. Physical D110 printing still needs hardware verification; check a single test label before a batch.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("labelPrinter.hardwareNote")
                DisclosureGroup("Printer protocol credits") {
                    Text(NiimbotProtocol.thirdPartyNotice)
                        .font(.footnote).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Label Printer").navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { queue.stop(using: printer) }
        }
        .onDisappear { if !printer.isConnected { printer.stop() } }
    }
}

@MainActor private struct LabelPrinterConnectionSection: View {
    let printer: NiimbotPrinter

    var body: some View {
        Section {
            Label(printer.isConnected ? "D110 connected" : "D110 not connected",
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
                    .disabled(printer.isPrinting).accessibilityIdentifier("labelPrinter.disconnect")
            } else {
                Button { printer.startSearch() } label: {
                    HStack {
                        Text(printer.isScanning ? "Search Again" : "Search for D110")
                        Spacer()
                        if printer.isScanning { ProgressView() }
                    }
                }.disabled(printer.isPrinting).accessibilityIdentifier("labelPrinter.search")
                ForEach(printer.devices) { device in
                    Button { printer.connect(device.id) } label: {
                        Label(device.name, systemImage: "printer")
                    }.accessibilityIdentifier("labelPrinter.device." + device.id.uuidString)
                }
            }
        } header: { Text("Bluetooth printer") } footer: {
            Text("Keep the app open while printing. Bluetooth access is requested only when you tap Search.")
        }
    }
}

private enum InventoryLabelStep: Hashable { case configure, review, queue }

/// The sheet owns navigation. All values copied here remain independent of stock.
@MainActor struct InventoryLabelFlowView: View {
    let inventory: [ShowInventoryItem]
    let marketQuotes: [UUID: TagMarketQuote]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [InventoryLabelStep]
    @State private var search = ""
    @State private var selectedIDs: Set<UUID>
    @State private var drafts: [InventoryLabelDraft]
    @State private var style: InventoryLabelStyle = .cardDetails
    @State private var paper: InventoryLabelSize = .small30x14
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

    init(inventory: [ShowInventoryItem], initialInventoryID: UUID? = nil,
         marketQuotes: [UUID: TagMarketQuote] = [:]) {
        self.inventory = inventory
        self.marketQuotes = marketQuotes
        let initial = inventory.first { $0.id == initialInventoryID && $0.quantity > 0 }
        _selectedIDs = State(initialValue: initial.map { [$0.id] } ?? [])
        _drafts = State(initialValue: initial.map {
            [TagPricingContext.draft(for: $0, marketQuotes: marketQuotes, store: .shared)]
        } ?? [])
        _path = State(initialValue: initial == nil ? [] : [.configure])
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
            guard !draft.isBulk, !keepExistingStickerIDs.contains(draft.id) else { return false }
            guard let saved = approvals.record(for: draft.id) else { return true }
            return saved.approvedTag != draft.tag || saved.needsLabels
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
        .onDisappear {
            stopPrinting()
            if !printer.isConnected { printer.stop() }
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
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(item.card.name), \(item.quantity) available")
                    .accessibilityAddTraits(selectedIDs.contains(item.id) ? .isSelected : [])
                    .accessibilityIdentifier("labels.select." + item.id.uuidString)
            }
        }
        .navigationTitle("Select Label Cards").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name, set, or card number")
        .scrollDismissesKeyboard(.interactively)
        .onSubmit(of: .search) { endEditing() }
        .toolbar {
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
            Section("Label layout") {
                Picker("Style", selection: $style) {
                    ForEach(InventoryLabelStyle.allCases) { value in
                        Text(value.title).tag(value).accessibilityIdentifier("labels.style." + value.rawValue)
                    }
                }.accessibilityIdentifier("labels.style")
                Picker("Physical paper", selection: $paper) {
                    ForEach(InventoryLabelSize.allCases) { value in
                        Text(value.title).tag(value).accessibilityIdentifier("labels.paper." + value.rawValue)
                    }
                }.accessibilityIdentifier("labels.paper")
                Text("Choose the size printed on your label roll. The printable area is 12 mm wide.")
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
                Text("One copy per selected card by default. Maximum 100 per card and 250 individual labels per batch. Bulk copies are reviewed as a category and do not print individual tags. Matching stock keeps the requested counts for review.")
            }
            Section("Asking prices & copies") {
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
        .onChange(of: style) { _, value in for index in drafts.indices { drafts[index].style = value } }
        .onChange(of: paper) { _, value in for index in drafts.indices { drafts[index].paperSize = value } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LabelActionBar {
                Text("\(labelCount.formatted()) labels").font(.subheadline).monospacedDigit()
                    .accessibilityIdentifier("labels.totalCount")
                Button("Continue to Review") { path.append(.review) }
                    .buttonStyle(.borderedProminent).disabled(validation != nil)
                    .accessibilityIdentifier("labels.continueReview")
            }
        }
        .accessibilityIdentifier("labels.configuration")
    }

    private var review: some View {
        List {
            savedQueueSection
            pricingSettingsSection
            if let approvedNotice {
                Section {
                    Text(approvedNotice).font(.footnote).foregroundStyle(.green)
                        .accessibilityIdentifier("labels.approvedNotice")
                }
            }
            Section("Review before preparing") {
                LabeledContent("Total labels", value: labelCount.formatted())
                    .accessibilityIdentifier("labels.reviewCount")
                if bulkCount > 0 {
                    LabeledContent("Bulk copies · no individual tags", value: bulkCount.formatted())
                        .accessibilityIdentifier("labels.reviewBulkCount")
                }
                LabeledContent("Paper", value: paper.title)
                LabeledContent("Style", value: style.title)
                Text("Preparing explicitly approves every selected price and saves its current market as the new review baseline. Only individual tags still needing labels enter the queue. Printing requires a separate Print action.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if requiresManualReview {
                Section("Manual review required") {
                    Text("Review the cost, profit and price warnings below. Approval with these warnings is a manual override; prices will not be raised automatically.")
                        .font(.footnote).foregroundStyle(.orange)
                    Toggle("I reviewed the warnings and approve a manual override", isOn: $acknowledgedPricingWarnings)
                        .accessibilityIdentifier("labels.acknowledgePricingWarnings")
                }
            }
            ForEach(orderedDrafts) { draft in
                Section {
                    if draft.isBulk {
                        Label("2 for $1 category — no individual tag", systemImage: "tray.2")
                    } else {
                        InventoryLabelPreview(draft: draft)
                    }
                    LabeledContent("Asking price", value: draft.priceText ?? "Needs input")
                        .accessibilityIdentifier("labels.review.price." + draft.id.uuidString)
                    LabeledContent("Condition", value: draft.condition)
                    LabeledContent("Copies", value: draft.copies.formatted())
                        .accessibilityIdentifier("labels.review.copies." + draft.id.uuidString)
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
                        if let saved = approvals.record(for: draft.id), saved.approvedTag == draft.tag,
                           !saved.needsLabels {
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
                } header: { Text(draft.cardName) }
            }
            TagBundleReviewSection(lines: TagPricingContext.bundleLines(drafts: drafts,
                inventory: inventory, preferences: approvals.preferences), preferences: approvals.preferences)
            if let validation {
                Section { Text(validation).font(.footnote).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Review Labels").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LabelActionBar {
                Text("\(labelCount.formatted()) labels · \(paper.title)").font(.caption)
                Button {
                    prepareQueue()
                } label: {
                    if preparing { ProgressView() }
                    else { Text(queue.isLoaded && queue.entries.isEmpty && labelCount > 0 ? "Approve & Prepare Labels" : "Approve Prices") }
                }.buttonStyle(.borderedProminent)
                    .disabled(preparing || validation != nil || (requiresManualReview && !acknowledgedPricingWarnings)
                              || queue.isPrinting)
                    .accessibilityIdentifier("labels.prepare")
            }
        }
        .accessibilityIdentifier("labels.review")
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
            var draft = previous[item.id] ?? TagPricingContext.draft(for: item, marketQuotes: marketQuotes, store: approvals)
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
            try approvals.approve(requests)
            pricesSaved = true
            if !keepExistingStickerIDs.isEmpty {
                try approvals.markLabeled(ids: keepExistingStickerIDs)
            }
            var entries: [LabelQueueEntry] = []
            for draft in drafts where !draft.isBulk && approvals.record(for: draft.id)?.needsLabels == true {
                let bitmap = try InventoryLabelRenderer.render(draft)
                for copy in 1...draft.copies {
                    entries.append(try LabelQueueEntry(draft: draft, raster: bitmap.raster, copyNumber: copy,
                        pricingRevisionID: approvals.record(for: draft.id)?.priceRevisionID))
                }
            }
            if entries.isEmpty {
                approvedNotice = "Approved prices saved. No individual labels need printing."
            } else if !queue.isLoaded || !queue.entries.isEmpty {
                approvedNotice = "Approved prices saved. \(entries.count.formatted()) labels still need printing. Review or clear the saved print queue before preparing replacements."
            } else {
                try queue.replace(with: entries)
                path.append(.queue)
            }
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
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { previewEntry = nil } } }
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
                    Task { await queue.start(using: printer) }
                }.buttonStyle(.borderedProminent)
                    .disabled(!queue.canStart || !printer.isConnected || scenePhase != .active)
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
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { showingRetry = false } } }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    LabelActionBar {
                        Button("Requeue Selected Labels") { retrySelected(); showingRetry = false }
                            .buttonStyle(.borderedProminent).disabled(!acknowledged)
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
