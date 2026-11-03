import SwiftUI
import SwiftData
import UIKit

/// Show activity uses local working stock; the imported website list remains a source snapshot.
@MainActor struct ShowHomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: ShowBudgetStore
    @State private var showingTransaction = false
    @State private var seedError: String?
    @State private var isVisible = false

    init(store: ShowBudgetStore = .shared) { _store = State(initialValue: store) }

    private var availableQuantity: Int { store.inventory.reduce(0) { $0 + max(0, $1.quantity) } }

    var body: some View {
        TimelineView(.animation(minimumInterval: 60, paused: !isVisible || scenePhase != .active)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ShowBudgetSummaryCard(store: store)
                    VStack(spacing: 12) {
                        NavigationLink { ShowWorkingInventoryView(store: store) } label: {
                            ShowHomeRouteCard(title: "Inventory", subtitle: "\(availableQuantity.formatted()) cards in local stock",
                                              symbol: "shippingbox.fill", color: .indigo)
                        }.buttonStyle(.plain).accessibilityIdentifier("show.inventory")
                        Button { showingTransaction = true } label: {
                            ShowHomeRouteCard(title: "Record Transaction", subtitle: "Sell, trade, or buy cards",
                                              symbol: "arrow.left.arrow.right", color: .teal)
                        }.buttonStyle(.plain).disabled(!store.isLoaded || store.eligibleActiveShow == nil)
                            .accessibilityIdentifier("show.recordTransaction")
                        NavigationLink { ShowTransactionHistoryView(store: store) } label: {
                            ShowHomeRouteCard(title: "Transaction History", subtitle: "Receipts, card movements, and Undo",
                                              symbol: "clock.arrow.circlepath", color: .orange)
                        }.buttonStyle(.plain).accessibilityIdentifier("show.history")
                    }
                    if store.isLoaded && store.eligibleActiveShow == nil {
                        Label(store.activeShow == nil
                              ? "Set up or choose a show budget to record transactions."
                              : "Recording opens on your show's dates. Open Show Budget to review the schedule.",
                              systemImage: "calendar")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Label("Local stock and saved receipts work offline.", systemImage: "iphone")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("show.offline")
                    if let seedError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(seedError).font(.footnote).foregroundStyle(.orange)
                            Button("Retry Preparing Inventory") { seedInventory() }
                        }.accessibilityIdentifier("show.inventoryError")
                    }
                }.padding(16)
            }.background(Color(uiColor: .systemGroupedBackground))
        }
        .navigationTitle("Show")
        .sheet(isPresented: $showingTransaction) { ShowTransactionForm(store: store, initialKind: .sale) }
        .onAppear { isVisible = true; seedInventory() }
        .onDisappear { isVisible = false }
    }

    private func seedInventory() {
        do { try ShowInventoryBridge.seedFromImportedList(context: context, store: store); seedError = nil }
        catch { seedError = showViewError(error) }
    }
}

private struct ShowHomeRouteCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(color)
                .frame(width: 46, height: 46).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

