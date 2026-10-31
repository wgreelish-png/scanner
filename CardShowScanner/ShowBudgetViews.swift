import SwiftUI

/// A small entry point that can live in Lists or the Scan home screen.
@MainActor struct ShowBudgetSummaryCard: View {
    @State private var store: ShowBudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    init(store: ShowBudgetStore = .shared) { _store = State(initialValue: store) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 60, paused: !isVisible || scenePhase != .active)) { _ in summary }
            .onAppear { isVisible = true }.onDisappear { isVisible = false }
    }

    private var summary: some View {
        NavigationLink { ShowBudgetView(store: store) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Show Budget", systemImage: "wallet.bifold").font(.headline)
                    Spacer()
                }
                if let show = store.activeShow, let totals = try? show.totals() {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                    layout {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(budgetBalanceTitle(show, store: store)).font(.caption).foregroundStyle(.secondary)
                            Text(budgetMoney(totals.availableCents)).font(.title2.bold())
                                .foregroundStyle(totals.availableCents < 0 ? Color.orange : Color.primary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Saved for you").font(.caption).foregroundStyle(.secondary)
                            Text(budgetMoney(totals.savedCents)).font(.headline).foregroundStyle(.indigo)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(show.name).font(.caption).foregroundStyle(.secondary)
                    Text(show.scheduleStatus(on: store.currentDate, calendar: store.calendar).title)
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("budget.summaryStatus")
                    if let dates = budgetShowDateLabel(show) {
                        Text(dates).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("budget.summaryDates")
                    }
                } else {
                    Text(store.isLoaded ? "Set buying funds and keep 35% of gross sales for you." : "Your budget needs attention. Open it to retry loading.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(.primary)
        }.buttonStyle(.plain).accessibilityIdentifier("budget.summary")
            .accessibilityHint("Opens your show budget and cash transactions.")
    }
}

@MainActor struct ShowBudgetView: View {
    @State private var store: ShowBudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var sheet: BudgetDashboardSheet?
    @State private var error: String?
    init(store: ShowBudgetStore = .shared) { _store = State(initialValue: store) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 60, paused: !isVisible || scenePhase != .active)) { _ in dashboard }
        .onAppear { isVisible = true }.onDisappear { isVisible = false }
        .navigationTitle("Show Budget")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { dashboardToolbar }
        .sheet(item: $sheet) { destination in
            NavigationStack {
                switch destination {
                case .newShow:
                    BudgetSetupForm(store: store, editing: nil) { _ in sheet = nil }
                case .edit(let id):
                    if let show = store.book.shows.first(where: { $0.id == id }) {
                        BudgetSetupForm(store: store, editing: show) { _ in sheet = nil }
                    } else { ContentUnavailableView("Show unavailable", systemImage: "tray") }
                case .record(let id, let kind):
                    BudgetEntryForm(store: store, showID: id, initialKind: kind) { sheet = nil }
                }
            }
        }
    }

    private var dashboard: some View {
        List {
            if !store.isLoaded {
                BudgetLoadFailure(store: store)
            } else {
                if !store.book.shows.isEmpty { showSelector }
                if let show = store.activeShow, let totals = try? show.totals() {
                    balanceSection(show, totals: totals)
                    dateSection(show)
                    recordSection(show)
                    totalsSection(totals)
                    entriesSection(show)
                } else {
                    Section {
                        ContentUnavailableView {
                            Label("Your show buying budget", systemImage: "wallet.bifold")
                        } description: {
                            Text("Start with your buying funds. Gross cash received is split 65% for buying and 35% for you. Fees reduce buying funds separately.")
                        } actions: {
                            Button("Set Up Show Budget") { sheet = .newShow }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("budget.setup")
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("budget.error") }
                }
            }
        }
    }

    @ToolbarContentBuilder private var dashboardToolbar: some ToolbarContent {
        if store.isLoaded {
            ToolbarItem(placement: .topBarTrailing) {
                Button { sheet = .newShow } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New Show").accessibilityIdentifier("budget.newShow")
            }
            if let show = store.activeShow {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { sheet = .edit(show.id) }.accessibilityIdentifier("budget.editShow")
                }
            }
        }
    }

    private var showSelector: some View {
        Section {
            Picker("Show", selection: Binding(get: { store.book.activeShowID }, set: { id in
                do { try store.select(showID: id); error = nil }
                catch { self.error = budgetError(error) }
            })) {
                if store.book.activeShowID == nil { Text("Choose a show").tag(Optional<UUID>.none) }
                ForEach(store.book.shows.reversed()) { show in Text(show.name).tag(Optional(show.id)) }
            }.pickerStyle(.menu).accessibilityIdentifier("budget.show")
        }
    }

    private func balanceSection(_ show: ShowBudgetEvent, totals: ShowBudgetTotals) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text(budgetBalanceTitle(show, store: store)).font(.subheadline).foregroundStyle(.secondary)
                Text(budgetMoney(totals.availableCents)).font(.largeTitle.bold()).monospacedDigit()
                    .foregroundStyle(totals.availableCents < 0 ? Color.orange : Color.primary)
                    .accessibilityIdentifier("budget.available")
                if totals.availableCents < 0 {
                    Label("Over budget", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
                HStack {
                    Label("Saved for you", systemImage: "person.crop.circle")
                    Spacer()
                    Text(budgetMoney(totals.savedCents)).font(.headline).monospacedDigit()
                        .accessibilityIdentifier("budget.saved")
                }.foregroundStyle(.indigo)
                Text("\(show.reinvestmentPercent)% of gross cash received goes toward buying; \(100 - show.reinvestmentPercent)% is reserved for you. Fees come out of buying funds.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 8)
        } header: { Text(show.name) }
    }

    private func dateSection(_ show: ShowBudgetEvent) -> some View {
        Section("Show dates") {
            LabeledContent("Status", value: show.scheduleStatus(on: store.currentDate, calendar: store.calendar).title)
                .accessibilityIdentifier("budget.scheduleStatus")
            if !store.canRecord(showID: show.id) {
                Text(budgetScheduleMessage(show, store: store)).font(.caption).foregroundStyle(.secondary)
            }
            if let dates = budgetShowDateLabel(show) {
                Text(dates).accessibilityIdentifier("budget.showDates")
            } else {
                Button("Set Show Dates") { sheet = .edit(show.id) }
                    .accessibilityIdentifier("budget.setDates")
            }
        }
    }

    private func recordSection(_ show: ShowBudgetEvent) -> some View {
        Section("Record actual cash") {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                recordButton("Buy", symbol: "arrow.up.right", kind: .purchase, showID: show.id, id: "budget.buy")
                recordButton("Sell", symbol: "arrow.down.left", kind: .sale, showID: show.id, id: "budget.sell")
                recordButton("Trade", symbol: "arrow.left.arrow.right", kind: .trade, showID: show.id, id: "budget.trade")
            }.padding(.vertical, 4)
            Text("List outcomes update this budget automatically. Use these actions for cash you have not already recorded.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func recordButton(_ title: String, symbol: String, kind: ShowBudgetEntryKind, showID: UUID, id: String) -> some View {
        Button {
            guard store.canRecord(showID: showID) else { return }
            sheet = .record(showID, kind)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.subheadline.weight(.semibold))
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
        }.buttonStyle(.bordered).tint(.indigo).disabled(!store.canRecord(showID: showID)).accessibilityIdentifier(id)
    }

    private func totalsSection(_ totals: ShowBudgetTotals) -> some View {
        Section("Cash breakdown") {
            LabeledContent("Starting funds", value: budgetMoney(totals.startingCents))
            LabeledContent("Gross cash received", value: budgetMoney(totals.grossReceivedCents))
                .accessibilityIdentifier("budget.grossReceived")
            LabeledContent("Allocated for buying", value: budgetMoney(totals.reinvestedCents))
            LabeledContent("Cash spent", value: budgetMoney(totals.paidCents))
            LabeledContent("Fees", value: budgetMoney(totals.feesCents))
            LabeledContent("Cash remaining, including savings", value: budgetMoney(totals.cashOnHandCents))
            Text("Available to buy = starting funds + buying allocation − cash spent − fees. Trade values are excluded; only cash paid or received is recorded.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func entriesSection(_ show: ShowBudgetEvent) -> some View {
        Section("Transactions") {
            if show.entries.isEmpty { Text("No cash transactions yet.").foregroundStyle(.secondary) }
            ForEach(show.entries.reversed()) { entry in
                NavigationLink { BudgetEntryDetail(store: store, showID: show.id, entryID: entry.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.kind.title).font(.headline)
                            if entry.voidedAt != nil { Text("Voided").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(entryCashLabel(entry)).monospacedDigit().strikethrough(entry.voidedAt != nil)
                        }
                        if let name = entry.listName { Text(name).font(.caption).foregroundStyle(.secondary) }
                        if !entry.note.isEmpty { Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        Text(entry.recordedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }.accessibilityIdentifier("budget.entry." + entry.id.uuidString)
            }
        }
    }
}

private enum BudgetDashboardSheet: Identifiable {
    case newShow, edit(UUID), record(UUID, ShowBudgetEntryKind)
    var id: String {
        switch self {
        case .newShow: return "new"
        case .edit(let id): return "edit." + id.uuidString
        case .record(let id, let kind): return "record." + id.uuidString + kind.rawValue
        }
    }
}

/// List outcomes describe what happened; recording a confirmed cash amount is
/// a separate explicit action so an estimate can never silently debit a budget.
@MainActor struct RecordListBudgetButton: View {
    let listID: UUID
    let listName: String
    var suggestedKind: ShowBudgetEntryKind = .purchase
    let startsWithCashPaid: Bool
    @State private var store: ShowBudgetStore
    @State private var showing = false

    init(listID: UUID, listName: String, suggestedKind: ShowBudgetEntryKind = .purchase, startsWithCashPaid: Bool = false,
         store: ShowBudgetStore = .shared) {
        self.listID = listID; self.listName = listName; self.suggestedKind = suggestedKind
        self.startsWithCashPaid = startsWithCashPaid
        _store = State(initialValue: store)
    }

    var body: some View {
        Button {
            guard store.activeShow == nil || store.eligibleActiveShow != nil else { return }
            showing = true
        } label: {
            Label("Record Cash in Show Budget", systemImage: "wallet.bifold")
        }.buttonStyle(.borderless)
            .disabled(!store.isLoaded || (store.activeShow != nil && store.eligibleActiveShow == nil))
            .accessibilityIdentifier("budget.recordListCash")
            .sheet(isPresented: $showing) {
                BudgetListRecordFlow(store: store, listID: listID, listName: listName, kind: suggestedKind,
                                     startsWithCashPaid: startsWithCashPaid)
            }
    }
}

@MainActor private struct BudgetListRecordFlow: View {
    let store: ShowBudgetStore
    let listID: UUID
    let listName: String
    let kind: ShowBudgetEntryKind
    let startsWithCashPaid: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var createdShowID: UUID?

    var body: some View {
        NavigationStack {
            if !store.isLoaded { List { BudgetLoadFailure(store: store) } }
            else if let id = createdShowID ?? store.book.activeShowID {
                BudgetEntryForm(store: store, showID: id, initialKind: kind, listID: listID, listName: listName,
                                startsWithCashPaid: startsWithCashPaid) { dismiss() }
            } else {
                BudgetSetupForm(store: store, editing: nil) { createdShowID = $0 }
            }
        }
    }
}

@MainActor private struct BudgetSetupForm: View {
    let store: ShowBudgetStore
    let editing: ShowBudgetEvent?
    let onSaved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var starting: String
    @State private var hasDates: Bool
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var error: String?
    @State private var saved = false
    @State private var saving = false
    @FocusState private var focused: Field?
    private enum Field: Hashable { case name, starting }
    private var reinvestmentPercent: Int { editing?.reinvestmentPercent ?? 65 }

    init(store: ShowBudgetStore, editing: ShowBudgetEvent?, onSaved: @escaping (UUID) -> Void) {
        self.store = store; self.editing = editing; self.onSaved = onSaved
        _name = State(initialValue: editing?.name ?? "Card Show " + Date().formatted(date: .abbreviated, time: .omitted))
        _starting = State(initialValue: editing.map { CSVExportService.number(ShowBudgetMoney.decimal($0.startingCents)) } ?? "")
        let today = Calendar.current.startOfDay(for: Date())
        _hasDates = State(initialValue: editing == nil || editing?.startDate != nil)
        _startDate = State(initialValue: editing?.startDate ?? today)
        _endDate = State(initialValue: editing?.endDate ?? editing?.startDate ?? today)
    }

    var body: some View {
        Form {
            Section("Show") {
                TextField("Show name", text: $name).focused($focused, equals: .name)
                    .submitLabel(.done).onSubmit { focused = nil }.accessibilityIdentifier("budget.name")
                    .onChange(of: name) { _, value in if value.count > 120 { name = String(value.prefix(120)) } }
                TextField("Starting buying funds, e.g. 300", text: $starting)
                    .keyboardType(.decimalPad).focused($focused, equals: .starting).accessibilityIdentifier("budget.starting")
            }
            Section("Show dates") {
                Toggle("Set show dates", isOn: $hasDates).accessibilityIdentifier("budget.hasDates")
                if hasDates {
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                        .accessibilityIdentifier("budget.startDate")
                        .onChange(of: startDate) { _, value in if endDate < value { endDate = value } }
                    DatePicker("End date", selection: $endDate, in: startDate..., displayedComponents: .date)
                        .accessibilityIdentifier("budget.endDate")
                }
            }
            Section("Your split") {
                LabeledContent("Reinvest", value: "\(reinvestmentPercent)% of gross sales")
                LabeledContent("Saved for you", value: "\(100 - reinvestmentPercent)% of gross sales")
                if reinvestmentPercent == 65 {
                    Text("A $200 sale allocates $130 for buying and $70 for you. If that sale has $10 in fees, available buying funds increase by $120.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The split applies to gross cash received. Fees reduce buying funds separately.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if editing != nil {
                    Text("Changing starting funds recalculates the available balance. Recorded transactions and their allocations are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("budget.error") } }
            Section {
                Button(editing == nil ? "Create Show Budget" : "Save Show") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ShowBudgetMoney.parse(starting) == nil || saving || saved || !store.isLoaded)
                    .accessibilityIdentifier("budget.create")
            }
        }
        .navigationTitle(editing == nil ? "New Show Budget" : "Edit Show")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }
                    .fixedSize().frame(minWidth: 60).accessibilityIdentifier("budget.keyboardDone")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        guard !saving, !saved, let cents = ShowBudgetMoney.parse(starting) else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            let id: UUID
            let start = hasDates ? Calendar.current.startOfDay(for: startDate) : nil
            let end = hasDates ? Calendar.current.startOfDay(for: endDate) : nil
            if let editing {
                try store.update(showID: editing.id, name: name, startingCents: cents, startDate: start, endDate: end)
                id = editing.id
            } else { id = try store.create(name: name, startingCents: cents, startDate: start, endDate: end) }
            saved = true; onSaved(id)
        } catch { self.error = budgetError(error) }
    }
}

private enum BudgetTradeDirection: String, CaseIterable, Identifiable {
    case none = "No cash", paid = "I paid", received = "I received"
    var id: String { rawValue }
}

@MainActor private struct BudgetEntryForm: View {
    let store: ShowBudgetStore
    let showID: UUID
    let listID: UUID?
    let listName: String?
    let onRecorded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var kind: ShowBudgetEntryKind
    @State private var direction: BudgetTradeDirection = .none
    @State private var amount = ""
    @State private var fees = ""
    @State private var note = ""
    @State private var draftID = UUID()
    @State private var recordedAt = Date()
    @State private var saved = false
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: MoneyField?
    private enum MoneyField: Hashable { case amount, fees, note }

    init(store: ShowBudgetStore, showID: UUID, initialKind: ShowBudgetEntryKind,
         listID: UUID? = nil, listName: String? = nil, startsWithCashPaid: Bool = false,
         onRecorded: @escaping () -> Void) {
        self.store = store; self.showID = showID; self.listID = listID; self.listName = listName
        self.onRecorded = onRecorded
        _kind = State(initialValue: initialKind)
        _direction = State(initialValue: initialKind == .trade && startsWithCashPaid ? .paid : .none)
    }

    private var receivesCash: Bool { kind == .sale || (kind == .trade && direction == .received) }
    private var isPureTrade: Bool { kind == .trade && direction == .none }
    private var entry: ShowBudgetEntry? {
        guard let show = store.book.shows.first(where: { $0.id == showID }) else { return nil }
        let amountCents: Int64? = isPureTrade ? 0 : ShowBudgetMoney.parse(amount)
        let feeCents: Int64? = receivesCash
            ? (fees.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : ShowBudgetMoney.parse(fees)) : 0
        guard let cents = amountCents, let fee = feeCents else { return nil }
        let name = listName.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(250)) }
        let result = ShowBudgetEntry(id: draftID, kind: kind, paidCents: receivesCash || isPureTrade ? 0 : cents,
            grossReceivedCents: receivesCash ? cents : 0, feeCents: fee,
            reinvestmentPercent: show.reinvestmentPercent, splitBasis: .grossProceeds, recordedAt: recordedAt,
            listID: listID, listName: name?.isEmpty == true ? nil : name, note: note)
        do { try result.validate(); return result }
        catch { return nil }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 60, paused: !isVisible || scenePhase != .active)) { _ in form }
        .onAppear { isVisible = true }.onDisappear { isVisible = false }
        .navigationTitle("Record Cash").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }
                    .fixedSize().frame(minWidth: 60).accessibilityIdentifier("budget.keyboardDone")
            }
        }
        .interactiveDismissDisabled(saving)
        .onChange(of: kind) { _, _ in amount = ""; fees = ""; direction = .none; error = nil }
        .onChange(of: direction) { _, _ in amount = ""; fees = ""; error = nil }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Transaction", selection: $kind) {
                    ForEach(ShowBudgetEntryKind.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("budget.kind")
                if let show = store.book.shows.first(where: { $0.id == showID }) { LabeledContent("Show", value: show.name) }
                if let listName { LabeledContent("Linked list", value: listName) }
            }
            if !store.canRecord(showID: showID), let show = store.book.shows.first(where: { $0.id == showID }) {
                Section("Show schedule") {
                    Text(budgetScheduleMessage(show, store: store)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("budget.recordScheduleStatus")
                }
            }
            Section("Cash movement") {
                if kind == .trade {
                    Picker("Cash in this trade", selection: $direction) {
                        ForEach(BudgetTradeDirection.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("budget.tradeDirection")
                }
                if isPureTrade {
                    Text("A card-for-card trade does not change cash available or your personal allocation.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    TextField(receivesCash ? "Gross amount received" : "Total cash paid", text: $amount)
                        .keyboardType(.decimalPad).focused($focused, equals: .amount)
                        .accessibilityLabel(receivesCash ? "Gross amount received" : "Total cash paid")
                        .accessibilityIdentifier("budget.amount")
                }
                if receivesCash {
                    TextField("Fees, optional", text: $fees).keyboardType(.decimalPad)
                        .focused($focused, equals: .fees).accessibilityIdentifier("budget.fees")
                    Text("The split uses the gross amount. Fees are deducted from buying funds separately.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !isPureTrade {
                    Text("Enter the total cash you actually paid, including any purchase fees.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Note, optional", text: $note, axis: .vertical).lineLimit(2...4)
                    .focused($focused, equals: .note)
                    .onChange(of: note) { _, value in if value.count > 1_000 { note = String(value.prefix(1_000)) } }
            }
            if let entry, let allocation = try? entry.allocation() {
                Section("Budget change") {
                    if receivesCash {
                        LabeledContent("\(entry.reinvestmentPercent)% allocated for buying", value: budgetMoney(allocation.reinvestedCents))
                        LabeledContent("\(100 - entry.reinvestmentPercent)% saved for you", value: budgetMoney(allocation.savedCents))
                        LabeledContent("Fees", value: budgetMoney(entry.feeCents))
                    }
                    LabeledContent("Available buying funds change", value: signedBudgetMoney(allocation.availableDeltaCents))
                        .accessibilityIdentifier("budget.previewDelta")
                    if let show = store.book.shows.first(where: { $0.id == showID }), let totals = try? show.totals() {
                        let next = totals.availableCents.addingReportingOverflow(allocation.availableDeltaCents)
                        if !next.overflow {
                            LabeledContent("Available after recording", value: budgetMoney(next.partialValue))
                            if next.partialValue < 0 { Text("This transaction puts the show over budget.").foregroundStyle(.orange) }
                        }
                    }
                }
            } else if !amount.isEmpty || !fees.isEmpty {
                Section { Text("Enter valid cash amounts with at most two decimal places. Fees cannot exceed gross cash received.").font(.caption).foregroundStyle(.secondary) }
            }
            if let error { Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("budget.error") } }
            Section {
                Button("Record Transaction") { record() }
                    .disabled(entry == nil || saving || saved || !store.isLoaded || !store.canRecord(showID: showID))
                    .accessibilityIdentifier("budget.record")
            } footer: {
                Text("Confirm the actual cash paid or received to record this budget transaction.")
            }
        }
    }

    private func record() {
        guard !saving, !saved, let entry else { return }
        guard store.canRecord(showID: showID) else {
            error = "Cash can be recorded only on this show's scheduled dates. Your transaction has not been added."
            return
        }
        saving = true; error = nil
        defer { saving = false }
        do { try store.record(entry, showID: showID); saved = true; onRecorded() }
        catch { self.error = budgetError(error) }
    }
}

@MainActor private struct BudgetEntryDetail: View {
    let store: ShowBudgetStore
    let showID: UUID
    let entryID: UUID
    @State private var confirmingVoid = false
    @State private var error: String?
    private var entry: ShowBudgetEntry? { store.book.shows.first { $0.id == showID }?.entries.first { $0.id == entryID } }

    var body: some View {
        List {
            if let entry {
                Section {
                    LabeledContent("Type", value: entry.kind.title)
                    LabeledContent("Recorded", value: entry.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    if let listName = entry.listName { LabeledContent("List at recording", value: listName) }
                    if !entry.note.isEmpty { Text(entry.note) }
                }
                Section("Recorded cash") {
                    LabeledContent("Cash paid", value: budgetMoney(entry.paidCents))
                    LabeledContent("Gross cash received", value: budgetMoney(entry.grossReceivedCents))
                    LabeledContent("Fees", value: budgetMoney(entry.feeCents))
                    LabeledContent("Split basis", value: entry.splitBasis.title)
                    LabeledContent("Buying allocation", value: "\(entry.reinvestmentPercent)%")
                }
                if let voidedAt = entry.voidedAt {
                    Section {
                        Label("Voided", systemImage: "arrow.uturn.backward")
                        Text(voidedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        Text("This entry is kept in history and excluded from the budget totals.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Button("Void Entry", role: .destructive) { confirmingVoid = true }
                            .accessibilityIdentifier("budget.void")
                        Text("Void a mistake, then record the corrected transaction. The original entry stays in history.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("budget.error") } }
            } else { ContentUnavailableView("Entry unavailable", systemImage: "tray") }
        }
        .navigationTitle("Budget Transaction").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Void this budget entry?", isPresented: $confirmingVoid, titleVisibility: .visible) {
            Button("Void Entry", role: .destructive) {
                do { try store.void(entryID: entryID, showID: showID); error = nil }
                catch { self.error = budgetError(error) }
            }.accessibilityIdentifier("budget.voidConfirm")
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its effect on buying funds and personal savings will be reversed. The original record will be kept.") }
    }
}

@MainActor private struct BudgetLoadFailure: View {
    let store: ShowBudgetStore
    var body: some View {
        Section {
            ContentUnavailableView("Budget unavailable", systemImage: "externaldrive.badge.exclamationmark",
                                   description: Text(store.error ?? "The saved budget could not be opened. Your file has been kept."))
            Button("Retry Loading") { store.reload() }.accessibilityIdentifier("budget.retryLoad")
        }
    }
}

private func budgetMoney(_ cents: Int64) -> String { ShowBudgetMoney.decimal(cents).money }
private func signedBudgetMoney(_ cents: Int64) -> String { (cents > 0 ? "+" : "") + budgetMoney(cents) }
private func entryCashLabel(_ entry: ShowBudgetEntry) -> String {
    if entry.grossReceivedCents > 0 { return "+" + budgetMoney(entry.grossReceivedCents) }
    if entry.paidCents > 0 { return "−" + budgetMoney(entry.paidCents) }
    return budgetMoney(0)
}
private func budgetError(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "The show budget could not be saved. Your entries have been kept; retry."
}

private func budgetShowDateLabel(_ show: ShowBudgetEvent) -> String? {
    guard let start = show.startDate, let end = show.endDate else { return nil }
    let first = start.formatted(date: .abbreviated, time: .omitted)
    if Calendar.current.isDate(start, inSameDayAs: end) { return first }
    return first + " – " + end.formatted(date: .abbreviated, time: .omitted)
}

@MainActor private func budgetBalanceTitle(_ show: ShowBudgetEvent, store: ShowBudgetStore) -> String {
    switch show.scheduleStatus(on: store.currentDate, calendar: store.calendar) {
    case .manual, .active: return "Available to buy"
    case .scheduled: return "Planned buying funds"
    case .ended: return "Show balance"
    }
}

@MainActor private func budgetScheduleMessage(_ show: ShowBudgetEvent, store: ShowBudgetStore) -> String {
    switch show.scheduleStatus(on: store.currentDate, calendar: store.calendar) {
    case .scheduled: return "This show is scheduled for later. Cash recording opens on its show dates."
    case .ended: return "This show has ended. Its saved balance and transactions remain available for review."
    case .manual: return "This budget has no schedule and is available while selected."
    case .active: return "This show is active today."
    }
}
