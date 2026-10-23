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
    var customCashOffer: Decimal? = nil
    private var cashTotal: Decimal { customCashOffer ?? totals.cash }
    var body: some View {
        LabeledContent("Cards in batch", value: String(totals.quantity))
        LabeledContent("Known market subtotal", value: totals.market.money)
        LabeledContent("Calculated cash (\(CSVExportService.number(rates.cash))%)", value: totals.cash.money)
        if let customCashOffer {
            LabeledContent("Custom cash offer", value: customCashOffer.money).font(.headline)
            if customCashOffer > totals.cash {
                LabeledContent("Above calculated cash", value: (customCashOffer - totals.cash).money)
            } else if customCashOffer < totals.cash {
                LabeledContent("Below calculated cash", value: (totals.cash - customCashOffer).money)
            }
        }
        LabeledContent("Cash offer total", value: cashTotal.money).font(.headline)
        LabeledContent("Trade credit (\(CSVExportService.number(rates.trade))%)", value: totals.trade.money)
        LabeledContent("Maximum buy (\(CSVExportService.number(rates.maximum))%)", value: totals.maximum.money)
        Text("Cash and trade are alternative offers. Per-card overrides affect calculated estimates; a custom cash offer sets the total for the whole list.")
            .font(.caption).foregroundStyle(.secondary)
        if totals.unpricedQuantity > 0 {
            Text(customCashOffer == nil
                 ? "Partial estimate: \(totals.unpricedQuantity) unpriced copies are excluded from calculated offers until priced."
                 : "Calculated estimates exclude \(totals.unpricedQuantity) unpriced copies. Your custom cash offer covers the whole list.")
                .foregroundStyle(.orange)
        }
        LabeledContent(totals.unpricedQuantity == 0 ? "Potential gross cash resale spread" : "Known market subtotal minus cash offer",
                       value: (totals.market - cashTotal).money)
        Text("Uses known market value and the selected cash offer. Excludes fees, shipping, labor and unsold inventory; this is not net profit or a recorded purchase.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct SessionReviewHeader: View {
    let session: ScanSession
    let list: CardList
    @Environment(\.modelContext) private var context
    @State private var editRates = false
    @State private var resumed = false
    @State private var confirmResume = false
    @FocusState private var editingCustomCash: Bool
    @State private var customCashText = ""
    @State private var restoredCustomCash = false
    @State private var offerSaved = false
    @State private var error: String?
    private var hasCustomInput: Bool { !customCashText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var customAmount: Decimal? { CustomOfferAmount.parse(customCashText) }
    private var invalidCustomAmount: Bool { hasCustomInput && customAmount == nil }
    var body: some View {
        Text(list.name).font(.headline)
        Text("\(session.isActive ? "Active" : "Completed") • \(session.game ?? "")")
        Text(session.startedAt, format: .dateTime).font(.caption)
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom cash offer").font(.headline)
            HStack {
                Text("$")
                TextField("Use calculated cash when blank", text: $customCashText)
                    .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).focused($editingCustomCash)
                    .accessibilityLabel("Custom cash offer for the whole list")
            }
            if hasCustomInput { Button("Use Calculated Cash") { customCashText = "" } }
            if invalidCustomAmount {
                Text(BatchFailure.invalidOfferAmount.localizedDescription).font(.caption).foregroundStyle(.orange)
            } else {
                Text("Enter the total you want to offer if the seller asks for a different amount. Save Offer Estimate keeps this amount with the estimate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if editingCustomCash { Spacer(); Button("Done") { editingCustomCash = false } }
            }
        }
        OfferBreakdownView(totals: OfferCalculator.calculate(list.cards.map(\.offerLine), rates: session.rates), rates: session.rates,
                           customCashOffer: customAmount)
        Button("Session Offer Percentages") { editRates = true }
        Button("Save Offer Estimate") {
            do {
                try SessionService.saveOffer(session, list: list, context: context, customCashOffer: customAmount)
                editingCustomCash = false; offerSaved = true
            } catch { self.error = error.localizedDescription }
        }.disabled(invalidCustomAmount)
        if offerSaved { Text("Offer estimate saved.").font(.caption).foregroundStyle(.green) }
        NavigationLink("Saved Offer Estimates") { SavedOffersView(session: session) }
        if session.isActive {
            NavigationLink { ScannerView(session: session, list: list) } label: { Label("Continue Scanning", systemImage: "viewfinder") }
            FinishSessionButton(session: session)
        } else {
            Button("Continue Scanning", systemImage: "viewfinder") { confirmResume = true }
        }
        Text("Editing cards updates this review. Saved estimates retain their original rates, prices, quantities, overrides and custom cash amount.").font(.caption).foregroundStyle(.secondary)
            .onAppear { restoreCustomCash() }
            .onChange(of: customCashText) { _, _ in offerSaved = false }
            .onChange(of: session.rates) { _, _ in offerSaved = false }
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
    private func restoreCustomCash() {
        guard !restoredCustomCash else { return }
        restoredCustomCash = true
        do {
            if let amount = try session.savedOffers().last?.customCashOffer {
                customCashText = CSVExportService.number(amount)
            }
        } catch { self.error = error.localizedDescription }
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
                            OfferBreakdownView(totals: estimate.totals, rates: estimate.rates, customCashOffer: estimate.customCashOffer)
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
                        Text("\(estimate.totals.quantity) cards • \(estimate.selectedCashOffer.money) cash • \(estimate.totals.trade.money) trade").font(.caption)
                        if estimate.customCashOffer != nil { Text("Custom cash offer").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }.navigationTitle("Saved Estimates")
            .task { do { estimates = try session.savedOffers() } catch { self.error = error.localizedDescription } }
            .failureAlert($error)
    }
}
