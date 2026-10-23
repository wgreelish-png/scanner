import SwiftUI
import SwiftData

struct SessionReviewView: View {
    let session: ScanSession
    let list: CardList
    var body: some View { CardListView(list: list, session: session) }
}

private struct OfferMetricCard: View {
    let title: String
    let amount: Decimal
    let caption: String
    var accent: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(amount.money).font(.title2.bold()).monospacedDigit().foregroundStyle(accent)
                .fixedSize(horizontal: false, vertical: true)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct OfferBreakdownView: View {
    let totals: OfferTotals
    let rates: OfferRates
    var customCashOffer: Decimal? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var cashTotal: Decimal { customCashOffer ?? totals.cash }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Collector's Cards").font(.headline)
            OfferMetricCard(title: "Market Value", amount: totals.market,
                            caption: "\(totals.quantity) cards • known market value")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 12) {
                OfferMetricCard(title: "Trade Credit", amount: totals.trade,
                                caption: "\(CSVExportService.number(rates.trade))% base rate", accent: .blue)
                OfferMetricCard(title: "Cash Offer", amount: cashTotal,
                                caption: customCashOffer == nil ? "\(CSVExportService.number(rates.cash))% base rate" : "Custom whole-list amount", accent: .green)
            }
            if totals.unpricedQuantity > 0 {
                Label("Partial estimate: \(totals.unpricedQuantity) unpriced copies are excluded from market-based values.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                if customCashOffer != nil { Text("The custom cash offer covers the whole list.").font(.caption).foregroundStyle(.secondary) }
            }
            DisclosureGroup("Offer details") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Calculated cash", value: totals.cash.money)
                    if let customCashOffer {
                        LabeledContent("Custom cash offer", value: customCashOffer.money)
                        LabeledContent(customCashOffer >= totals.cash ? "Above calculated cash" : "Below calculated cash",
                                       value: abs(customCashOffer - totals.cash).money)
                    }
                    LabeledContent("Maximum buy (\(CSVExportService.number(rates.maximum))%)", value: totals.maximum.money)
                    LabeledContent("Market minus cash offer", value: (totals.market - cashTotal).money)
                    Text("Base rates and per-card overrides determine calculated offers. Cash and trade are alternatives; a custom cash offer applies to a cash-only buy.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Market minus cash offer excludes fees, shipping, labor and unsold inventory. It is not net profit or a recorded purchase.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }.font(.subheadline)
        }
    }
}

