import SwiftUI

/// One explicit draft edit; each card still keeps its own cost/profit evaluation.
struct LabelBatchPriceEditor: View {
    let cardCount: Int
    let onSave: (Int64) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var price = ""
    @FocusState private var priceFocused: Bool

    private var cents: Int64? {
        guard let value = ShowBudgetMoney.parse(price), value % 100 == 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Price per card") {
                    HStack {
                        Text("$").foregroundStyle(.secondary)
                        TextField("Whole-dollar price", text: $price).keyboardType(.numberPad)
                            .focused($priceFocused).accessibilityIdentifier("labels.batchPrice.amount")
                    }
                    Text("Applies to \(cardCount.formatted()) selected inventory entries. Copy counts stay the same; 2 for $1 bulk cards stay in their category.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("Each card's acquisition cost and minimum profit are still checked before approval. Applying this price does not save or print labels.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Set Batch Price").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("labels.batchPrice.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        guard let cents else { return }
                        onSave(cents)
                        dismiss()
                    }.disabled(cents == nil).accessibilityIdentifier("labels.batchPrice.apply")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { priceFocused = false }.fixedSize().frame(minWidth: 64, minHeight: 44)
                        .accessibilityIdentifier("labels.batchPrice.keyboardDone")
                }
            }
        }
    }
}