@MainActor struct ShowWorkingInventoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var store: ShowBudgetStore
    @State private var search = ""
    @State private var seedError: String?
    @State private var showingTransaction = false
    @State private var showingPriceTags = false

    init(store: ShowBudgetStore = .shared) { _store = State(initialValue: store) }

    private var available: [ShowInventoryItem] {
        store.inventory.filter { $0.quantity > 0 }.sorted {
            $0.card.name.localizedStandardCompare($1.card.name) == .orderedAscending
        }
    }

    private var filtered: [ShowInventoryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return available }
        return available.filter { item in
            [item.card.name, item.card.set, item.card.number, item.card.identity.printing,
             item.card.identity.condition, item.card.identity.language].joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if !store.isLoaded {
                Section {
                    Text(store.error ?? "Your saved show data could not be opened.").foregroundStyle(.orange)
                    Button("Retry Loading") { store.reload(); seedInventory() }
                        .accessibilityIdentifier("showInventory.retryLoad")
                }
            }
            if let seedError {
                Section {
                    Text(seedError).font(.footnote).foregroundStyle(.orange)
                    Button("Retry Preparing Inventory") { seedInventory() }
                }.accessibilityIdentifier("showInventory.seedError")
            }
            if store.isLoaded && available.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No cards in local stock", systemImage: "shippingbox")
                    } description: {
                        Text(store.inventorySourceLocationID == nil
                             ? "Import your TCGTracking Card Show snapshot to start, or record a purchase."
                             : "Your available stock is empty. Record a purchase or a trade to add cards. Previous cards stay in transaction history.")
                    }
                }
            } else if store.isLoaded && filtered.isEmpty {
                Section { ContentUnavailableView.search(text: search) }
            } else if store.isLoaded {
                Section("Available cards") {
                    ForEach(filtered) { item in
                        NavigationLink { ShowWorkingInventoryDetailView(itemID: item.id, store: store) } label: {
                            ShowWorkingInventoryRow(item: item)
                        }.accessibilityIdentifier("showInventory.item." + item.id.uuidString)
                    }
                }
            }
        }
        .navigationTitle("Show Inventory").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Name, set, or card number")
        .scrollDismissesKeyboard(.interactively)
        .onSubmit(of: .search) { endSearchEditing() }
        .safeAreaInset(edge: .top, spacing: 0) { inventorySummary }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TimelineView(.animation(minimumInterval: 60, paused: !visible || scenePhase != .active)) { _ in
                transactionAction
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Print Price Tags", systemImage: "printer") { showingPriceTags = true }
                        .disabled(!store.isLoaded || available.isEmpty)
                        .accessibilityIdentifier("showInventory.priceTags")
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("Inventory options").accessibilityIdentifier("showInventory.options")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { CardShowInventoryView() } label: { Text("Source") }
                    .accessibilityLabel("TCGTracking Source Snapshot")
                    .accessibilityIdentifier("showInventory.importSnapshot")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { endSearchEditing() }.fixedSize().frame(minWidth: 64, minHeight: 44)
                    .accessibilityIdentifier("showInventory.keyboardDone")
            }
        }
        .sheet(isPresented: $showingTransaction) { ShowTransactionForm(store: store) }
        .sheet(isPresented: $showingPriceTags, onDismiss: { LetraTagPrinter.shared.stop() }) {
            NavigationStack {
                PriceTagQueueView(inventory: store.inventory)
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showingPriceTags = false }.disabled(LetraTagPrinter.shared.isPrinting)
                            .accessibilityIdentifier("priceTags.close")
                    } }
            }.interactiveDismissDisabled(LetraTagPrinter.shared.isPrinting)
        }
        .onAppear { visible = true; seedInventory() }
        .onDisappear { visible = false }
    }

    private var inventorySummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(available.reduce(0) { $0 + $1.quantity }.formatted()) cards available")
                .font(.headline).monospacedDigit().accessibilityIdentifier("showInventory.quantity")
            Label("Local stock · Works offline", systemImage: "iphone")
                .font(.caption).foregroundStyle(.indigo).accessibilityIdentifier("showInventory.localStock")
                .accessibilityHint("Sales remove cards from this stock. Purchases and trades add the cards you receive. Artwork and research may need internet.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var transactionAction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard store.isLoaded, store.eligibleActiveShow != nil else { return }
                endSearchEditing()
                showingTransaction = true
            } label: {
                Label("Record Transaction", systemImage: "arrow.left.arrow.right")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.isLoaded || store.eligibleActiveShow == nil)
            .accessibilityIdentifier("showInventory.recordTransaction")
            if !store.isLoaded {
                Text("Load your show data to record transactions.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if store.eligibleActiveShow == nil {
                Text(store.activeShow == nil
                     ? "Choose an active show in Show Budget to record."
                     : "Recording opens on your show's dates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func endSearchEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func seedInventory() {
        do { try ShowInventoryBridge.seedFromImportedList(context: context, store: store); seedError = nil }
        catch { seedError = showViewError(error) }
    }
}

private struct ShowWorkingInventoryRow: View {
    let item: ShowInventoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ShowInventoryArtwork(card: item.card, width: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.card.name).font(.subheadline.weight(.semibold))
                Text(showCardSetLabel(item.card)).font(.caption).foregroundStyle(.secondary)
                Text([item.card.identity.printing, item.card.identity.condition, item.card.identity.language].joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Text(item.card.marketPrice?.money ?? "Market unavailable").font(.caption.weight(.medium)).monospacedDigit()
                    Spacer(minLength: 8)
                    Text("Qty \(item.quantity.formatted())").font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.indigo)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 5)
    }
}

