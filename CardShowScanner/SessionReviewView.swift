import SwiftUI
import SwiftData

struct SessionReviewView: View {
    let session: ScanSession
    let list: CardList
    var body: some View { CardListView(list: list, session: session) }
}

struct OfferBreakdownView: View {
    let totals: OfferTotals
    let rates: OfferRates
    var body: some View {
        LabeledContent("Cards in batch", value: String(totals.quantity))
        LabeledContent("Known market subtotal", value: totals.market.money)
        LabeledContent("Cash offer (\(CSVExportService.number(rates.cash))%)", value: totals.cash.money)
        LabeledContent("Trade credit (\(CSVExportService.number(rates.trade))%)", value: totals.trade.money)
        LabeledContent("Maximum buy (\(CSVExportService.number(rates.maximum))%)", value: totals.maximum.money)
        Text("Cash and trade are alternative offers. Per-card overrides replace these rates where entered.").font(.caption).foregroundStyle(.secondary)
        if totals.unpricedQuantity > 0 {
            Text("Partial estimate: \(totals.unpricedQuantity) unpriced copies are excluded from every offer until priced.").foregroundStyle(.orange)
        }
        LabeledContent("Potential gross cash resale spread", value: totals.grossCashSpread.money)
        Text("Assumes resale at known market value and the suggested cash cost. Excludes fees, shipping, labor and unsold inventory; this is not net profit or a recorded purchase.").font(.caption).foregroundStyle(.secondary)
    }
}

struct SessionReviewHeader: View {
    let session: ScanSession
    let list: CardList
    @Environment(\.modelContext) private var context
    @State private var editRates = false
    @State private var resumed = false
    @State private var confirmResume = false
    @State private var error: String?
    var body: some View {
        Text(list.name).font(.headline)
        Text("\(session.isActive ? "Active" : "Completed") • \(session.game ?? "")")
        Text(session.startedAt, format: .dateTime).font(.caption)
        OfferBreakdownView(totals: OfferCalculator.calculate(list.cards.map(\.offerLine), rates: session.rates), rates: session.rates)
        Button("Session Offer Percentages") { editRates = true }
        Button("Save Offer Estimate") {
            do { try SessionService.saveOffer(session, list: list, context: context) }
            catch { self.error = error.localizedDescription }
        }
        NavigationLink("Saved Offer Estimates") { SavedOffersView(session: session) }
        if session.isActive {
            NavigationLink { ScannerView(session: session, list: list) } label: { Label("Continue Scanning", systemImage: "viewfinder") }
            FinishSessionButton(session: session)
        } else {
            Button("Continue Scanning", systemImage: "viewfinder") { confirmResume = true }
        }
        Text("Editing cards updates this review. Saved estimates retain their original rates, prices, quantities and overrides.").font(.caption).foregroundStyle(.secondary)
            .confirmationDialog("Continue this list?", isPresented: $confirmResume) {
                Button("Continue Scanning") {
                    do { try SessionService.resume(session, context: context, finishingOtherSession: true); resumed = true }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("New cards append to this list. Any other active session will be finished and kept.") }
            .navigationDestination(isPresented: $resumed) { ScannerView(session: session, list: list) }
            .sheet(isPresented: $editRates) { SessionRatesView(session: session) }
            .failureAlert($error)
    }
}

struct FinishSessionButton: View {
    let session: ScanSession
    var onFinish: () -> Void = {}
    @Environment(\.modelContext) private var context
    @State private var confirm = false
    @State private var error: String?
    var body: some View {
        Button("Finish Session", systemImage: "checkmark.circle") { confirm = true }
            .confirmationDialog("Finish this session?", isPresented: $confirm) {
                Button("Finish & Keep List") {
                    do { try SessionService.finish(session, context: context); onFinish() }
                    catch { self.error = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Its cards and saved offers remain available. Start a new session for the next batch.") }
            .failureAlert($error)
    }
}

struct SessionRatesView: View {
    let session: ScanSession
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var cash: String
    @State private var trade: String
    @State private var maximum: String
    @State private var error: String?
    init(session: ScanSession) {
        self.session = session
        _cash = State(initialValue: CSVExportService.number(session.rates.cash))
        _trade = State(initialValue: CSVExportService.number(session.rates.trade))
        _maximum = State(initialValue: CSVExportService.number(session.rates.maximum))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Percentages • this session only") {
                    TextField("Cash %", text: $cash).keyboardType(.decimalPad)
                    TextField("Trade %", text: $trade).keyboardType(.decimalPad)
                    TextField("Maximum buy %", text: $maximum).keyboardType(.decimalPad)
                    Text("Global defaults and previously saved estimates will not change.").font(.caption)
                }
            }.navigationTitle("Session Pricing")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
                }.failureAlert($error)
        }
    }
    private func save() {
        guard let cash = MoneyInput.parse(cash), let trade = MoneyInput.parse(trade), let maximum = MoneyInput.parse(maximum) else {
            error = "Enter numeric percentages from 0 to 100."; return
        }
        let rates = OfferRates(cash: cash, trade: trade, maximum: maximum)
        guard rates.isValid else { error = BatchFailure.invalidRates.localizedDescription; return }
        session.setRates(rates)
        do { try CardListService.save(context); dismiss() } catch { self.error = error.localizedDescription }
    }
}

struct SavedOffersView: View {
    let session: ScanSession
    @State private var estimates: [OfferSnapshot] = []
    @State private var error: String?
    var body: some View {
        List {
            if estimates.isEmpty { Text("No saved offer estimates.") }
            ForEach(estimates.reversed()) { estimate in
                NavigationLink {
                    List {
                        Section("Saved \(estimate.savedAt.formatted())") {
                            OfferBreakdownView(totals: estimate.totals, rates: estimate.rates)
                        }
                        Section("Original valuation inputs") {
                            ForEach(Array(estimate.lines.enumerated()), id: \.offset) { _, line in
                                VStack(alignment: .leading) {
                                    Text(line.name).font(.headline)
                                    Text("\(line.printing) • \(line.condition) • \(line.language)").font(.caption)
                                    Text("Qty \(line.quantity) • \(line.price?.money ?? "Unpriced") per copy")
                                    Text("Overrides/copy: cash \(line.cashOverride?.money ?? "rate"), trade \(line.tradeOverride?.money ?? "rate"), max \(line.maximumOverride?.money ?? "rate")").font(.caption)
                                }
                            }
                        }
                    }.navigationTitle("Saved Estimate")
                } label: {
                    VStack(alignment: .leading) {
                        Text(estimate.savedAt, format: .dateTime)
                        Text("\(estimate.totals.quantity) cards • \(estimate.totals.cash.money) cash • \(estimate.totals.trade.money) trade").font(.caption)
                    }
                }
            }
        }.navigationTitle("Saved Estimates")
            .task { do { estimates = try session.savedOffers() } catch { self.error = error.localizedDescription } }
            .failureAlert($error)
    }
}