private struct TradeTransactionSummary: View {
    let transaction: TradeTransactionResult
    private var title: String {
        switch transaction.outcome {
        case .customerPays: return "Customer Pays You"
        case .payCustomer, .cashOffer: return "You Pay Customer"
        case .evenTrade: return "Even Trade"
        case .unusedCredit: return "Unused Trade Credit"
        }
    }
    private var accent: Color {
        switch transaction.outcome {
        case .customerPays: return .blue
        case .payCustomer, .cashOffer: return .green
        case .evenTrade: return .teal
        case .unusedCredit: return .orange
        }
    }
    private var symbol: String {
        switch transaction.outcome {
        case .customerPays: return "arrow.down.left.circle.fill"
        case .payCustomer, .cashOffer: return "arrow.up.right.circle.fill"
        case .evenTrade: return "equal.circle.fill"
        case .unusedCredit: return "creditcard.fill"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(transaction.mode.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(accent)
            Text(transaction.finalAmount.money).font(.largeTitle.bold()).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true).foregroundStyle(accent)
            if transaction.mode != .cashOnly {
                if let price = transaction.myCardPrice { LabeledContent("Your Card", value: price.money) }
                LabeledContent("Covered by Trade", value: transaction.tradeApplied.money)
            }
            if transaction.isPartial { Text("Partial estimate • some scanned cards are unpriced").font(.caption).foregroundStyle(.orange) }
            if transaction.mode == .tradeCreditOnly {
                Text("Unused credit is not paid out or stored for future use.").font(.caption).foregroundStyle(.secondary)
            } else if transaction.outcome == .evenTrade {
                Text("No cash changes hands.").font(.caption).foregroundStyle(.secondary)
            }
            if transaction.mode != .cashOnly {
                DisclosureGroup("Transaction math") {
                    VStack(spacing: 10) {
                        LabeledContent("Trade Applied", value: transaction.tradeApplied.money)
                        LabeledContent("Remaining Trade Credit", value: transaction.remainingTradeCredit.money)
                        LabeledContent("Remaining Market Value", value: transaction.remainingMarketValue.money)
                        LabeledContent("Cash Payout", value: transaction.cashPayout.money)
                        LabeledContent("Customer Balance", value: transaction.customerPays.money)
                        Text("Unused value is allocated proportionally across this list, using its calculated trade and cash offers. A custom cash-only amount does not change the trade payout.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                }.font(.subheadline)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.2), lineWidth: 1) }
            .accessibilityElement(children: .contain)
    }
}

struct SessionReviewHeader: View {
    let session: ScanSession
    let list: CardList
    @Environment(\.modelContext) private var context
    @State private var editRates = false
    @State private var resumed = false
    @State private var confirmResume = false
    private enum MoneyField: Hashable { case customCash, myCard }
    @FocusState private var editingMoney: MoneyField?
    @State private var customCashText = ""
    @State private var myCardPriceText = ""
    @State private var transactionMode = TradeTransactionMode.cashOnly
    @State private var restoredInputs = false
    @State private var offerSaved = false
    @State private var error: String?
    private var hasCustomInput: Bool { !customCashText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasMyCardInput: Bool { !myCardPriceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var customAmount: Decimal? { CustomOfferAmount.parse(customCashText) }
    private var myCardPrice: Decimal? { CustomOfferAmount.parse(myCardPriceText) }
    private var invalidCustomAmount: Bool { hasCustomInput && customAmount == nil }
    private var invalidMyCardPrice: Bool { hasMyCardInput && myCardPrice == nil }
    private var totals: OfferTotals { OfferCalculator.calculate(list.cards.map(\.offerLine), rates: session.rates) }
    private var transactionInput: TradeTransactionInput {
        TradeTransactionInput(mode: transactionMode, myCardPrice: transactionMode == .cashOnly ? nil : myCardPrice)
    }
    private var transaction: TradeTransactionResult? {
        guard !invalidMyCardPrice, !invalidCustomAmount else { return nil }
        return try? TradeTransactionCalculator.calculate(totals: totals, input: transactionInput, customCashOffer: customAmount)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text(list.name).font(.headline)
                Text("\(session.isActive ? "Active" : "Completed") • \(session.game ?? "")").font(.caption).foregroundStyle(.secondary)
                Text(session.startedAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
            }
            transactionControls
            if let transaction { TradeTransactionSummary(transaction: transaction) }
            else {
                Text(invalidMyCardPrice || invalidCustomAmount
                     ? "Enter a valid amount to calculate the transaction."
                     : "Enter My Card Price to calculate the trade, or choose Cash Only.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if transactionMode != .cashOnly && totals.trade == 0 && totals.market > 0 {
                Text("No trade credit is available. Choose Cash Only to make a cash offer for these cards.")
                    .font(.caption).foregroundStyle(.orange)
            }
            OfferBreakdownView(totals: totals, rates: session.rates, customCashOffer: customAmount)
            cashNegotiationControls
            offerActions
        }.padding(.vertical, 8)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if editingMoney != nil { Spacer(); Button("Done") { editingMoney = nil } }
                }
            }
            .onAppear { restoreOfferInputs() }
            .onChange(of: customCashText) { _, _ in offerSaved = false }
            .onChange(of: myCardPriceText) { _, _ in
                offerSaved = false
                if hasMyCardInput && transactionMode == .cashOnly { transactionMode = .tradeAndCash }
                else if !hasMyCardInput && transactionMode == .tradeAndCash { transactionMode = .cashOnly }
            }
            .onChange(of: transactionMode) { _, mode in
                offerSaved = false
                if mode == .cashOnly { myCardPriceText = "" }
            }
            .onChange(of: totals) { _, _ in offerSaved = false }
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
    private var transactionControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Transaction", selection: $transactionMode) {
                ForEach(TradeTransactionMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.menu)
            VStack(alignment: .leading, spacing: 8) {
                Text("My Card Price").font(.headline)
                HStack {
                    Text("$").foregroundStyle(.secondary)
                    TextField(transactionMode == .tradeCreditOnly ? "Optional card price" : "Leave blank for cash only", text: $myCardPriceText)
                        .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        .focused($editingMoney, equals: .myCard).accessibilityLabel("My Card Price")
                }
                if invalidMyCardPrice {
                    Text("Enter a price from $0 to $999,999,999.99 with at most two decimal places.").font(.caption).foregroundStyle(.orange)
                } else {
                    Text(transactionMode == .tradeCreditOnly
                         ? "Leave blank to show all unused credit. Credit is not paid out or stored for future use."
                         : "Enter your selling price to apply trade credit. Leave blank for a cash-only buy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }
    private var cashNegotiationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom cash offer").font(.subheadline.weight(.semibold))
            HStack {
                Text("$").foregroundStyle(.secondary)
                TextField("Use calculated cash when blank", text: $customCashText)
                    .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .focused($editingMoney, equals: .customCash).accessibilityLabel("Custom cash offer for the whole list")
            }
            if hasCustomInput { Button("Use Calculated Cash") { customCashText = "" }.font(.caption) }
            if invalidCustomAmount {
                Text(BatchFailure.invalidOfferAmount.localizedDescription).font(.caption).foregroundStyle(.orange)
            } else {
                Text("Negotiated total for Cash Only. Trade + Cash uses the calculated cash value of the remaining cards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }
    private var offerActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Save Offer Estimate", systemImage: "square.and.arrow.down") {
                do {
                    try SessionService.saveOffer(session, list: list, context: context, customCashOffer: customAmount, transactionInput: transactionInput)
                    editingMoney = nil; offerSaved = true
                } catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent).disabled(transaction == nil)
            if offerSaved { Label("Offer estimate saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            Button("Session Offer Percentages") { editRates = true }
            NavigationLink("Saved Offer Estimates") { SavedOffersView(session: session) }
            if session.isActive {
                NavigationLink { ScannerView(session: session, list: list) } label: { Label("Continue Scanning", systemImage: "viewfinder") }
                FinishSessionButton(session: session)
            } else {
                Button("Continue Scanning", systemImage: "viewfinder") { confirmResume = true }
            }
            Text("Editing cards updates this review. Saved estimates keep their original values, rates, overrides, card price and transaction choice. Saving an estimate does not record a completed purchase.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func restoreOfferInputs() {
        guard !restoredInputs else { return }
        restoredInputs = true
        do {
            if let saved = try session.savedOffers().last {
                if let amount = saved.customCashOffer { customCashText = CSVExportService.number(amount) }
                if let transaction = saved.tradeTransaction {
                    transactionMode = transaction.mode
                    if transaction.mode != .cashOnly, let price = transaction.myCardPrice { myCardPriceText = CSVExportService.number(price) }
                }
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
                            VStack(alignment: .leading, spacing: 20) {
                                if let transaction = estimate.tradeTransaction { TradeTransactionSummary(transaction: transaction) }
                                OfferBreakdownView(totals: estimate.totals, rates: estimate.rates, customCashOffer: estimate.customCashOffer)
                            }.padding(.vertical, 8)
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(estimate.savedAt, format: .dateTime)
                        if let transaction = estimate.tradeTransaction {
                            Text("\(transaction.mode.title) • \(transaction.finalAmount.money)").font(.subheadline.weight(.semibold))
                        }
                        Text("\(estimate.totals.quantity) cards • \(estimate.selectedCashOffer.money) cash • \(estimate.totals.trade.money) trade").font(.caption).foregroundStyle(.secondary)
                        if estimate.customCashOffer != nil { Text("Custom cash offer").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }.navigationTitle("Saved Estimates")
            .task { do { estimates = try session.savedOffers() } catch { self.error = error.localizedDescription } }
            .failureAlert($error)
    }
}