@MainActor private struct ShowWorkingInventoryDetailView: View {
    let itemID: UUID
    let store: ShowBudgetStore
    private var item: ShowInventoryItem? { store.inventory.first { $0.id == itemID } }

    var body: some View {
        List {
            if let item {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        ShowInventoryArtwork(card: item.card, width: 76)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.card.name).font(.title3.bold())
                            Text(showCardSetLabel(item.card)).font(.subheadline).foregroundStyle(.secondary)
                            Text(item.card.marketPrice?.money ?? "Market unavailable").font(.headline).monospacedDigit()
                            Text("Last saved market value · USD per card").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }
                Section("Local stock") {
                    LabeledContent("Available quantity", value: item.quantity.formatted())
                    LabeledContent("Game", value: item.card.identity.game)
                    LabeledContent("Printing", value: item.card.identity.printing)
                    LabeledContent("Condition", value: item.card.identity.condition)
                    LabeledContent("Language", value: item.card.identity.language)
                    Text("This quantity changes when you record or undo a transaction.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink { CardResearchView(card: item.card) } label: {
                        Label("Market & Graded Research", systemImage: "magnifyingglass")
                    }.accessibilityIdentifier("showInventory.cardResearch")
                    if let transactionID = item.acquiredByTransactionID {
                        NavigationLink { ShowTransactionDetailView(transactionID: transactionID, store: store) } label: {
                            Label("Acquisition Receipt", systemImage: "receipt")
                        }
                    }
                }
            } else { ContentUnavailableView("Card unavailable", systemImage: "shippingbox") }
        }.navigationTitle("Card Details").navigationBarTitleDisplayMode(.inline)
    }
}

private struct ShowInventoryArtwork: View {
    let card: CardCandidate
    let width: CGFloat
    var body: some View {
        AsyncImage(url: card.imageURL) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                    .overlay { Image(systemName: "rectangle.portrait").foregroundStyle(.secondary) }
            }
        }.frame(width: width, height: width * 1.4).clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
    }
}

@MainActor struct ShowTransactionHistoryView: View {
    @State private var store: ShowBudgetStore
    @State private var search = ""

    init(store: ShowBudgetStore = .shared) { _store = State(initialValue: store) }

    private var receipts: [ShowHistoryReceipt] {
        let transactions = store.transactions.map(ShowHistoryReceipt.transaction)
        let cash = store.book.shows.flatMap { show in
            show.entries.filter { $0.transactionID == nil }.map { ShowHistoryReceipt.cash(show: show, entry: $0) }
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (transactions + cash).filter { query.isEmpty || $0.searchText.localizedCaseInsensitiveContains(query) }
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    var body: some View {
        List {
            if !store.isLoaded {
                Section {
                    Text(store.error ?? "Your saved transactions could not be opened.").foregroundStyle(.orange)
                    Button("Retry Loading") { store.reload() }.accessibilityIdentifier("showHistory.retryLoad")
                }
            } else if receipts.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("No transactions yet", systemImage: "receipt",
                                           description: Text("Recorded transactions and cash receipts stay here, including after a show is deleted."))
                } else { ContentUnavailableView.search(text: search) }
            } else {
                Section {
                    ForEach(receipts) { receipt in
                        NavigationLink {
                            switch receipt {
                            case .transaction(let transaction):
                                ShowTransactionDetailView(transactionID: transaction.id, store: store)
                            case .cash(let show, let entry):
                                BudgetEntryDetail(store: store, showID: show.id, entryID: entry.id)
                            }
                        } label: { historyRow(receipt) }
                            .accessibilityIdentifier("showHistory.receipt." + receipt.id)
                    }
                } footer: {
                    Text("Receipts keep their original card and cash details. Undo a card transaction from its receipt. Cash-only entries retain their original Void action.")
                }
            }
        }
        .navigationTitle("Transaction History").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Show or card name")
    }

