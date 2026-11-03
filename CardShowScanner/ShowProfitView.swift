import SwiftUI

/// Cash budgets and realized profit are separate views of the same immutable
/// receipts. Missing costs are excluded from the known subtotal, never zeroed.
@MainActor struct ShowProfitView: View {
    let store: ShowBudgetStore
    @State private var showID: UUID?

    init(store: ShowBudgetStore = .shared) { self.store = store }

    private var receipts: [ShowTransactionReceipt] {
        store.transactions.filter { $0.reversedAt == nil && $0.kind != .purchase && (showID == nil || $0.showID == showID) }
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    var body: some View {
        let report = try? store.profitSummary(showID: showID)
        List {
            Section {
                Picker("Report", selection: $showID) {
                    Text("All shows").tag(Optional<UUID>.none)
                    ForEach(store.book.shows.reversed()) { show in
                        Text(show.name + (show.deletedAt == nil ? "" : " · Deleted show"))
                            .tag(Optional(show.id))
                    }
                }.accessibilityIdentifier("profit.scope")
            }
            if !store.isLoaded {
                Section {
                    Text(store.error ?? "Your saved show data must be available to calculate profit.")
                        .foregroundStyle(.orange)
                    Button("Retry Loading") { store.reload() }
                }
            } else if let report {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(report.isComplete ? "Recorded profit" : "Known profit subtotal")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(profitMoney(report.knownProfitCents)).font(.largeTitle.bold()).monospacedDigit()
                            .foregroundStyle(report.knownProfitCents < 0 ? Color.red : Color.primary)
                            .accessibilityIdentifier("profit.knownProfit")
                        if !report.isComplete {
                            Label("Profit incomplete", systemImage: "exclamationmark.circle")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                        }
                        Text("\(report.unknownCostQuantity) copies missing cost · \(report.uncostedSaleCount) sales and \(report.uncostedTradeCount) trades without card costs")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("profit.unknown")
                    }.padding(.vertical, 5)
                } footer: {
                    Text("Missing costs are excluded from this profit subtotal. They are not treated as free cards.")
                }
                Section("Sales") {
                    LabeledContent("Gross sales", value: profitMoney(report.salesCents)).accessibilityIdentifier("profit.sales")
                    LabeledContent("Selling fees", value: profitMoney(report.sellingFeesCents)).accessibilityIdentifier("profit.fees")
                    LabeledContent("Known cost of sold cards", value: profitMoney(report.soldCostCents)).accessibilityIdentifier("profit.cost")
                    LabeledContent("Known sales profit", value: profitMoney(report.knownProfitCents - report.tradeCashProfitCents))
                }
                Section("Trades") {
                    LabeledContent("Known trade cash profit", value: profitMoney(report.tradeCashProfitCents))
                        .accessibilityIdentifier("profit.tradeProfit")
                    Text("Trades carry the original acquisition cost into incoming cards, adjusted for cash exchanged. Only cash received beyond that cost is profit at the trade.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("Profit = sale proceeds − selling fees − the cost of the copies sold.")
                    Text("Buying funds still use your gross-sale reinvestment split, less fees. Acquisition cost is paid when you buy, and is not deducted from cash again when you sell.")
                }.font(.footnote).foregroundStyle(.secondary)
                if !receipts.isEmpty {
                    Section("Transactions") {
                        ForEach(receipts) { receipt in
                            NavigationLink {
                                ShowTransactionDetailView(transactionID: receipt.id, store: store)
                            } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(receipt.kind.title).font(.subheadline.weight(.semibold))
                                        Text(receipt.showName).font(.caption).foregroundStyle(.secondary)
                                        Text(receipt.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(receipt.profitCents.map(profitMoney) ?? "Cost unknown")
                                        .font(.subheadline).monospacedDigit()
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
            } else {
                Section {
                    Text("Profit could not be calculated from the saved records. Your saved data has been kept.")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Sales & Profit").navigationBarTitleDisplayMode(.inline)
    }
}

private func profitMoney(_ cents: Int64) -> String { ShowBudgetMoney.decimal(cents).money }
