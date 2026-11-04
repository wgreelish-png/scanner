import SwiftUI
import SwiftData
import UIKit

/// A transaction is confirmed once, using one stable command identity. The
/// selected scan list is a snapshot; recording never edits its rows or prices.
@MainActor struct ShowTransactionForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \CardList.createdAt, order: .reverse) private var lists: [CardList]
    @State private var store: ShowBudgetStore
    @State private var kind: ShowTransactionKind
    @State private var incomingListID: UUID?
    @State private var showID: UUID?
    @State private var draftID = UUID()
    @State private var incoming: [ShowIncomingCard] = []
    @State private var capturedListID: UUID?
    @State private var capturedListName: String?
    @State private var outgoingQuantities: [UUID: Int] = [:]
    @State private var incomingValue = ""
    @State private var outgoingValue = ""
    @State private var saleReceived = ""
    @State private var offerCash = ""
    @State private var incomingDefault: Int64?
    @State private var incomingValueEdited = false
    @State private var outgoingValueEdited = false
    @State private var makeEven = false
    @State private var note = ""
    @State private var selectingInventory = false
    @State private var editingIncomingList = false
    @State private var incomingDetailsExpanded = false
    @State private var outgoingDetailsExpanded = false
    @State private var editingCashAmount = false
    @State private var editingIncomingCost: ShowIncomingCard?
    @State private var incomingCostsExpanded = false
    @State private var incomingEditMessage: String?
    @State private var saleReceivedEdited = true
    @State private var error: String?
    @State private var isRecording = false
    @State private var didPrepare = false
    @State private var tagApprovals = TagApprovalStore.shared
    @FocusState private var focused: MoneyField?
    private let initialInventoryID: UUID?
    private let confirmingSelection: Bool
    private let contextualList: Bool
    private let offerContext: ShowTransactionOfferContext?
    private let onSelectionChanged: ([UUID: Int]) -> Void
    private let onRecorded: () -> Void

    private enum MoneyField: Hashable { case incoming, outgoing, note }

    init(store: ShowBudgetStore = .shared, initialKind: ShowTransactionKind = .sale,
         initialListID: UUID? = nil, initialInventoryID: UUID? = nil,
         initialQuantities: [UUID: Int] = [:], confirmingSelection: Bool = false,
         offerContext: ShowTransactionOfferContext? = nil,
         onSelectionChanged: @escaping ([UUID: Int]) -> Void = { _ in },
         onRecorded: @escaping () -> Void = {}) {
        _store = State(initialValue: store)
        _kind = State(initialValue: offerContext?.kind ?? initialKind)
        _incomingListID = State(initialValue: initialListID)
        _outgoingQuantities = State(initialValue: initialQuantities)
        _outgoingDetailsExpanded = State(initialValue: !initialQuantities.isEmpty)
        self.initialInventoryID = initialInventoryID
        self.confirmingSelection = confirmingSelection
        contextualList = initialListID != nil
        self.offerContext = offerContext
        self.onSelectionChanged = onSelectionChanged; self.onRecorded = onRecorded
    }

    private var isTrade: Bool { kind != .sale && kind != .purchase }
    private var selectedShow: ShowBudgetEvent? { store.visibleShows.first { $0.id == showID } }
    private var incomingLists: [CardList] { lists.filter { !$0.isCardShowInventory } }
    private var selectedLines: [ShowTransactionCardLine] {
        store.inventory.compactMap { item in
            guard let quantity = outgoingQuantities[item.id], quantity > 0 else { return nil }
            return ShowTransactionCardLine(inventoryID: item.id, card: item.card, quantity: quantity)
        }
    }
    private var outgoingReference: Int64? { ShowSaleMath.suggestedTotal(selectedLines) }
    private var stickerSuggestion: TagSaleSuggestion? {
        TagPricingContext.saleSuggestion(lines: selectedLines, inventory: store.inventory, store: tagApprovals)
    }
    private var saleText: String { saleReceived }
    private var outgoingText: String {
        if let amount = offerContext?.outgoingValueCents { return showTransactionInput(amount) }
        return outgoingValueEdited ? outgoingValue : outgoingReference.map(showTransactionInput) ?? ""
    }
    private var contextualTrade: Bool { contextualList && isTrade && offerContext != nil }
    private var needsOfferCash: Bool { contextualList && offerContext != nil && kind != .trade }
    private var showNeedsSelection: Bool { showID.map { !store.canRecord(showID: $0) } ?? true }
    private var evaluatedPreview: (amounts: ShowTransactionAmounts?, accounting: ShowTransactionAccounting?, message: String?, needsCostAllocation: Bool) {
        do {
            let draft = try preparedDraft()
            let percent = selectedShow?.reinvestmentPercent ?? 65
            let amounts = try ShowTransactionMath.calculate(draft, saleReinvestmentPercent: percent)
            do {
                return (amounts, try ShowTransactionMath.preview(draft, inventory: store.inventory,
                    saleReinvestmentPercent: percent), nil, false)
            } catch {
                return (amounts, nil, error.localizedDescription, error as? ShowTransactionFailure == .costAllocationRequired)
            }
        } catch { return (nil, nil, error.localizedDescription, false) }
    }
    private func canRecord(preview: ShowTransactionAmounts?, accounting: ShowTransactionAccounting?) -> Bool {
        guard let showID else { return false }
        return store.isLoaded && !store.isSaving && !isRecording && !selectingInventory && !editingIncomingList && !editingCashAmount && editingIncomingCost == nil && !context.hasChanges && store.canRecord(showID: showID) && preview != nil && accounting != nil
    }

    var body: some View {
        let evaluation = evaluatedPreview
        NavigationStack {
            Form {
                if !contextualList || showNeedsSelection || !store.isLoaded { transactionSection }
                valuesSection
                if kind != .sale { incomingSection(evaluation.accounting, needsCostAllocation: evaluation.needsCostAllocation) }
                if kind != .purchase { outgoingSection(evaluation.accounting) }
                if let message = evaluation.message, cashAmountWasEntered {
                    Section { Text(message).font(.subheadline).foregroundStyle(.orange) }
                }
                if !contextualList {
                    Section {
                        TextField("Note, optional", text: $note, axis: .vertical)
                            .lineLimit(2...4).focused($focused, equals: .note).accessibilityIdentifier("showTransaction.note")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("showTransaction.error") }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top) { checkoutBar(evaluation.amounts, accounting: evaluation.accounting) }
            .navigationTitle(confirmingSelection || contextualList ? "Confirm Transaction" : "Record \(kind.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !selectingInventory && !editingIncomingList { Button("Cancel") { dismiss() } }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if !selectingInventory && !editingIncomingList && !editingCashAmount && editingIncomingCost == nil {
                        Spacer()
                        Button("Done") { endEditing() }.fixedSize()
                            .frame(minWidth: 64, minHeight: 44).accessibilityIdentifier("showTransaction.keyboardDone")
                    }
                }
            }
            .navigationDestination(isPresented: $selectingInventory) {
                ShowInventorySelectionView(store: store, quantities: $outgoingQuantities)
            }
            .navigationDestination(isPresented: $editingIncomingList) {
                if let list = incomingLists.first(where: { $0.id == incomingListID }) {
                    CardListView(list: list, transactionEditing: true)
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { endEditing(); editingIncomingList = false }
                                .accessibilityLabel("Return to Transaction")
                                .accessibilityIdentifier("showTransaction.returnFromEdit")
                        } }
                } else { ContentUnavailableView("List unavailable", systemImage: "tray") }
            }
            .onChange(of: editingIncomingList) { previous, current in
                if previous && !current { refreshIncomingAfterEdit() }
            }
            .onAppear(perform: prepare)
            .onChange(of: incomingListID) { _, _ in loadIncoming() }
            .onChange(of: kind) { previous, next in
                makeEven = false
                incoming = incoming.map { line in
                    var line = line; line.allocatedCostCents = nil; return line
                }
                if previous == .purchase || next == .purchase { incomingValueEdited = false }
                updateIncomingDefault()
            }
            .onChange(of: outgoingQuantities) { previous, quantities in
                onSelectionChanged(quantities)
                if (confirmingSelection || contextualList) && previous.isEmpty && !quantities.isEmpty { outgoingDetailsExpanded = true }
                makeEven = offerContext?.makeEven ?? false
                if !outgoingValueEdited { outgoingValue = outgoingReference.map(showTransactionInput) ?? "" }
                // Actual cash is an explicit agreement. Changing the cart keeps
                // it and invalidates the previous per-card sticker allocation.
                saleReceivedEdited = true
            }
        }
        .sheet(item: $editingIncomingCost) { line in
            ShowTransactionCostEditor(title: "Lot Cost", label: "Total cost for this lot",
                detail: "\(line.card.name) · Quantity \(line.quantity). Enter the total acquisition cost for all copies in this lot. Other lots share the remaining transaction cost.",
                identifier: "incomingCost", initialText: line.allocatedCostCents.map(showTransactionInput) ?? "") { amount in
                guard amount != line.allocatedCostCents else { return }
                if let index = incoming.firstIndex(where: { $0.id == line.id }) {
                    incoming[index].allocatedCostCents = amount
                }
            }
        }
    }

    private func checkoutBar(_ preview: ShowTransactionAmounts?, accounting: ShowTransactionAccounting?) -> some View {
        VStack(spacing: 8) {
            HStack {
                if let preview {
                    Text(preview.receivedCents > 0 ? "You receive" : preview.paidCents > 0 ? "You pay" : isTrade ? "Even trade" : "Cash total")
                    Spacer()
                    Text(ShowTransactionCashInput.money(max(preview.paidCents, preview.receivedCents))).bold().monospacedDigit()
                } else {
                    Text("Review transaction amounts").foregroundStyle(.secondary)
                    Spacer()
                    Text("—").monospacedDigit()
                }
            }.font(.subheadline)
            if let accounting {
                LabeledContent("Change to buying funds", value: ShowTransactionCashInput.signedMoney(accounting.buyingFundsDeltaCents))
                    .font(.caption).monospacedDigit()
                    .accessibilityIdentifier("showTransaction.preview.buyingFundsChange")
            }
            Button(action: record) {
                HStack {
                    if isRecording { ProgressView() }
                    Text("Record Transaction").font(.headline)
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent).disabled(!canRecord(preview: preview, accounting: accounting))
                .accessibilityIdentifier("showTransaction.record")
        }.padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
    }

    private func endEditing() {
        focused = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var transactionSection: some View {
        Section {
            if !contextualList {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Transaction").font(.subheadline).foregroundStyle(.secondary)
                    transactionTypeButtons
                    if isTrade {
                        Text("Cash difference").font(.subheadline).foregroundStyle(.secondary)
                        tradeTypeButtons
                    }
                }.accessibilityElement(children: .contain)
                    .accessibilityIdentifier("showTransaction.kind")
            }
            Picker("Show", selection: $showID) {
                Text("Choose a show").tag(Optional<UUID>.none)
                ForEach(store.visibleShows) { show in
                    Text(show.name).tag(Optional(show.id)).disabled(!store.canRecord(showID: show.id))
                }
            }.pickerStyle(.menu).accessibilityIdentifier("showTransaction.show")
            if !store.isLoaded {
                Text(store.error ?? "Your saved show budget must be available before recording.")
                    .font(.caption).foregroundStyle(.orange)
            } else if let showID, !store.canRecord(showID: showID) {
                Text("This show is outside its recording dates. Choose an active show before recording.")
                    .font(.caption).foregroundStyle(.orange)
            } else if showID == nil {
                Text("Choose an active show. You can create a show in Show Budget.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var transactionTypeButtons: some View {
        if dynamicTypeSize >= .xxLarge {
            VStack(spacing: 8) { mainTypeButtons }
        } else {
            HStack(spacing: 8) { mainTypeButtons }
        }
    }

    @ViewBuilder private var mainTypeButtons: some View {
        kindButton("Sale", accessibilityLabel: ShowTransactionKind.sale.title,
                   selected: kind == .sale, identifier: "sale") { kind = .sale }
        kindButton("Trade", accessibilityLabel: ShowTransactionKind.trade.title,
                   selected: isTrade, identifier: "trade") {
            if !isTrade { kind = .trade }
        }
        kindButton("Purchase", accessibilityLabel: ShowTransactionKind.purchase.title,
                   selected: kind == .purchase, identifier: "purchase") { kind = .purchase }
    }

    @ViewBuilder private var tradeTypeButtons: some View {
        if dynamicTypeSize >= .xxLarge {
            VStack(spacing: 8) { tradeCashButtons }
        } else {
            HStack(spacing: 8) { tradeCashButtons }
        }
    }

    @ViewBuilder private var tradeCashButtons: some View {
        kindButton("Even", accessibilityLabel: ShowTransactionKind.trade.title,
                   selected: kind == .trade, identifier: "tradeEven") { kind = .trade }
        kindButton("Pay Customer", accessibilityLabel: ShowTransactionKind.tradePayCustomer.title,
                   selected: kind == .tradePayCustomer, identifier: "tradePayCustomer") { kind = .tradePayCustomer }
        kindButton("Receive Cash", accessibilityLabel: ShowTransactionKind.tradeReceiveCash.title,
                   selected: kind == .tradeReceiveCash, identifier: "tradeReceiveCash") { kind = .tradeReceiveCash }
    }

    private func kindButton(_ title: String, accessibilityLabel: String, selected: Bool,
                            identifier: String, action: @escaping () -> Void) -> some View {
        Button {
            endEditing()
            action()
        } label: {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .padding(.horizontal, 8).padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("showTransaction.kind." + identifier)
    }

    @ViewBuilder private func incomingSection(_ accounting: ShowTransactionAccounting?, needsCostAllocation: Bool) -> some View {
        if contextualList {
            Section("Selected cards") {
                let costs = Dictionary(uniqueKeysWithValues: (accounting?.incoming ?? []).map { ($0.inventoryID, $0) })
                ForEach(incoming) { line in
                    compactCardRow(card: line.card, quantity: line.quantity,
                        acquisitionCost: line.allocatedCostCents ?? costs[line.id]?.totalCostCents)
                        .accessibilityIdentifier("showTransaction.incomingCard." + line.id.uuidString)
                }
                if needsCostAllocation { incomingCostDisclosure(accounting) }
                if incoming.isEmpty {
                    Text(error ?? "This list is unavailable. Return to the list and try again.")
                        .foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("showTransaction.incomingCards")
        } else {
            genericIncomingSection(accounting)
        }
    }

    private func genericIncomingSection(_ accounting: ShowTransactionAccounting?) -> some View {
        Section {
            Picker("Incoming scanned list", selection: $incomingListID) {
                Text("Choose a list").tag(Optional<UUID>.none)
                ForEach(incomingLists) { list in
                    let used = store.transaction(forListID: list.id) != nil
                    let legacy = hasLegacyOutcome(list)
                    Text(list.name + (used || legacy ? " · Already recorded" : " · \(list.quantity) cards"))
                        .tag(Optional(list.id)).disabled(used || legacy || list.quantity <= 0)
                }
            }.pickerStyle(.menu).accessibilityIdentifier("showTransaction.incomingList")
            if let incomingListID, store.transaction(forListID: incomingListID) != nil {
                Text("This list already belongs to a recorded transaction. Undo that transaction before using the list again.")
                    .font(.caption).foregroundStyle(.orange)
            } else if let list = incomingLists.first(where: { $0.id == incomingListID }), hasLegacyOutcome(list) {
                Text("This list already has a completed outcome. Review its existing outcome before recording another transaction.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let list = incomingLists.first(where: { $0.id == incomingListID }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(capturedListName ?? list.name).font(.subheadline.weight(.semibold))
                    Text("\(incoming.reduce(0) { $0 + $1.quantity }) cards · \(incoming.count) rows")
                        .font(.caption).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
                    .accessibilityIdentifier("showTransaction.incomingSummary")
                Button("Review / Edit Selected List", systemImage: "pencil") {
                    endEditing(); editingIncomingList = true
                }.frame(minHeight: 44).accessibilityIdentifier("showTransaction.editIncomingList")
            }
            if let incomingEditMessage { Text(incomingEditMessage).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("showTransaction.incomingEditStatus") }
            if incomingLists.isEmpty {
                Text("Scan cards into a list before recording incoming stock.").foregroundStyle(.secondary)
            } else if incomingListID != nil {
                Button("Reload Incoming List", action: loadIncoming).frame(minHeight: 44)
                    .accessibilityIdentifier("showTransaction.reloadIncoming")
            }
            if !incoming.isEmpty {
                DisclosureGroup("Selected cards · \(incoming.count) rows", isExpanded: $incomingDetailsExpanded) {
                    if incomingDetailsExpanded {
                        ForEach(incoming) { line in
                            ShowTransactionCardRow(card: line.card, quantity: line.quantity)
                        }
                    }
                }.accessibilityIdentifier("showTransaction.incomingCards")
                incomingCostDisclosure(accounting)
            }
        } header: {
            Text("Cards coming in")
        } footer: {
            Text("The whole selected list becomes local stock. Your scanned list and its market reference prices stay as saved.")
        }
    }

    private func compactCardRow(card: CardCandidate, quantity: Int, acquisitionCost: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.name).font(.headline)
                Spacer(minLength: 12)
                Text("Qty \(quantity)").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack {
                Text("Acquisition cost").foregroundStyle(.secondary)
                Spacer()
                Text(acquisitionCost.map(showTransactionMoney) ?? "Unknown").monospacedDigit()
            }.font(.caption)
            HStack {
                Text("Market reference").foregroundStyle(.secondary)
                Spacer()
                Text(card.marketPrice.map { ($0 * Decimal(quantity)).money } ?? "Unavailable").monospacedDigit()
            }.font(.caption)
        }.padding(.vertical, 4).accessibilityElement(children: .combine)
    }

    @ViewBuilder private func incomingCostDisclosure(_ accounting: ShowTransactionAccounting?) -> some View {
        DisclosureGroup("Acquisition costs · \(incoming.count) lots", isExpanded: $incomingCostsExpanded) {
            if incomingCostsExpanded {
                let costs = Dictionary(uniqueKeysWithValues: (accounting?.incoming ?? []).map { ($0.inventoryID, $0) })
                let canEdit = !isTrade || accounting == nil || accounting?.totalCostCents != nil
                ForEach(incoming) { line in
                    incomingCostRow(line, calculatedCost: costs[line.id]?.totalCostCents, canEdit: canEdit)
                }
            }
        }.accessibilityIdentifier("showTransaction.incomingCosts")
        if let accounting, accounting.incoming.contains(where: { $0.totalCostCents == nil }) {
            Text("Incoming acquisition cost is unknown because some outgoing stock has no recorded cost. Record with unknown cost, or set the outgoing lot costs in Show Inventory first.")
                .font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("showTransaction.incomingCostUnknown")
        } else if accounting == nil {
            Text("Enter costs for lots that cannot be allocated automatically. Your entered costs are kept and must fit the transaction's total cost.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Your entered lot costs are kept. Any remaining cost is allocated automatically across the other lots. Review or edit each lot before recording.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func incomingCostRow(_ line: ShowIncomingCard, calculatedCost: Int64?, canEdit: Bool) -> some View {
        let amount = line.allocatedCostCents ?? calculatedCost
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                endEditing()
                var edited = line
                edited.allocatedCostCents = amount
                editingIncomingCost = edited
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(line.card.name) · Qty \(line.quantity)").foregroundStyle(.primary)
                    HStack {
                        Text(line.allocatedCostCents == nil ? "Allocated lot cost" : "Entered lot cost")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(amount.map(showTransactionMoney) ?? "Unknown").monospacedDigit()
                        Image(systemName: "pencil")
                    }.font(.subheadline)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.disabled(!canEdit)
                .accessibilityLabel("Edit cost for \(line.card.name), quantity \(line.quantity)")
                .accessibilityValue(amount.map(showTransactionMoney) ?? "Unknown")
                .accessibilityIdentifier("showTransaction.incomingCost." + line.id.uuidString)
            if line.allocatedCostCents != nil {
                Button("Use Automatic Allocation") {
                    if let index = incoming.firstIndex(where: { $0.id == line.id }) {
                        incoming[index].allocatedCostCents = nil
                    }
                }.font(.caption).frame(minHeight: 44)
                    .accessibilityIdentifier("showTransaction.resetIncomingCost." + line.id.uuidString)
            }
        }
    }

    private func outgoingSection(_ accounting: ShowTransactionAccounting?) -> some View {
        Section {
            Button {
                endEditing(); selectingInventory = true
            } label: {
                Label(selectedLines.isEmpty ? "Select Inventory Cards" : "Add Cards", systemImage: "shippingbox")
                    .frame(minHeight: 48)
            }.accessibilityIdentifier("showTransaction.selectInventory")
            LabeledContent("Selected quantity", value: outgoingQuantities.values.reduce(0, +).formatted())
                .accessibilityIdentifier("showTransaction.selectedQuantity")
            if !selectedLines.isEmpty {
                DisclosureGroup("Selected cards · \(selectedLines.count) rows", isExpanded: $outgoingDetailsExpanded) {
                    let costs = Dictionary(uniqueKeysWithValues: (accounting?.outgoing ?? []).map { ($0.inventoryID, $0) })
                    let stock = Dictionary(uniqueKeysWithValues: store.inventory.map { ($0.id, $0) })
                    ForEach(selectedLines, id: \.inventoryID) { line in
                        compactCardRow(card: line.card, quantity: line.quantity, acquisitionCost: costs[line.inventoryID]?.totalCostCents ?? outgoingCost(line, in: stock))
                            .accessibilityIdentifier("showTransaction.selectedCard." + line.inventoryID.uuidString)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Remove", role: .destructive) {
                                    guard !isRecording else { return }
                                    endEditing(); outgoingQuantities.removeValue(forKey: line.inventoryID)
                                }.disabled(isRecording)
                                    .accessibilityIdentifier("showTransaction.remove." + line.inventoryID.uuidString)
                            }
                    }
                }
            }
        } header: { Text(kind == .sale ? "Cards being sold" : "Cards going out") }
    }

    private var valuesSection: some View {
        Section {
            if kind == .sale {
                ShowInlineCashAmount(title: "Actual cash received", value: saleReceived,
                    identifier: "sale", editIdentifier: "showTransaction.editSaleAmount",
                    controlsIdentifier: "cashEditor", isEditing: $editingCashAmount) { amount in
                        saleReceived = ShowTransactionCashInput.input(amount)
                        saleReceivedEdited = true
                    }.disabled(isRecording)
                if let suggestion = stickerSuggestion, suggestion.usesApprovedPrices,
                   let amount = ShowTransactionCashInput.nearestWholeDollarCents(suggestion.totalCents) {
                    Button {
                        endEditing(); editingCashAmount = false
                        saleReceived = ShowTransactionCashInput.input(amount)
                        saleReceivedEdited = amount != suggestion.totalCents
                    } label: {
                        HStack {
                            Text("Use approved sticker total")
                            Spacer()
                            Text(ShowTransactionCashInput.money(amount)).monospacedDigit()
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("showTransaction.resetSaleTotal")
                }
            } else if contextualList && offerContext != nil {
                if needsOfferCash {
                    ShowInlineCashAmount(title: kind == .tradeReceiveCash ? "Actual cash received" : "Actual cash paid",
                        value: offerCash, identifier: "offerCash", editIdentifier: "showTransaction.editOfferCashAmount",
                        controlsIdentifier: "offerCashEditor", isEditing: $editingCashAmount) { amount in
                            offerCash = ShowTransactionCashInput.input(amount)
                        }.disabled(isRecording)
                    if let amount = offerContext?.cashSuggestionCents {
                        calculatedOfferButton(amount: amount, cash: true) {
                            offerCash = ShowTransactionCashInput.input(amount)
                        }
                    }
                } else {
                    Label("No cash changes hands", systemImage: "equal.circle")
                }
            } else {
                if kind == .purchase {
                    ShowInlineCashAmount(title: "Actual cash paid", value: incomingValue,
                        identifier: "incoming", editIdentifier: "showTransaction.editIncomingAmount",
                        controlsIdentifier: "incomingCashEditor", isEditing: $editingCashAmount) { amount in
                            incomingValue = ShowTransactionCashInput.input(amount)
                            incomingValueEdited = true; makeEven = false
                        }.disabled(isRecording)
                } else {
                    amountField("Agreed incoming card value", text: Binding(get: { incomingValue }, set: {
                        incomingValue = $0; incomingValueEdited = true; makeEven = false
                    }), field: .incoming)
                }
                if let incomingDefault,
                   let amount = kind == .purchase ? (offerContext?.cashSuggestionCents ?? ShowTransactionCashInput.nearestWholeDollarCents(incomingDefault)) : incomingDefault {
                    calculatedOfferButton(amount: amount, cash: kind == .purchase) {
                        incomingValueEdited = true
                        incomingValue = kind == .purchase ? ShowTransactionCashInput.input(amount) : showTransactionInput(amount)
                        makeEven = false
                    }
                }
                if isTrade {
                    amountField("Agreed outgoing card value", text: Binding(get: { outgoingText }, set: {
                        outgoingValue = $0; outgoingValueEdited = true; makeEven = false
                    }), field: .outgoing)
                    if kind == .trade { evenTradeControl }
                }
            }
        } header: { Text(kind == .sale || kind == .purchase || contextualTrade ? "Actual cash" : "Agreed card values") }
    }

    private func calculatedOfferButton(amount: Int64, cash: Bool, apply: @escaping () -> Void) -> some View {
        Button {
            endEditing(); editingCashAmount = false
            apply()
        } label: {
            HStack {
                Text(cash ? "Use calculated cash offer" : "Use calculated trade offer")
                Spacer()
                Text(ShowTransactionCashInput.money(amount)).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }.frame(minHeight: 44)
        }.accessibilityIdentifier("showTransaction.useCalculatedOffer")
    }

    private func outgoingCost(_ line: ShowTransactionCardLine, in stock: [UUID: ShowInventoryItem]) -> Int64? {
        guard let item = stock[line.inventoryID] else { return nil }
        return try? ShowCostBasisMath.consumedCost(totalCostCents: item.remainingCostCents,
            quantity: item.quantity, consumedQuantity: line.quantity)
    }

    private var cashAmountWasEntered: Bool {
        if kind == .sale { return !saleReceived.isEmpty }
        if needsOfferCash { return !offerCash.isEmpty }
        return !incomingValue.isEmpty
    }

    private func amountField(_ title: String, text: Binding<String>, field: MoneyField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            HStack {
                Text("USD").foregroundStyle(.secondary)
                TextField("0.00", text: text).keyboardType(.decimalPad).focused($focused, equals: field)
                    .monospacedDigit().accessibilityLabel(title)
                    .accessibilityIdentifier("showTransaction.amount." + String(describing: field))
            }.frame(minHeight: 64)
        }
    }

    @ViewBuilder private var evenTradeControl: some View {
        if let incomingCents = ShowBudgetMoney.parse(incomingValue),
           let outgoingCents = ShowBudgetMoney.parse(outgoingText), incomingCents != outgoingCents {
            if makeEven {
                Label("Even trade · No cash changes hands", systemImage: "equal.circle.fill")
                    .foregroundStyle(.indigo).accessibilityIdentifier("showTransaction.evenConfirmed")
                LabeledContent(outgoingCents > incomingCents ? "Value conceded" : "Extra incoming value",
                               value: showTransactionMoney(abs(outgoingCents - incomingCents)))
                Button("Review Cash Difference") { makeEven = false }.frame(minHeight: 44)
            } else {
                Text("These agreed values differ by \(showTransactionMoney(abs(outgoingCents - incomingCents))). Choose a cash trade type or explicitly make an even trade.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Make Even Trade") { focused = nil; makeEven = true }
                    .frame(minHeight: 64).accessibilityIdentifier("showTransaction.makeEven")
            }
        }
    }

    private func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        var inventoryError: String?
        do { try ShowInventoryBridge.seedFromImportedList(context: context, store: store) }
        catch { inventoryError = error.localizedDescription }
        showID = store.eligibleActiveShow?.id ?? store.visibleShows.first(where: { store.canRecord(showID: $0.id) })?.id
        if outgoingQuantities.isEmpty, let initialInventoryID,
           store.inventory.contains(where: { $0.id == initialInventoryID && $0.quantity > 0 }) {
            outgoingQuantities[initialInventoryID] = 1
        }
        if incomingListID != nil { loadIncoming() }
        if let offerContext {
            makeEven = offerContext.makeEven
            if let amount = offerContext.incomingTradeValueCents, kind != .purchase {
                incomingValue = showTransactionInput(amount)
            }
        }
        if let inventoryError { error = inventoryError }
    }

    private func loadIncoming() {
        incomingDetailsExpanded = false
        incomingCostsExpanded = false
        incoming = []; capturedListID = nil; capturedListName = nil
        incomingValueEdited = false; incomingValue = ""; incomingDefault = nil; makeEven = false; incomingEditMessage = nil
        guard let incomingListID else { return }
        guard let list = incomingLists.first(where: { $0.id == incomingListID }) else {
            error = "This scanned list is no longer available. Choose another list."
            return
        }
        do {
            let snapshot = try ShowTransactionListService.incomingSnapshot(for: list, kind: kind, context: context)
            incoming = snapshot.cards
            capturedListID = snapshot.listID; capturedListName = snapshot.name
            incomingDefault = snapshot.defaultValueCents
            error = nil
            if !incomingValueEdited && kind != .purchase { incomingValue = snapshot.defaultValueCents.map(showTransactionInput) ?? "" }
        } catch { self.error = error.localizedDescription }
    }

    private func refreshIncomingAfterEdit() {
        guard let list = incomingLists.first(where: { $0.id == incomingListID }) else {
            incoming = []; capturedListID = nil; capturedListName = nil
            error = "The incoming list is no longer available. Choose another list."
            return
        }
        do {
            guard !context.hasChanges else { throw ShowTransactionListFailure.unsavedChanges }
            let updated = try ShowTransactionListService.incomingSnapshot(for: list, kind: kind, context: context)
            let refreshed = preservingIncomingCosts(updated.cards)
            let changed = incoming != refreshed || incomingDefault != updated.defaultValueCents || capturedListName != updated.name
            incoming = refreshed; capturedListID = updated.listID; capturedListName = updated.name
            incomingDefault = updated.defaultValueCents
            if !incomingValueEdited && kind != .purchase { incomingValue = updated.defaultValueCents.map(showTransactionInput) ?? "" }
            if changed {
                makeEven = false
                incomingEditMessage = incomingValueEdited
                    ? "List updated. Your agreed total was kept; review it before recording."
                    : "List and calculated offer updated. Review the transaction before recording."
            }
            error = nil
        } catch {
            incoming = []; capturedListID = nil; capturedListName = nil
            self.error = error.localizedDescription
        }
    }

    private func preservingIncomingCosts(_ cards: [ShowIncomingCard]) -> [ShowIncomingCard] {
        let previous = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        return cards.map { card in
            guard let old = previous[card.id], old.card == card.card, old.quantity == card.quantity else { return card }
            var updated = card
            updated.allocatedCostCents = old.allocatedCostCents
            return updated
        }
    }

    private func updateIncomingDefault() {
        guard kind != .sale, let incomingListID,
              let list = incomingLists.first(where: { $0.id == incomingListID }) else { return }
        do {
            let snapshot = try ShowTransactionListService.incomingSnapshot(for: list, kind: kind, context: context)
            incoming = preservingIncomingCosts(snapshot.cards)
            incomingDefault = snapshot.defaultValueCents
            if !incomingValueEdited { incomingValue = kind == .purchase ? "" : incomingDefault.map(showTransactionInput) ?? "" }
        } catch {
            incomingDefault = nil
            if !incomingValueEdited { incomingValue = "" }
            self.error = error.localizedDescription
        }
    }

    private func preparedDraft() throws -> ShowTransactionDraft {
        var draft = ShowTransactionDraft(id: draftID, kind: kind, note: note)
        if kind != .sale {
            guard let incomingListID, capturedListID == incomingListID, !incoming.isEmpty else {
                throw ShowTransactionInputFailure.chooseIncoming
            }
            guard store.transaction(forListID: incomingListID) == nil else {
                throw ShowTransactionFailure.incomingListAlreadyUsed
            }
            if let list = incomingLists.first(where: { $0.id == incomingListID }), hasLegacyOutcome(list) {
                throw ShowTransactionFailure.legacyListOutcomeExists
            }
            let amount: Int64
            if contextualList && offerContext != nil && kind == .purchase {
                guard let cash = ShowTransactionCashInput.parseWholeDollars(offerCash) else {
                    throw ShowTransactionInputFailure.invalidCash("cash paid")
                }
                amount = cash
            } else if contextualTrade, let offerContext {
                guard let outgoing = offerContext.outgoingValueCents else {
                    throw ShowTransactionInputFailure.invalidAmount("outgoing card value")
                }
                if kind == .trade {
                    guard let incoming = offerContext.incomingTradeValueCents else {
                        throw ShowTransactionInputFailure.invalidAmount("incoming card value")
                    }
                    amount = incoming
                } else {
                    guard let cash = ShowTransactionCashInput.parseWholeDollars(offerCash) else {
                        throw ShowTransactionInputFailure.invalidCash(kind == .tradeReceiveCash ? "cash received" : "cash paid")
                    }
                    let agreed = kind == .tradeReceiveCash ? outgoing.subtractingReportingOverflow(cash) : outgoing.addingReportingOverflow(cash)
                    guard !agreed.overflow, ShowBudgetMoney.isValid(agreed.partialValue) else {
                        if kind == .tradeReceiveCash {
                            throw ShowTransactionInputFailure.cashDirection("Cash received cannot exceed the agreed price of your outgoing cards.")
                        }
                        throw ShowTransactionInputFailure.invalidAmount("incoming card value")
                    }
                    amount = agreed.partialValue
                    if cash == 0 { draft.kind = .trade; draft.makeEven = true }
                }
            } else {
                guard let entered = kind == .purchase ? ShowTransactionCashInput.parseWholeDollars(incomingValue) : ShowBudgetMoney.parse(incomingValue) else {
                    if kind == .purchase { throw ShowTransactionInputFailure.invalidCash("cash paid") }
                    throw ShowTransactionInputFailure.invalidAmount("incoming card value")
                }
                amount = entered
            }
            draft.incomingListID = capturedListID; draft.incomingListName = capturedListName
            draft.incoming = incoming; draft.incomingValueCents = amount
        }
        if kind != .purchase {
            draft.outgoing = outgoingQuantities.filter { $0.value > 0 }.sorted { $0.key.uuidString < $1.key.uuidString }
                .map { ShowTransactionSelection(inventoryID: $0.key, quantity: $0.value) }
            guard !draft.outgoing.isEmpty else { throw ShowTransactionInputFailure.chooseOutgoing }
            let quantitiesByID = Dictionary(uniqueKeysWithValues: store.inventory.map { ($0.id, $0.quantity) })
            for selection in draft.outgoing {
                guard let available = quantitiesByID[selection.inventoryID],
                      available >= selection.quantity else { throw ShowTransactionFailure.insufficientStock }
            }
        }
        if kind == .sale {
            guard let amount = ShowTransactionCashInput.parseWholeDollars(saleText) else {
                throw ShowTransactionInputFailure.invalidCash("actual cash received")
            }
            draft.saleReceivedCents = amount
            draft.feeCents = 0
            if !saleReceivedEdited, let suggestion = stickerSuggestion {
                let allocations = Dictionary(uniqueKeysWithValues: suggestion.allocations.map { ($0.inventoryID, $0.receivedCents) })
                for index in draft.outgoing.indices {
                    draft.outgoing[index].allocatedProceedsCents = allocations[draft.outgoing[index].inventoryID]
                }
            }
        } else if isTrade {
            guard let amount = ShowBudgetMoney.parse(outgoingText) else {
                throw ShowTransactionInputFailure.invalidAmount("outgoing card value")
            }
            draft.outgoingValueCents = amount
            draft.makeEven = needsOfferCash && draft.kind == .trade ? true : makeEven
            if draft.kind == .trade && !draft.makeEven && draft.incomingValueCents != amount {
                throw ShowTransactionInputFailure.confirmEvenTrade
            }
            if draft.kind == .tradePayCustomer && draft.incomingValueCents <= amount {
                throw ShowTransactionInputFailure.cashDirection("Pay Customer requires incoming value greater than outgoing value.")
            }
            if draft.kind == .tradeReceiveCash && amount <= draft.incomingValueCents {
                throw ShowTransactionInputFailure.cashDirection("Receive Cash requires outgoing value greater than incoming value.")
            }
        }
        return draft
    }

    private func record() {
        focused = nil
        guard !isRecording, let showID else { return }
        isRecording = true
        defer { isRecording = false }
        do {
            let draft = try preparedDraft()
            _ = try ShowTransactionListService.record(draft, showID: showID, context: context, store: store)
            onRecorded()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func hasLegacyOutcome(_ list: CardList) -> Bool {
        list.transactionOutcomeData != nil && list.outcomeRecord?.kind != .nothingHappened
    }
}

/// Inline editing isolates keystrokes from the transaction calculation. Each
/// edit starts blank; Cancel keeps the last agreed cash amount unchanged.
@MainActor private struct ShowInlineCashAmount: View {
    let title: String
    let value: String
    let identifier: String
    let editIdentifier: String
    let controlsIdentifier: String
    @Binding var isEditing: Bool
    let onSave: (Int64) -> Void
    @State private var text = ""
    @FocusState private var amountFocused: Bool

    private var amount: Int64? { ShowTransactionCashInput.parseWholeDollars(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEditing {
                Text(title).font(.subheadline)
                HStack {
                    Text("$").foregroundStyle(.secondary)
                    TextField("Amount", text: $text).keyboardType(.numberPad).focused($amountFocused)
                        .font(.title2).monospacedDigit().accessibilityLabel(title)
                        .accessibilityIdentifier("showTransaction.amount." + identifier)
                }.frame(minHeight: 44)
                HStack {
                    Button("Cancel") { finish() }
                        .accessibilityIdentifier("showTransaction." + controlsIdentifier + ".cancel")
                    Spacer()
                    Button("Done") {
                        guard let amount else { return }
                        onSave(amount); finish()
                    }.fontWeight(.semibold).disabled(amount == nil)
                        .accessibilityIdentifier("showTransaction." + controlsIdentifier + ".done")
                }.buttonStyle(.borderless).frame(minHeight: 44)
            } else {
                Button {
                    text = ""; isEditing = true
                } label: {
                    HStack {
                        Text(title).foregroundStyle(.primary)
                        Spacer()
                        Text(ShowTransactionCashInput.parseWholeDollars(value).map(ShowTransactionCashInput.money) ?? "Enter amount")
                            .monospacedDigit()
                        Image(systemName: "pencil")
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.borderless).accessibilityLabel("Edit " + title.lowercased())
                    .accessibilityValue(value.isEmpty ? "Not entered" : value)
                    .accessibilityIdentifier(editIdentifier)
            }
        }
        .task(id: isEditing) {
            guard isEditing else { return }
            await Task.yield()
            guard !Task.isCancelled, isEditing else { return }
            amountFocused = true
        }
    }

    private func finish() {
        amountFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isEditing = false
    }
}

/// Optional acquisition edits keep typing and focus local, so a keystroke
/// never rebuilds the transaction calculation.
@MainActor private struct ShowTransactionCostEditor: View {
    let title: String
    let label: String
    let detail: String
    let identifier: String
    let onSave: (Int64) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isApplying = false
    @FocusState private var amountFocused: Bool

    init(title: String, label: String, detail: String, identifier: String,
         initialText: String, onSave: @escaping (Int64) -> Void) {
        self.title = title; self.label = label; self.detail = detail
        self.identifier = identifier; self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    private var amount: Int64? { ShowBudgetMoney.parse(text) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(label).font(.headline)
                HStack(spacing: 12) {
                    Text("USD").foregroundStyle(.secondary)
                    TextField("0.00", text: $text)
                        .keyboardType(.decimalPad).focused($amountFocused)
                        .font(.largeTitle).monospacedDigit()
                        .accessibilityLabel(label)
                        .accessibilityIdentifier("showTransaction.amount." + identifier)
                    Button {
                        text = ""; amountFocused = true
                    } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .disabled(text.isEmpty || isApplying)
                        .accessibilityLabel("Clear amount")
                        .accessibilityIdentifier("showTransaction." + identifier + ".clear")
                }.frame(minHeight: 56)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                Text("Enter a USD amount with up to two decimal places.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }.padding(24)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { amountFocused = false; dismiss() }
                            .disabled(isApplying)
                            .accessibilityIdentifier("showTransaction." + identifier + ".cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: apply).fontWeight(.semibold)
                            .disabled(amount == nil || isApplying)
                            .accessibilityIdentifier("showTransaction." + identifier + ".done")
                    }
                }
        }
        .interactiveDismissDisabled(isApplying)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            amountFocused = true
        }
    }

    private func apply() {
        guard !isApplying, let amount else { return }
        isApplying = true; amountFocused = false
        onSave(amount)
        dismiss()
    }
}


@MainActor private struct ShowSaleBreakdownView: View {
    let lines: [ShowTransactionCardLine]
    let receivedCents: Int64
    var approvedAllocations: [ShowSaleAllocation]? = nil
    @State private var expanded = false

    var body: some View {
        if !lines.isEmpty {
            if approvedAllocations == nil, ShowSaleMath.suggestedTotal(lines) != receivedCents,
               let percent = ShowSaleMath.marketPercentage(lines, receivedCents: receivedCents) {
                LabeledContent("Sale percentage of market", value: CSVExportService.number(OfferCalculator.cents(percent)) + "%")
                    .accessibilityIdentifier("showTransaction.salePercentage")
                Text("The same market percentage applies to every card, with cent rounding so allocations match the total received.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Allocated sale prices", isExpanded: $expanded) {
                // A collapsed disclosure must not sort thousands of allocations
                // when a keyboard or unrelated checkout field changes.
                if expanded {
                    if let allocations = approvedAllocations ?? ShowSaleMath.allocations(lines, receivedCents: receivedCents) {
                        let cardsByID = Dictionary(uniqueKeysWithValues: lines.map { ($0.inventoryID, $0.card) })
                        ForEach(allocations) { allocation in
                            if let card = cardsByID[allocation.inventoryID] {
                                LabeledContent("\(card.name) · Qty \(allocation.quantity)", value: showTransactionMoney(allocation.receivedCents))
                            }
                        }
                    } else {
                        Text("A proportional breakdown needs market prices for every selected card and a nonzero market total.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

@MainActor private struct ShowTransactionAccountingSummary: View {
    let accounting: ShowTransactionAccounting?
    let kind: ShowTransactionKind
    let identifier: String

    var body: some View {
        LabeledContent(kind == .purchase ? "Acquisition cost" : "Cost of cards released",
                       value: accounting?.totalCostCents.map(showTransactionMoney) ?? "Unknown")
            .accessibilityIdentifier("showTransaction." + identifier + ".cost")
        if kind != .purchase {
            LabeledContent(kind == .sale ? "Sale proceeds" : "Cash proceeds",
                           value: accounting?.proceedsCents.map(showTransactionMoney) ?? "Unknown")
                .accessibilityIdentifier("showTransaction." + identifier + ".proceeds")
        }
        LabeledContent("Fees", value: accounting.map { showTransactionMoney($0.feeCents) } ?? "Unknown")
            .accessibilityIdentifier("showTransaction." + identifier + ".fees")
        if kind != .purchase {
            LabeledContent("Realized profit", value: accounting?.profitCents.map(showTransactionMoney) ?? "Unknown")
                .accessibilityIdentifier("showTransaction." + identifier + ".profit")
        }
        if accounting == nil {
            Text("Cost and profit were not recorded for this historical transaction.")
                .font(.caption).foregroundStyle(.secondary)
        } else if kind != .purchase && accounting?.profitCents == nil {
            Text("Profit is unknown because some acquisition costs are unavailable.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if kind != .purchase && kind != .sale {
            Text("Trades carry acquisition cost into incoming stock after the cash difference. Cash received above that cost is realized profit.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Historical card and money snapshots remain readable after source lists,
/// shows, or working inventory have changed.
@MainActor struct ShowTransactionDetailView: View {
    let transactionID: UUID
    @State private var store: ShowBudgetStore
    @State private var confirmingUndo = false
    @State private var error: String?
    @State private var isUndoing = false
    @State private var incomingCardsExpanded = false
    @State private var outgoingCardsExpanded = false

    init(transactionID: UUID, store: ShowBudgetStore = .shared) {
        self.transactionID = transactionID
        _store = State(initialValue: store)
    }

    private var receipt: ShowTransactionReceipt? { store.transactions.first { $0.id == transactionID } }

    var body: some View {
        List {
            if let receipt {
                receiptSection(receipt)
                moneySection(receipt)
                if !receipt.incoming.isEmpty {
                    cardsSection("Cards acquired", receipt: receipt, lines: receipt.incoming, acquired: true, expanded: $incomingCardsExpanded,
                                 identifier: "acquiredCards")
                }
                if !receipt.outgoing.isEmpty {
                    cardsSection("Cards released", receipt: receipt, lines: receipt.outgoing, acquired: false, expanded: $outgoingCardsExpanded,
                                 identifier: "releasedCards")
                }
                if !receipt.draft.note.isEmpty { Section("Note") { Text(receipt.draft.note) } }
                if let error {
                    Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("showTransaction.undoError") }
                }
            } else {
                ContentUnavailableView("Transaction unavailable", systemImage: "receipt",
                                       description: Text("This transaction could not be found in your saved history."))
            }
        }
        .navigationTitle("Transaction Receipt").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let receipt, receipt.reversedAt == nil {
                VStack(spacing: 8) {
                    Button(role: .destructive) { confirmingUndo = true } label: {
                        Text("Undo Transaction").frame(maxWidth: .infinity, minHeight: 44)
                    }
                        .buttonStyle(.bordered)
                        .disabled(!store.isLoaded || store.isSaving || isUndoing)
                        .accessibilityIdentifier("showTransaction.undo")
                    Text("Review the stock and cash reversal before confirming. The original receipt remains in history.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
            }
        }
        .sheet(isPresented: $confirmingUndo) {
            if let receipt { undoSheet(receipt) }
        }
    }

    private func receiptSection(_ receipt: ShowTransactionReceipt) -> some View {
        Section {
            LabeledContent("Transaction", value: receipt.kind.title)
            LabeledContent("Show", value: receipt.showName)
            LabeledContent("Recorded", value: receipt.recordedAt.formatted(date: .abbreviated, time: .shortened))
            if let name = receipt.incomingListName { LabeledContent("Incoming list", value: name) }
            if let reversedAt = receipt.reversedAt {
                Label("Undone", systemImage: "arrow.uturn.backward.circle.fill").foregroundStyle(.secondary)
                    .accessibilityIdentifier("showTransaction.undone")
                LabeledContent("Undone on", value: reversedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private func cardsSection(_ title: String, receipt: ShowTransactionReceipt, lines: [ShowTransactionCardLine], acquired: Bool, expanded: Binding<Bool>,
                              identifier: String) -> some View {
        Section {
            DisclosureGroup(isExpanded: expanded) {
                if expanded.wrappedValue {
                    let accounting = acquired ? receipt.accounting?.incoming : receipt.accounting?.outgoing
                    let costs = Dictionary(uniqueKeysWithValues: (accounting ?? []).map { ($0.inventoryID, $0) })
                    let inventoryIDs = Set(store.inventory.map(\.id))
                    let sourceIDs = acquired ? [:] : acquisitionTransactionIDs
                    ForEach(lines, id: \.inventoryID) { line in
                        receiptCardRow(line, accounting: costs[line.inventoryID], sale: receipt.kind == .sale,
                            acquired: acquired, available: inventoryIDs.contains(line.inventoryID), sourceID: sourceIDs[line.inventoryID])
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text("\(lines.reduce(0) { $0 + $1.quantity }) cards · \(lines.count) rows")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("showTransaction.receipt." + identifier)
        }
    }

    private func receiptCardRow(_ line: ShowTransactionCardLine, accounting: ShowCostLineAccounting?, sale: Bool,
                                acquired: Bool, available: Bool, sourceID: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ShowTransactionCardRow(card: line.card, quantity: line.quantity)
            receiptLineAccounting(line, accounting: accounting, sale: sale)
            if acquired {
                if available {
                    NavigationLink {
                        ShowWorkingInventoryDetailView(itemID: line.inventoryID, store: store)
                    } label: { Label("View acquired lot", systemImage: "shippingbox") }
                        .accessibilityIdentifier("showTransaction.receipt.lot." + line.inventoryID.uuidString)
                }
                Text("Acquired by this transaction").font(.caption).foregroundStyle(.secondary)
            } else if let sourceID {
                NavigationLink {
                    ShowTransactionDetailView(transactionID: sourceID, store: store)
                } label: { Label("View acquisition receipt", systemImage: "receipt") }
                    .accessibilityIdentifier("showTransaction.receipt.source." + line.inventoryID.uuidString)
            } else {
                Text("Imported stock · Acquisition receipt unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func receiptLineAccounting(_ line: ShowTransactionCardLine, accounting: ShowCostLineAccounting?, sale: Bool) -> some View {
        VStack(spacing: 4) {
            LabeledContent("Lot cost", value: accounting?.totalCostCents.map(showTransactionMoney) ?? "Unknown")
                .accessibilityIdentifier("showTransaction.receipt.line.cost." + line.inventoryID.uuidString)
            if sale {
                LabeledContent("Sale proceeds", value: accounting?.proceedsCents.map(showTransactionMoney) ?? "Unknown")
                LabeledContent("Fees", value: accounting?.feeCents.map(showTransactionMoney) ?? "Unknown")
                LabeledContent("Realized profit", value: accounting?.profitCents.map(showTransactionMoney) ?? "Unknown")
            }
        }.font(.caption)
    }

    private var acquisitionTransactionIDs: [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for receipt in store.transactions {
            for line in receipt.incoming { result[line.inventoryID] = receipt.id }
        }
        return result
    }

    private func moneySection(_ receipt: ShowTransactionReceipt) -> some View {
        Section {
            if receipt.kind != .sale && receipt.kind != .purchase {
                LabeledContent("Agreed incoming card value", value: showTransactionMoney(receipt.incomingValueCents))
                LabeledContent("Agreed outgoing card value", value: showTransactionMoney(receipt.outgoingValueCents))
            }
            LabeledContent("Cash paid", value: showTransactionMoney(receipt.paidCents))
                .accessibilityIdentifier("showTransaction.receipt.paid")
            LabeledContent("Cash received", value: showTransactionMoney(receipt.receivedCents))
                .accessibilityIdentifier("showTransaction.receipt.received")
            LabeledContent("Allocated for buying", value: showTransactionMoney(receipt.reinvestedCents))
            if let accounting = receipt.accounting {
                LabeledContent("Change to buying funds", value: ShowTransactionCashInput.signedMoney(accounting.buyingFundsDeltaCents))
                    .accessibilityIdentifier("showTransaction.receipt.buyingFundsChange")
            }
            LabeledContent("Saved for you", value: showTransactionMoney(receipt.savedCents))
            if receipt.concessionCents != 0 {
                LabeledContent(receipt.concessionCents > 0 ? "Value conceded · No cash" : "Extra incoming value · No cash",
                               value: showTransactionMoney(abs(receipt.concessionCents)))
                    .accessibilityIdentifier("showTransaction.receipt.concession")
            }
            if receipt.kind == .sale {
                ShowSaleBreakdownView(lines: receipt.outgoing, receivedCents: receipt.receivedCents)
            }
            ShowTransactionAccountingSummary(accounting: receipt.accounting, kind: receipt.kind, identifier: "receipt")
        } header: { Text("Recorded amounts") } footer: {
            Text("These are the original receipt amounts. Card prices are market reference snapshots.")
        }
    }

    private func undoSheet(_ receipt: ShowTransactionReceipt) -> some View {
        NavigationStack {
            List {
                Section {
                    Text("Undo reverses this transaction's local stock and budget changes. Its receipt stays in history.")
                }
                Section("Stock reversal") {
                    LabeledContent("Cards returned to stock", value: receipt.outgoing.reduce(0) { $0 + $1.quantity }.formatted())
                    LabeledContent("Acquired cards removed", value: receipt.incoming.reduce(0) { $0 + $1.quantity }.formatted())
                    Text("If acquired stock has been used in a later transaction, undo that later transaction first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Cash reversal") {
                    LabeledContent("Cash paid reversed", value: showTransactionMoney(receipt.paidCents))
                    LabeledContent("Cash received reversed", value: showTransactionMoney(receipt.receivedCents))
                    LabeledContent("Buying allocation removed", value: showTransactionMoney(receipt.reinvestedCents))
                    LabeledContent("Savings removed", value: showTransactionMoney(receipt.savedCents))
                    if let accounting = receipt.accounting, accounting.feeCents > 0 {
                        LabeledContent("Fee returned to buying funds", value: showTransactionMoney(accounting.feeCents))
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("showTransaction.undoError") }
                }
            }
            .navigationTitle("Undo Transaction?").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button(role: .destructive, action: undo) {
                    HStack {
                        if isUndoing { ProgressView() }
                        Text("Confirm Undo Transaction").font(.headline)
                    }.frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(.red)
                    .disabled(isUndoing || store.isSaving || receipt.reversedAt != nil)
                    .accessibilityIdentifier("showTransaction.confirmUndo")
                    .padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { confirmingUndo = false } } }
        }
    }

    private func undo() {
        guard !isUndoing else { return }
        isUndoing = true
        defer { isUndoing = false }
        do {
            try store.undoTransaction(transactionID)
            error = nil
            confirmingUndo = false
        } catch { self.error = error.localizedDescription }
    }
}

struct ShowTransactionCardRow: View {
    let card: CardCandidate
    let quantity: Int
    var quantityTitle = "Quantity"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: card.imageURL) { phase in
                if let image = phase.image { image.resizable().scaledToFit() }
                else {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                        .overlay { Image(systemName: "rectangle.portrait").foregroundStyle(.secondary) }
                }
            }.frame(width: 54, height: 76).clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.name).font(.headline).foregroundStyle(.primary)
                Text([card.set, card.number.isEmpty ? "" : "#" + card.number].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(card.identity.printing + " · " + card.identity.condition)
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(quantityTitle): \(quantity)").font(.subheadline).foregroundStyle(.primary)
                Text(card.marketPrice.map { "Market reference: " + $0.money + " each" } ?? "Market reference unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 4)
    }
}

private enum ShowTransactionInputFailure: LocalizedError {
    case chooseIncoming, chooseOutgoing, invalidAmount(String), invalidCash(String), confirmEvenTrade, cashDirection(String)
    var errorDescription: String? {
        switch self {
        case .chooseIncoming: return "Choose a nonempty scanned list for the incoming cards."
        case .chooseOutgoing: return "Select cards and quantities from your local stock."
        case .invalidAmount(let label): return "Enter \(label) in USD with up to two decimal places."
        case .invalidCash(let label): return "Enter \(label) in whole dollars."
        case .confirmEvenTrade: return "Choose a cash trade type or tap Make Even Trade to confirm no cash changes hands."
        case .cashDirection(let message): return message
        }
    }
}

private func showTransactionMoney(_ cents: Int64) -> String { ShowBudgetMoney.decimal(cents).money }
private func showTransactionInput(_ cents: Int64) -> String {
    String(cents / 100) + "." + String(format: "%02lld", cents % 100)
}