    private func historyRow(_ receipt: ShowHistoryReceipt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(receipt.title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(receipt.cashLabel).font(.subheadline.weight(.medium)).monospacedDigit()
                    .strikethrough(receipt.isReversed)
            }
            Text(receipt.showName).font(.caption).foregroundStyle(.secondary)
            if !receipt.cardSummary.isEmpty {
                Text(receipt.cardSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(receipt.recordedAt.formatted(date: .abbreviated, time: .shortened))
                if let status = receipt.status { Text(status).fontWeight(.medium) }
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

private enum ShowHistoryReceipt: Identifiable {
    case transaction(ShowTransactionReceipt)
    case cash(show: ShowBudgetEvent, entry: ShowBudgetEntry)

    var id: String {
        switch self { case .transaction(let value): return value.id.uuidString; case .cash(_, let entry): return "cash." + entry.id.uuidString }
    }
    var title: String {
        switch self { case .transaction(let value): return value.kind.title; case .cash(_, let entry): return entry.kind.title + " · Cash only" }
    }
    var showName: String {
        switch self { case .transaction(let value): return value.showName; case .cash(let show, _): return show.name }
    }
    var recordedAt: Date {
        switch self { case .transaction(let value): return value.recordedAt; case .cash(_, let entry): return entry.recordedAt }
    }
    var isReversed: Bool {
        switch self { case .transaction(let value): return value.reversedAt != nil; case .cash(_, let entry): return entry.voidedAt != nil }
    }
    var status: String? {
        guard isReversed else { return nil }
        switch self { case .transaction: return "Undone"; case .cash: return "Voided" }
    }
    var cashLabel: String {
        let received: Int64
        let paid: Int64
        switch self {
        case .transaction(let value): received = value.receivedCents; paid = value.paidCents
        case .cash(_, let entry): received = entry.grossReceivedCents; paid = entry.paidCents
        }
        if received > 0 { return "+" + ShowBudgetMoney.decimal(received).money }
        if paid > 0 { return "−" + ShowBudgetMoney.decimal(paid).money }
        return "No cash"
    }
    var cardSummary: String {
        switch self {
        case .transaction(let value):
            let incoming = value.incoming.reduce(0) { $0 + $1.quantity }
            let outgoing = value.outgoing.reduce(0) { $0 + $1.quantity }
            return [incoming > 0 ? "\(incoming.formatted()) in" : nil,
                    outgoing > 0 ? "\(outgoing.formatted()) out" : nil].compactMap { $0 }.joined(separator: " · ")
        case .cash(_, let entry): return entry.listName ?? entry.note
        }
    }
    var searchText: String {
        switch self {
        case .transaction(let value):
            return ([value.showName, value.kind.title, value.incomingListName ?? ""] +
                    (value.incoming + value.outgoing).map { $0.card.name }).joined(separator: " ")
        case .cash(let show, let entry): return [show.name, entry.kind.title, entry.listName ?? "", entry.note].joined(separator: " ")
        }
    }
}

private func showCardSetLabel(_ card: CardCandidate) -> String {
    card.number.isEmpty ? card.set : card.set + " · #" + card.number
}

private func showViewError(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "Local show inventory could not be prepared. Your saved stock is kept; retry."
}
