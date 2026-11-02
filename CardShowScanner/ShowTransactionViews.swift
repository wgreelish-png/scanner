import SwiftUI
import SwiftData
import UIKit

/// A transaction is confirmed once, using one stable command identity. The
/// selected scan list is a snapshot; recording never edits its rows or prices.
@MainActor struct ShowTransactionForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
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
    @State private var incomingDefault: Int64?
    @State private var incomingValueEdited = false
    @State private var outgoingValueEdited = false
    @State private var makeEven = false
    @State private var note = ""
    @State private var selectingInventory = false
    @State private var editingIncomingList = false
    @State private var editingSaleCash = false
    @State private var incomingEditMessage: String?
    @State private var saleReceivedEdited = false
    @State private var error: String?
    @State private var isRecording = false
    @State private var didPrepare = false
    @FocusState private var focused: MoneyField?

    private enum MoneyField: Hashable { case incoming, outgoing, note }

    init(store: ShowBudgetStore = .shared, initialKind: ShowTransactionKind = .sale,
         initialListID: UUID? = nil) {
        _store = State(initialValue: store)
        _kind = State(initialValue: initialKind)
        _incomingListID = State(initialValue: initialListID)
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
    private var saleText: String { saleReceivedEdited ? saleReceived : outgoingReference.map(showTransactionInput) ?? "" }
    private var outgoingText: String { outgoingValueEdited ? outgoingValue : outgoingReference.map(showTransactionInput) ?? "" }
    private var evaluatedPreview: (amounts: ShowTransactionAmounts?, message: String?) {
        do {
            return (try ShowTransactionMath.calculate(preparedDraft(), saleReinvestmentPercent: selectedShow?.reinvestmentPercent ?? 65), nil)
        } catch { return (nil, error.localizedDescription) }
    }
    private func canRecord(preview: ShowTransactionAmounts?) -> Bool {
        guard let showID else { return false }
        return store.isLoaded && !store.isSaving && !isRecording && !selectingInventory && !editingIncomingList && !editingSaleCash && !context.hasChanges && store.canRecord(showID: showID) && preview != nil
    }

    var body: some View {
        let evaluation = evaluatedPreview
        NavigationStack {
            Form {
                transactionSection
                if kind != .sale { incomingSection }
                if kind != .purchase { outgoingSection }
                valuesSection
                previewSection(evaluation.amounts, message: evaluation.message)
                Section {
                    TextField("Note, optional", text: $note, axis: .vertical)
                        .lineLimit(2...4).focused($focused, equals: .note).accessibilityIdentifier("showTransaction.note")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("showTransaction.error") }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top) { checkoutBar(evaluation.amounts) }
            .navigationTitle("Record \(kind.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !selectingInventory && !editingIncomingList { Button("Cancel") { dismiss() } }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if !selectingInventory && !editingIncomingList && !editingSaleCash {
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
                if previous == .purchase || next == .purchase { incomingValueEdited = false }
                updateIncomingDefault()
            }
            .onChange(of: outgoingQuantities) { _, _ in
                makeEven = false
                if !outgoingValueEdited { outgoingValue = outgoingReference.map(showTransactionInput) ?? "" }
                if !saleReceivedEdited { saleReceived = outgoingReference.map(showTransactionInput) ?? "" }
            }
        }
        .sheet(isPresented: $editingSaleCash, onDismiss: {
            DiagnosticLog.shared.record("show_transaction.cash_edit", ["phase": "dismissed"])
        }) {
            ShowSaleAmountEditor(initialText: saleText) { amount in
                // Opening/focusing or accepting an unchanged value must not
                // turn the automatic rounded total into a manual override.
                if ShowBudgetMoney.parse(saleText) != amount {
                    saleReceived = showTransactionInput(amount)
                    saleReceivedEdited = true
                }
            }
        }
    }

    private func checkoutBar(_ preview: ShowTransactionAmounts?) -> some View {
        VStack(spacing: 8) {
            HStack {
                if let preview {
                    Text(preview.receivedCents > 0 ? "You receive" : preview.paidCents > 0 ? "You pay" : isTrade ? "Even trade" : "Cash total")
                    Spacer()
                    Text(showTransactionMoney(max(preview.paidCents, preview.receivedCents))).bold().monospacedDigit()
                } else {
                    Text("Review transaction amounts").foregroundStyle(.secondary)
                    Spacer()
                    Text("—").monospacedDigit()
                }
            }.font(.subheadline)
            Button(action: record) {
                HStack {
                    if isRecording { ProgressView() }
                    Text("Record Transaction").font(.headline)
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent).disabled(!canRecord(preview: preview))
                .accessibilityIdentifier("showTransaction.record")
        }.padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
    }

    private func endEditing() {
        focused = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var transactionSection: some View {
        Section {
            Picker("Transaction", selection: $kind) {
                ForEach(ShowTransactionKind.allCases) { kind in Text(kind.title).tag(kind) }
            }.pickerStyle(.menu).accessibilityIdentifier("showTransaction.kind")
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

    private var incomingSection: some View {
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
            if incomingLists.contains(where: { $0.id == incomingListID }) {
                Button("Review / Edit Selected List", systemImage: "pencil") {
                    endEditing(); editingIncomingList = true
                }.frame(minHeight: 44).accessibilityIdentifier("showTransaction.editIncomingList")
            }
            if let incomingEditMessage { Text(incomingEditMessage).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("showTransaction.incomingEditStatus") }
            ForEach(incoming) { line in
                ShowTransactionCardRow(card: line.card, quantity: line.quantity)
            }
            if incomingLists.isEmpty {
                Text("Scan cards into a list before recording incoming stock.").foregroundStyle(.secondary)
            } else if incomingListID != nil {
                Button("Reload Incoming List", action: loadIncoming).frame(minHeight: 44)
                    .accessibilityIdentifier("showTransaction.reloadIncoming")
            }
        } header: {
            Text("Cards coming in")
        } footer: {
            Text("The whole selected list becomes local stock. Your scanned list and its market reference prices stay as saved.")
        }
    }

    private var outgoingSection: some View {
        Section {
            Button {
                endEditing(); selectingInventory = true
            } label: {
                Label(selectedLines.isEmpty ? "Select Inventory Cards" : "Change Selected Cards", systemImage: "shippingbox")
                    .frame(minHeight: 48)
            }.accessibilityIdentifier("showTransaction.selectInventory")
            LabeledContent("Selected quantity", value: outgoingQuantities.values.reduce(0, +).formatted())
            if !selectedLines.isEmpty {
                DisclosureGroup("Selected cards · \(selectedLines.count) rows") {
                    ForEach(selectedLines, id: \.inventoryID) { line in
                        ShowTransactionCardRow(card: line.card, quantity: line.quantity)
                    }
                }
            }
        } header: { Text(kind == .sale ? "Cards being sold" : "Cards going out") }
    }

    private var valuesSection: some View {
        Section {
            if kind == .sale {
                Button {
                    guard !isRecording else { return }
                    endEditing()
                    DiagnosticLog.shared.record("show_transaction.cash_edit", ["phase": "requested"])
                    editingSaleCash = true
                } label: {
                    HStack {
                        Text("Actual cash received").foregroundStyle(.primary)
                        Spacer()
                        Text(ShowBudgetMoney.parse(saleText).map(showTransactionMoney) ?? "Enter amount")
                            .monospacedDigit()
                        Image(systemName: "pencil")
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel("Edit actual cash received")
                    .accessibilityValue(saleText)
                    .accessibilityIdentifier("showTransaction.editSaleAmount")
                if let suggested = outgoingReference {
                    LabeledContent("Rounded market total", value: showTransactionMoney(suggested))
                    Text("Each card defaults to its market value rounded to the nearest dollar.")
                        .font(.caption).foregroundStyle(.secondary)
                    if saleReceivedEdited {
                        Button("Use Rounded Market Total") {
                            saleReceivedEdited = false; saleReceived = showTransactionInput(suggested)
                        }.accessibilityIdentifier("showTransaction.resetSaleTotal")
                    }
                }
                if let cash = ShowBudgetMoney.parse(saleText) {
                    ShowSaleBreakdownView(lines: selectedLines, receivedCents: cash)
                }
                Text("Enter the total the customer actually paid for all selected cards.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                amountField(kind == .purchase ? "Actual cash paid" : "Agreed incoming card value",
                            text: Binding(get: { incomingValue }, set: {
                    incomingValue = $0; incomingValueEdited = true; makeEven = false
                }), field: .incoming)
                if let incomingDefault {
                    LabeledContent(kind == .purchase ? "Calculated Cash Offer" : "Calculated Trade Offer",
                                   value: showTransactionMoney(incomingDefault))
                    if incomingValueEdited {
                        Button(kind == .purchase ? "Use Calculated Cash Offer" : "Use Calculated Trade Offer") {
                            incomingValueEdited = false
                            incomingValue = showTransactionInput(incomingDefault)
                            makeEven = false
                        }.frame(minHeight: 44)
                    }
                } else {
                    Text("A complete calculated offer is unavailable. Enter the agreed total explicitly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isTrade {
                    amountField("Agreed outgoing card value", text: Binding(get: { outgoingText }, set: {
                        outgoingValue = $0; outgoingValueEdited = true; makeEven = false
                    }), field: .outgoing)
                    if let outgoingReference {
                        LabeledContent("Rounded outgoing market total", value: showTransactionMoney(outgoingReference))
                        if outgoingValueEdited {
                            Button("Use Rounded Market Total") {
                                outgoingValueEdited = false
                                outgoingValue = showTransactionInput(outgoingReference)
                                makeEven = false
                            }.frame(minHeight: 44)
                        }
                    } else {
                        Text("Some outgoing cards have no market price. Enter their agreed total explicitly.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if kind == .trade { evenTradeControl }
                    Text("Agreed card values determine the cash difference. Market reference prices on the cards stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: { Text(kind == .sale || kind == .purchase ? "Actual cash" : "Agreed card values") }
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

    private func previewSection(_ preview: ShowTransactionAmounts?, message: String?) -> some View {
        Section {
            if let preview {
                LabeledContent("Cash you pay", value: showTransactionMoney(preview.paidCents))
                    .accessibilityIdentifier("showTransaction.preview.paid")
                LabeledContent("Cash you receive", value: showTransactionMoney(preview.receivedCents))
                    .accessibilityIdentifier("showTransaction.preview.received")
                LabeledContent("Added to buying funds", value: showTransactionMoney(preview.reinvestedCents))
                LabeledContent("Saved for you", value: showTransactionMoney(preview.savedCents))
                if preview.concessionCents != 0 {
                    LabeledContent(preview.concessionCents > 0 ? "Value conceded" : "Extra incoming value",
                                   value: showTransactionMoney(abs(preview.concessionCents)))
                }
                if kind == .sale {
                    let percent = selectedShow?.reinvestmentPercent ?? 65
                    Text("This show's sale split: \(percent)% for buying and \(100 - percent)% saved for you.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if kind == .tradeReceiveCash {
                    Text("All cash received from this trade goes to buying funds.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let message {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Profit unavailable: acquisition costs are not tracked for this stock.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Transaction preview") }
    }

    private func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        var inventoryError: String?
        do { try ShowInventoryBridge.seedFromImportedList(context: context, store: store) }
        catch { inventoryError = error.localizedDescription }
        showID = store.eligibleActiveShow?.id ?? store.visibleShows.first(where: { store.canRecord(showID: $0.id) })?.id
        if incomingListID != nil { loadIncoming() }
        if let inventoryError { error = inventoryError }
    }

    private func loadIncoming() {
        incoming = []; capturedListID = nil; capturedListName = nil
        incomingValueEdited = false; incomingValue = ""; incomingDefault = nil; makeEven = false; incomingEditMessage = nil
        guard let incomingListID else { return }
        guard let list = incomingLists.first(where: { $0.id == incomingListID }) else {
            error = "This scanned list is no longer available. Choose another list."
            return
        }
        do {
            incoming = try ShowTransactionListService.incomingCards(for: list)
            capturedListID = list.id; capturedListName = list.name
            error = nil
            updateIncomingDefault()
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
            let changed = incoming != updated.cards || incomingDefault != updated.defaultValueCents || capturedListName != updated.name
            incoming = updated.cards; capturedListID = updated.listID; capturedListName = updated.name
            incomingDefault = updated.defaultValueCents
            if !incomingValueEdited { incomingValue = updated.defaultValueCents.map(showTransactionInput) ?? "" }
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

    private func updateIncomingDefault() {
        guard kind != .sale, let incomingListID,
              let list = incomingLists.first(where: { $0.id == incomingListID }) else { return }
        do {
            incomingDefault = try ShowTransactionListService.defaultIncomingValue(for: list, kind: kind, context: context)
            if !incomingValueEdited { incomingValue = incomingDefault.map(showTransactionInput) ?? "" }
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
            guard let amount = ShowBudgetMoney.parse(incomingValue) else {
                throw ShowTransactionInputFailure.invalidAmount(kind == .purchase ? "cash paid" : "incoming card value")
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
            guard let amount = ShowBudgetMoney.parse(saleText) else {
                throw ShowTransactionInputFailure.invalidAmount("actual cash received")
            }
            draft.saleReceivedCents = amount
        } else if isTrade {
            guard let amount = ShowBudgetMoney.parse(outgoingText) else {
                throw ShowTransactionInputFailure.invalidAmount("outgoing card value")
            }
            draft.outgoingValueCents = amount; draft.makeEven = makeEven
            if kind == .trade && !makeEven && draft.incomingValueCents != amount {
                throw ShowTransactionInputFailure.confirmEvenTrade
            }
            if kind == .tradePayCustomer && draft.incomingValueCents <= amount {
                throw ShowTransactionInputFailure.cashDirection("Pay Customer requires incoming value greater than outgoing value.")
            }
            if kind == .tradeReceiveCash && amount <= draft.incomingValueCents {
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
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func hasLegacyOutcome(_ list: CardList) -> Bool {
        list.transactionOutcomeData != nil && list.outcomeRecord?.kind != .nothingHappened
    }
}

/// Cash editing owns only local text/focus. No stock validation, allocation
/// sorting or checkout geometry changes run for its keyboard/typing updates.
@MainActor private struct ShowSaleAmountEditor: View {
    let onSave: (Int64) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isApplying = false
    @State private var startedAt = Date()
    @FocusState private var amountFocused: Bool

    init(initialText: String, onSave: @escaping (Int64) -> Void) {
        _text = State(initialValue: initialText)
        self.onSave = onSave
    }

    private var amount: Int64? { ShowBudgetMoney.parse(text) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Total cash received").font(.headline)
                HStack(spacing: 12) {
                    Text("USD").foregroundStyle(.secondary)
                    TextField("0.00", text: $text)
                        .keyboardType(.decimalPad).focused($amountFocused)
                        .font(.largeTitle).monospacedDigit()
                        .accessibilityLabel("Actual cash received")
                        .accessibilityIdentifier("showTransaction.amount.sale")
                    Button {
                        text = ""; amountFocused = true
                    } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .disabled(text.isEmpty || isApplying)
                        .accessibilityLabel("Clear amount")
                        .accessibilityIdentifier("showTransaction.cashEditor.clear")
                }.frame(minHeight: 56)
                Text("Enter a USD amount with up to two decimal places.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("This is the total the customer pays for the selected cards.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }.padding(24)
                .navigationTitle("Sale Amount").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            DiagnosticLog.shared.record("show_transaction.cash_edit", ["phase": "cancelled"])
                            amountFocused = false; dismiss()
                        }.disabled(isApplying).accessibilityIdentifier("showTransaction.cashEditor.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: apply).fontWeight(.semibold)
                            .disabled(amount == nil || isApplying)
                            .accessibilityIdentifier("showTransaction.cashEditor.done")
                    }
                }
        }
        .interactiveDismissDisabled(isApplying)
        .task {
            DiagnosticLog.shared.record("show_transaction.cash_edit", ["phase": "presented"])
            await Task.yield()
            guard !Task.isCancelled else { return }
            amountFocused = true
        }
        .onChange(of: amountFocused) { _, focused in
            DiagnosticLog.shared.record("show_transaction.cash_edit", ["phase": focused ? "focused" : "unfocused"])
        }
        .onDisappear {
            DiagnosticLog.shared.record("show_transaction.cash_edit", ["phase": "closed",
                "elapsed_ms": String(Int(max(0, min(3_600_000, Date().timeIntervalSince(startedAt) * 1_000))))])
        }
    }

    private func apply() {
        guard !isApplying, let amount else { return }
        isApplying = true
        amountFocused = false
        DiagnosticLog.shared.record("show_transaction.cash_edit", ["phase": "applied"])
        onSave(amount)
        dismiss()
    }
}


@MainActor private struct ShowSaleBreakdownView: View {
    let lines: [ShowTransactionCardLine]
    let receivedCents: Int64
    @State private var expanded = false

    var body: some View {
        if !lines.isEmpty {
            if ShowSaleMath.suggestedTotal(lines) != receivedCents,
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
                    if let allocations = ShowSaleMath.allocations(lines, receivedCents: receivedCents) {
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

/// Historical card and money snapshots remain readable after source lists,
/// shows, or working inventory have changed.
@MainActor struct ShowTransactionDetailView: View {
    let transactionID: UUID
    @State private var store: ShowBudgetStore
    @State private var confirmingUndo = false
    @State private var error: String?
    @State private var isUndoing = false

    init(transactionID: UUID, store: ShowBudgetStore = .shared) {
        self.transactionID = transactionID
        _store = State(initialValue: store)
    }

    private var receipt: ShowTransactionReceipt? { store.transactions.first { $0.id == transactionID } }

    var body: some View {
        List {
            if let receipt {
                receiptSection(receipt)
                if !receipt.incoming.isEmpty { cardsSection("Cards acquired", lines: receipt.incoming) }
                if !receipt.outgoing.isEmpty { cardsSection("Cards released", lines: receipt.outgoing) }
                moneySection(receipt)
                if !receipt.draft.note.isEmpty { Section("Note") { Text(receipt.draft.note) } }
                if let error {
                    Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("showTransaction.undoError") }
                }
                if receipt.reversedAt == nil {
                    Section {
                        Button("Undo Transaction", role: .destructive) { confirmingUndo = true }
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .disabled(!store.isLoaded || store.isSaving || isUndoing)
                            .accessibilityIdentifier("showTransaction.undo")
                    } footer: {
                        Text("Review the stock and cash reversal before confirming. The original receipt remains in history.")
                    }
                }
            } else {
                ContentUnavailableView("Transaction unavailable", systemImage: "receipt",
                                       description: Text("This transaction could not be found in your saved history."))
            }
        }
        .navigationTitle("Transaction Receipt").navigationBarTitleDisplayMode(.inline)
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

    private func cardsSection(_ title: String, lines: [ShowTransactionCardLine]) -> some View {
        Section(title) {
            ForEach(lines, id: \.inventoryID) { line in
                ShowTransactionCardRow(card: line.card, quantity: line.quantity)
            }
        }
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
            LabeledContent("Saved for you", value: showTransactionMoney(receipt.savedCents))
            if receipt.concessionCents != 0 {
                LabeledContent(receipt.concessionCents > 0 ? "Value conceded · No cash" : "Extra incoming value · No cash",
                               value: showTransactionMoney(abs(receipt.concessionCents)))
                    .accessibilityIdentifier("showTransaction.receipt.concession")
            }
            if receipt.kind == .sale {
                ShowSaleBreakdownView(lines: receipt.outgoing, receivedCents: receipt.receivedCents)
            }
            Text("Profit unavailable: acquisition costs are not tracked for this stock.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Recorded amounts") } footer: {
            Text("These are the original receipt amounts. Card prices above are market reference snapshots.")
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
                }
                if let error {
                    Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("showTransaction.undoError") }
                }
                Section {
                    Button(role: .destructive, action: undo) {
                        HStack {
                            Spacer()
                            if isUndoing { ProgressView() }
                            Text("Confirm Undo Transaction").font(.headline)
                            Spacer()
                        }.frame(minHeight: 64)
                    }.disabled(isUndoing || store.isSaving || receipt.reversedAt != nil)
                        .accessibilityIdentifier("showTransaction.confirmUndo")
                }
            }
            .navigationTitle("Undo Transaction?").navigationBarTitleDisplayMode(.inline)
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
    case chooseIncoming, chooseOutgoing, invalidAmount(String), confirmEvenTrade, cashDirection(String)
    var errorDescription: String? {
        switch self {
        case .chooseIncoming: return "Choose a nonempty scanned list for the incoming cards."
        case .chooseOutgoing: return "Select cards and quantities from your local stock."
        case .invalidAmount(let label): return "Enter \(label) in USD with up to two decimal places."
        case .confirmEvenTrade: return "Choose a cash trade type or tap Make Even Trade to confirm no cash changes hands."
        case .cashDirection(let message): return message
        }
    }
}

private func showTransactionMoney(_ cents: Int64) -> String { ShowBudgetMoney.decimal(cents).money }
private func showTransactionInput(_ cents: Int64) -> String {
    String(cents / 100) + "." + String(format: "%02lld", cents % 100)
}
