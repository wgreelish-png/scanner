import SwiftUI

/// Pricing details stay inside the existing label editor and review flow.
struct TagPricingDisclosure: View {
    let draft: InventoryLabelDraft

    var body: some View {
        DisclosureGroup("Price, profit & negotiation") {
            LabeledContent("Current market", value: draft.marketValue?.money ?? "Unknown")
            LabeledContent("Suggested tag", value: draft.pricing.tag?.displayText ?? "Needs manual input")
            LabeledContent("Actual acquisition cost", value: draft.profitInputs.acquisitionCost?.money ?? "Unknown")
            LabeledContent("Break-even floor", value: money(draft.pricing.breakEvenCents))
            LabeledContent("Preferred minimum", value: money(draft.pricing.preferredFloorCents))
            LabeledContent("Suggested offer", value: money(draft.suggestedOfferCents))
            Text("Profit floors include acquisition cost, allocated expenses and payment fees. Offers follow the saved discount tiers and never fall below the preferred minimum.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .accessibilityIdentifier("labels.pricingDetails." + draft.id.uuidString)
    }

    private func money(_ cents: Int64?) -> String {
        cents.map { ShowBudgetMoney.decimal($0).money } ?? "Unavailable"
    }
}

struct TagRepricingSummary: View {
    let evaluation: RepricingEvaluation

    var body: some View {
        ForEach(evaluation.reasons.sorted { $0.priority < $1.priority }, id: \.rawValue) { reason in
            Label(title(reason), systemImage: icon(reason))
                .font(.caption.weight(.semibold))
                .foregroundStyle(reason == .overpriced || reason == .marketDecrease ? Color.orange : Color.secondary)
        }
        if let baseline = evaluation.baselineMarket, let delta = evaluation.marketDelta,
           !evaluation.reasons.isEmpty {
            Text("Last approved market \(baseline.money) · Change \(delta >= 0 ? "+" : "")\(delta.money)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func title(_ reason: RepricingReason) -> String {
        switch reason {
        case .newPricing: return "New pricing review"
        case .marketUnavailable: return "Current market unavailable"
        case .marketDecrease: return "Market decrease — review this tag first"
        case .overpriced: return "Overpriced against current market"
        case .marketIncrease: return "Market increase — review suggested price"
        }
    }
    private func icon(_ reason: RepricingReason) -> String {
        switch reason {
        case .marketDecrease: return "arrow.down.circle"
        case .overpriced: return "exclamationmark.triangle"
        case .marketIncrease: return "arrow.up.circle"
        case .newPricing, .marketUnavailable: return "tag"
        }
    }
}

@MainActor struct TagPricingSettingsView: View {
    let store: TagApprovalStore
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var minimum: String
    @State private var expenses: String
    @State private var fixedFee: String
    @State private var percentFee: String
    @State private var twoFive: Bool
    @State private var threeFive: Bool
    @State private var stacking: Bool
    @State private var error: String?
    @FocusState private var editing: Bool

    init(store: TagApprovalStore, onSave: @escaping () -> Void) {
        self.store = store
        self.onSave = onSave
        let preferences = store.preferences
        _minimum = State(initialValue: preferences.minimumDesiredProfitCents.map(Self.input) ?? "")
        _expenses = State(initialValue: Self.input(preferences.allocatedExpensesCents))
        _fixedFee = State(initialValue: Self.input(preferences.fixedPaymentFeeCents))
        _percentFee = State(initialValue: NSDecimalNumber(decimal: preferences.percentagePaymentFee * 100).stringValue)
        _twoFive = State(initialValue: preferences.enableTwoFiveForNine)
        _threeFive = State(initialValue: preferences.enableThreeFiveForThirteen)
        _stacking = State(initialValue: preferences.allowPromotionStacking)
    }

    private var preferences: TagPricingPreferences? {
        let minimumText = minimum.trimmingCharacters(in: .whitespacesAndNewlines)
        let percentageText = percentFee.trimmingCharacters(in: .whitespacesAndNewlines)
        let desired = minimumText.isEmpty ? nil : ShowBudgetMoney.parse(minimumText)
        guard minimumText.isEmpty || desired != nil,
              let expenses = ShowBudgetMoney.parse(expenses),
              let fixedFee = ShowBudgetMoney.parse(fixedFee),
              percentageText.range(of: #"^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let percentage = Decimal(string: percentageText,
                                       locale: Locale(identifier: "en_US_POSIX")),
              !percentage.isNaN, percentage >= 0, percentage < 100 else { return nil }
        return TagPricingPreferences(minimumDesiredProfitCents: desired,
            allocatedExpensesCents: expenses, fixedPaymentFeeCents: fixedFee,
            percentagePaymentFee: percentage / 100, enableTwoFiveForNine: twoFive,
            enableThreeFiveForThirteen: threeFive, allowPromotionStacking: stacking)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    amount("Minimum desired profit per card", text: $minimum, id: "minimum", placeholder: "Not configured")
                    amount("Allocated expenses per card", text: $expenses, id: "expenses")
                    amount("Fixed payment fee", text: $fixedFee, id: "fixedFee")
                    HStack {
                        Text("Payment percentage")
                        TextField("0", text: $percentFee).multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad).focused($editing)
                            .accessibilityIdentifier("labels.settings.percentFee")
                        Text("%").foregroundStyle(.secondary)
                    }
                } header: { Text("Profit inputs") } footer: {
                    Text("Leave the profit target blank until you choose an amount. Enter 2.9 for a 2.9% fee. Bundle previews count the fixed fee once per payment.")
                }
                Section("Optional bundle previews") {
                    Toggle("2 × $5 for $9", isOn: $twoFive)
                    Toggle("3 × $5 for $13", isOn: $threeFive)
                    Toggle("Allow promotion stacking", isOn: $stacking)
                    Text("2 for $1 is the default bulk category. These settings enable previews; they do not apply checkout discounts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if preferences == nil {
                    Section { Text("Enter nonnegative dollar amounts and a payment percentage below 100%.").foregroundStyle(.orange) }
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
            }
            .navigationTitle("Pricing Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { ClearLabelPrintQueueButton(identifier: "labels.settings.clearQueue") }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        guard let preferences else { return }
                        do {
                            try store.updatePreferences(preferences)
                            onSave()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(preferences == nil || !store.isLoaded)
                        .accessibilityIdentifier("labels.settings.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
        }
    }

    private func amount(_ title: String, text: Binding<String>, id: String, placeholder: String = "0") -> some View {
        HStack {
            Text(title)
            Text("$").foregroundStyle(.secondary)
            TextField(placeholder, text: text).multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad).focused($editing)
                .accessibilityIdentifier("labels.settings." + id)
        }
    }

    private static func input(_ cents: Int64) -> String {
        NSDecimalNumber(decimal: ShowBudgetMoney.decimal(cents)).stringValue
    }
}

struct TagBundleReviewSection: View {
    let lines: [TagBundleLine]
    let preferences: TagPricingPreferences

    private var promotions: [TagBundlePromotion] {
        var values: [TagBundlePromotion] = [.twoForOne]
        if preferences.enableTwoFiveForNine { values.append(.twoFiveForNine) }
        if preferences.enableThreeFiveForThirteen { values.append(.threeFiveForThirteen) }
        return values
    }

    var body: some View {
        Section {
            DisclosureGroup("Selected bundle margin preview") {
                Text("Uses every selected card and its requested copies as one group. Ineligible cards remain visible for review. No discount is applied.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(promotions) { promotion in
                    let result = TagBundlePricing.evaluate(lines: lines, promotion: promotion,
                        paymentFixedFee: ShowBudgetMoney.decimal(preferences.fixedPaymentFeeCents),
                        paymentPercentageFee: preferences.percentagePaymentFee,
                        settings: TagBundleSettings(enabledPromotions: promotions,
                                                    allowsDiscountStacking: preferences.allowPromotionStacking))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(promotion.title).font(.subheadline.weight(.semibold))
                        LabeledContent("Selected copies", value: result.selectedQuantity.formatted())
                        LabeledContent("Bundle total", value: money(result.totalChargeCents))
                        LabeledContent("Break-even floor", value: money(result.breakEvenCents))
                        LabeledContent("Preferred minimum", value: money(result.preferredFloorCents))
                        if let profit = profit(result) {
                            LabeledContent("Profit after costs & fees", value: profit.money)
                        }
                        if let savings = result.savingsCents {
                            LabeledContent("Savings", value: money(savings))
                        }
                        if !result.excludedLineIDs.isEmpty {
                            LabeledContent("Excluded cards", value: result.excludedLineIDs.count.formatted())
                                .foregroundStyle(.orange)
                        }
                        ForEach(result.manualReviewReasons, id: \.self) { reason in
                            Label(reason, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if result.isEligible {
                            Label("Selected group passes the margin checks", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }.padding(.vertical, 6)
                }
            }
        }.accessibilityIdentifier("labels.bundlePreview")
    }

    private func money(_ cents: Int64?) -> String {
        cents.map { ShowBudgetMoney.decimal($0).money } ?? "Unavailable"
    }
    private func profit(_ result: TagBundleEvaluation) -> Decimal? {
        guard let charge = result.totalChargeCents, result.breakEvenCents != nil,
              lines.allSatisfy({ $0.profitInputs.acquisitionCost != nil }) else { return nil }
        let costs = lines.reduce(Decimal.zero) {
            $0 + (($1.profitInputs.acquisitionCost ?? 0) + $1.profitInputs.allocatedExpenses) * Decimal($1.quantity)
        }
        let dollars = ShowBudgetMoney.decimal(charge)
        return dollars * (1 - preferences.percentagePaymentFee)
            - ShowBudgetMoney.decimal(preferences.fixedPaymentFeeCents) - costs
    }
}
